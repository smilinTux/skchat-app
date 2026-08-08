import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/device_list_service.dart";

/// Records every request and answers with a configurable [status] + [body].
/// Mirrors `guest_dm_contacts_service_test.dart`'s `_RecordingAdapter`, plus a
/// settable status so the same adapter can exercise both the happy path and
/// the 400/404 branches `device_routes.py` returns.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  /// What the daemon answers with. Defaults to an empty object; set it when
  /// the test cares about what the caller reads back off the response.
  Object? body = const <String, dynamic>{};

  /// HTTP status to answer with. Dio's default `validateStatus` turns
  /// anything outside 200-299 into a `DioException`, which is what lets these
  /// tests exercise the service's error mapping.
  int status = 200;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

DeviceListService _service(_RecordingAdapter a) => DeviceListService(
    dio: Dio()..httpClientAdapter = a, webuiBaseUrl: "https://h.test");

void main() {
  test("list() parses the devices envelope and the is_current flag",
      () async {
    final a = _RecordingAdapter()
      ..body = const {
        "devices": [
          {
            "device_fp": "FP1",
            "label": "Pixel 9",
            "label_source": "user",
            "platform": "android",
            "enrolled_at": 1000.0,
            "last_seen": 2000.0,
            "key_ids": ["k1", "k2"],
            "is_current": true,
          },
          {
            "device_fp": "FP2",
            "label": "Chef's laptop",
            "label_source": "auto",
            "platform": "linux",
            "enrolled_at": 500.0,
            "last_seen": 600.0,
            "key_ids": [],
            "is_current": false,
          },
        ],
      };
    final svc = _service(a);

    final devices = await svc.list();

    expect(a.requests.single.method, "GET");
    expect(a.requests.single.uri.path, "/api/v1/operator/devices");
    expect(devices, hasLength(2));
    expect(devices[0].deviceFp, "FP1");
    expect(devices[0].label, "Pixel 9");
    expect(devices[0].labelSource, "user");
    expect(devices[0].platform, "android");
    expect(devices[0].enrolledAt, 1000.0);
    expect(devices[0].lastSeen, 2000.0);
    expect(devices[0].keyIds, ["k1", "k2"]);
    expect(devices[0].isCurrent, isTrue);
    expect(devices[1].isCurrent, isFalse);
  });

  test("list() tolerates an empty envelope", () async {
    final a = _RecordingAdapter();
    final svc = _service(a);

    expect(await svc.list(), isEmpty);
  });

  test("unlink() issues DELETE to the device-fp path and parses the report",
      () async {
    final a = _RecordingAdapter()
      ..body = const {
        "device_fp": "FP1",
        "sessions_revoked": true,
        "slots_removed": ["k1"],
        "slots_failed": [],
        "registry_had_no_slots": false,
        "store_removed": true,
        "capauth_revoked": true,
        "capauth_records_failed": 0,
        "registry_marked": true,
      };
    final svc = _service(a);

    final report = await svc.unlink("FP1");

    final req = a.requests.single;
    expect(req.method, "DELETE");
    expect(req.uri.path, "/api/v1/operator/devices/FP1");
    expect(report.deviceFp, "FP1");
    expect(report.sessionsRevoked, isTrue);
    expect(report.slotsRemoved, ["k1"]);
    expect(report.storeRemoved, isTrue);
    expect(report.isDegraded, isFalse);
  });

  test("unlink() report is degraded when a slot failed to remove", () async {
    final a = _RecordingAdapter()
      ..body = const {
        "device_fp": "FP1",
        "sessions_revoked": true,
        "slots_removed": [],
        "slots_failed": ["k1"],
        "registry_had_no_slots": false,
        "store_removed": true,
        "capauth_revoked": false,
        "capauth_records_failed": 0,
        "registry_marked": true,
      };
    final svc = _service(a);

    final report = await svc.unlink("FP1");

    expect(report.isDegraded, isTrue);
  });

  test(
      "unlink() on the caller's own device surfaces a typed selfUnlink error, "
      "not a raw DioException", () async {
    final a = _RecordingAdapter()
      ..status = 400
      ..body = const {
        "detail":
            "cannot unlink the device you are using; unlink it from another "
                "device, or use unlink-others",
      };
    final svc = _service(a);

    try {
      await svc.unlink("FP-SELF");
      fail("expected a DeviceUnlinkException");
    } on DeviceUnlinkException catch (e) {
      expect(e.reason, DeviceUnlinkFailureReason.selfUnlink);
      expect(e.statusCode, 400);
      expect(e.message, contains("you are using"));
    }
  });

  test(
      "unlink() with no operator session surfaces a typed noOperatorSession "
      "error, distinct from selfUnlink", () async {
    final a = _RecordingAdapter()
      ..status = 400
      ..body = const {
        "detail":
            "an operator session is required so this route can tell whether "
                "you are unlinking the device you are using; if you have no "
                "enrolled device to authenticate with, use `skchat devices "
                "reset`",
      };
    final svc = _service(a);

    try {
      await svc.unlink("FP1");
      fail("expected a DeviceUnlinkException");
    } on DeviceUnlinkException catch (e) {
      expect(e.reason, DeviceUnlinkFailureReason.noOperatorSession);
      expect(e.statusCode, 400);
    }
  });

  test("unlink() on an unknown fingerprint surfaces a typed notFound error",
      () async {
    final a = _RecordingAdapter()
      ..status = 404
      ..body = const {"detail": "device not found"};
    final svc = _service(a);

    try {
      await svc.unlink("FP-GHOST");
      fail("expected a DeviceUnlinkException");
    } on DeviceUnlinkException catch (e) {
      expect(e.reason, DeviceUnlinkFailureReason.notFound);
      expect(e.statusCode, 404);
    }
  });

  test("unlinkOthers() POSTs the unlink-others route and returns the "
      "fingerprint list plus skipped/degraded", () async {
    final a = _RecordingAdapter()
      ..body = const {
        "unlinked": ["FP2", "FP3"],
        "reports": {
          "FP2": {
            "device_fp": "FP2",
            "sessions_revoked": true,
            "slots_removed": ["k2"],
            "slots_failed": [],
            "registry_had_no_slots": false,
            "store_removed": true,
            "capauth_revoked": true,
            "capauth_records_failed": 0,
            "registry_marked": true,
          },
          "FP3": {
            "device_fp": "FP3",
            "sessions_revoked": true,
            "slots_removed": [],
            "slots_failed": [],
            "registry_had_no_slots": true,
            "store_removed": true,
            "capauth_revoked": false,
            "capauth_records_failed": 0,
            "registry_marked": true,
          },
        },
        "skipped": ["FP4"],
        "degraded": ["FP3"],
      };
    final svc = _service(a);

    final result = await svc.unlinkOthers();

    final req = a.requests.single;
    expect(req.method, "POST");
    expect(req.uri.path, "/api/v1/operator/devices/unlink-others");
    expect(result.unlinked, ["FP2", "FP3"]);
    expect(result.skipped, ["FP4"]);
    expect(result.degraded, ["FP3"]);
    expect(result.reports["FP2"]!.isDegraded, isFalse);
    expect(result.reports["FP3"]!.isDegraded, isTrue);
  });

  test(
      "unlinkOthers() with no operator session surfaces a typed "
      "noOperatorSession error", () async {
    final a = _RecordingAdapter()
      ..status = 400
      ..body = const {
        "detail":
            "unlink-others requires an operator session so this device can "
                "be spared",
      };
    final svc = _service(a);

    try {
      await svc.unlinkOthers();
      fail("expected a DeviceUnlinkException");
    } on DeviceUnlinkException catch (e) {
      expect(e.reason, DeviceUnlinkFailureReason.noOperatorSession);
      expect(e.statusCode, 400);
    }
  });
}
