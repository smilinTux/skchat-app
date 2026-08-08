import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/profile/linked_devices_screen.dart";
import "package:skchat/services/device_list_service.dart";

const _jsonHeaders = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

/// Fake adapter routing by method + path, mirroring the project's
/// established Dio-mocking style (`device_list_service_test.dart`'s
/// `_RecordingAdapter`, `operator_session_service_test.dart`'s
/// `_CannedAdapter`). [listResponses] is a queue: each GET pops the next
/// entry, but once it drains, the last entry keeps being served, so a test
/// can prime "before" and "after refresh" bodies without having to guess how
/// many loads will happen.
class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Object?> listResponses = [];
  int listStatus = 200;
  Object? unlinkBody = const <String, dynamic>{};
  int unlinkStatus = 200;
  Object? unlinkOthersBody = const {
    "unlinked": <String>[],
    "reports": <String, dynamic>{},
    "skipped": <String>[],
    "degraded": <String>[],
  };
  int unlinkOthersStatus = 200;
  Object? renameBody;
  int renameStatus = 200;

  @override
  void close({bool force = false}) {}

  Object? _nextListResponse() {
    if (listResponses.isEmpty) return const {"devices": <dynamic>[]};
    return listResponses.length > 1
        ? listResponses.removeAt(0)
        : listResponses.first;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    if (options.method == "GET" && path == "/api/v1/operator/devices") {
      return ResponseBody.fromString(
        jsonEncode(_nextListResponse()),
        listStatus,
        headers: _jsonHeaders,
      );
    }
    if (options.method == "DELETE") {
      return ResponseBody.fromString(
        jsonEncode(unlinkBody),
        unlinkStatus,
        headers: _jsonHeaders,
      );
    }
    if (options.method == "PATCH") {
      return ResponseBody.fromString(
        jsonEncode(renameBody ?? _echoRename(options)),
        renameStatus,
        headers: _jsonHeaders,
      );
    }
    if (options.method == "POST" &&
        path == "/api/v1/operator/devices/unlink-others") {
      return ResponseBody.fromString(
        jsonEncode(unlinkOthersBody),
        unlinkOthersStatus,
        headers: _jsonHeaders,
      );
    }
    return ResponseBody.fromString("{}", 404, headers: _jsonHeaders);
  }
}

/// Default PATCH response when a test doesn't set [_FakeAdapter.renameBody]:
/// echoes the fingerprint out of the path and the label out of the request
/// body, with `label_source` "operator", the way the real server does on a
/// successful rename (`device_routes.py:rename`).
Map<String, dynamic> _echoRename(RequestOptions options) {
  final fp = options.uri.pathSegments.last;
  final data = options.data;
  final label = (data is Map && data["label"] is String)
      ? data["label"] as String
      : "";
  return _device(fp: fp, label: label, labelSource: "operator");
}

DeviceListService _service(_FakeAdapter a) => DeviceListService(
      dio: Dio()..httpClientAdapter = a,
      webuiBaseUrl: "https://h.test",
    );

Widget _wrap(DeviceListService service) {
  return ProviderScope(
    overrides: [deviceListServiceProvider.overrideWithValue(service)],
    child: const MaterialApp(home: LinkedDevicesScreen()),
  );
}

Map<String, dynamic> _device({
  required String fp,
  required String label,
  String labelSource = "derived",
  String platform = "linux",
  double lastSeen = 0,
  bool isCurrent = false,
}) =>
    {
      "device_fp": fp,
      "label": label,
      "label_source": labelSource,
      "platform": platform,
      "enrolled_at": 1000.0,
      "last_seen": lastSeen,
      "key_ids": <String>[],
      "is_current": isCurrent,
    };

void main() {
  group("relativeLastSeen", () {
    test("renders sub-minute, minute, hour and day boundaries", () {
      final now = DateTime.now();
      double secondsAgo(Duration d) =>
          now.subtract(d).millisecondsSinceEpoch / 1000;

      expect(relativeLastSeen(now.millisecondsSinceEpoch / 1000), "just now");
      expect(relativeLastSeen(secondsAgo(const Duration(minutes: 5))),
          "5m ago");
      expect(
          relativeLastSeen(secondsAgo(const Duration(hours: 3))), "3h ago");
      expect(relativeLastSeen(secondsAgo(const Duration(days: 2))), "2d ago");
      expect(relativeLastSeen(0), "never");
    });
  });

  group("rows", () {
    testWidgets(
      "render each device's label, platform, and relative last-seen",
      (tester) async {
        final fiveMinAgo = DateTime.now()
                .subtract(const Duration(minutes: 5))
                .millisecondsSinceEpoch /
            1000;
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(
                fp: "FP-SELF",
                label: "This Laptop",
                platform: "linux",
                lastSeen: DateTime.now().millisecondsSinceEpoch / 1000,
                isCurrent: true,
              ),
              _device(
                fp: "FP-OTHER",
                label: "Pixel 9",
                labelSource: "operator",
                platform: "android",
                lastSeen: fiveMinAgo,
              ),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        expect(find.text("This Laptop"), findsOneWidget);
        expect(find.textContaining("linux"), findsOneWidget);
        expect(find.text("Pixel 9"), findsOneWidget);
        expect(find.textContaining("android"), findsOneWidget);
        expect(find.textContaining("5m ago"), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "the current device shows the This device chip and offers no Unlink "
      "control; every other row does",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
              _device(
                  fp: "FP-OTHER", label: "Pixel 9", labelSource: "operator"),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        expect(find.text("This device"), findsOneWidget);
        expect(find.byKey(const Key("unlink-action-FP-SELF")), findsNothing);
        expect(
            find.byKey(const Key("unlink-action-FP-OTHER")), findsOneWidget);
      },
    );

    testWidgets(
      "client and derived sources render untrusted (amber, italic); only "
      "client also gets a self-named: marker; operator renders trusted with "
      "neither",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
              _device(
                fp: "FP-CLIENT",
                label: "Self-Named Device",
                labelSource: "client",
              ),
              _device(
                fp: "FP-DERIVED",
                label: "Derived Device",
                labelSource: "derived",
              ),
              _device(
                fp: "FP-OPERATOR",
                label: "Operator-Set Name",
                labelSource: "operator",
              ),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        // Client-asserted: untrusted styling AND a text-level marker, so a
        // device signing itself e.g. "Chef's MacBook (verified)" cannot pass
        // as a row the server named.
        final untrustedText =
            tester.widget<Text>(find.text("self-named: Self-Named Device"));
        expect(untrustedText.style?.fontStyle, FontStyle.italic);
        expect(untrustedText.style?.color, isNotNull);
        expect(find.text("Self-Named Device"), findsNothing);

        // Server-derived (parsed from the User-Agent, not spoofable by the
        // device, but not necessarily accurate either): untrusted styling
        // too, since only an operator-confirmed rename earns the trusted
        // look, but no "self-named:" marker, the device never claimed it.
        final derivedText = tester.widget<Text>(find.text("Derived Device"));
        expect(derivedText.style?.fontStyle, FontStyle.italic);
        expect(derivedText.style?.color, isNotNull);

        // Operator-set (a confirmed rename): trusted, no marker, no
        // untrusted styling.
        final trustedText =
            tester.widget<Text>(find.text("Operator-Set Name"));
        expect(trustedText.style?.fontStyle, isNot(FontStyle.italic));
      },
    );
  });

  group("rename device", () {
    testWidgets(
      "the rename affordance exists on every row, including the current "
      "device",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
              _device(fp: "FP-OTHER", label: "Pixel 9"),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key("rename-action-FP-SELF")), findsOneWidget);
        expect(
            find.byKey(const Key("rename-action-FP-OTHER")), findsOneWidget);
      },
    );

    testWidgets(
      "tapping it opens a dialog pre-filled with the current label",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-OTHER", label: "Pixel 9"),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key("rename-action-FP-OTHER")));
        await tester.pumpAndSettle();

        expect(find.text("Rename device"), findsOneWidget);
        final field =
            tester.widget<TextField>(find.byKey(const Key("rename-input-field")));
        expect(field.controller?.text, "Pixel 9");
      },
    );

    testWidgets(
      "confirming calls the service with the new label and refreshes the "
      "list",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.addAll([
            {
              "devices": [
                _device(fp: "FP-OTHER", label: "Pixel 9", labelSource: "derived"),
              ],
            },
            {
              "devices": [
                _device(
                  fp: "FP-OTHER",
                  label: "Chef's Desk",
                  labelSource: "operator",
                ),
              ],
            },
          ]);

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key("rename-action-FP-OTHER")));
        await tester.pumpAndSettle();

        await tester.enterText(
            find.byKey(const Key("rename-input-field")), "Chef's Desk");
        await tester.tap(find.byKey(const Key("rename-confirm-action")));
        await tester.pumpAndSettle();

        final patchRequests =
            adapter.requests.where((r) => r.method == "PATCH").toList();
        expect(patchRequests, hasLength(1));
        expect(patchRequests.single.uri.path,
            "/api/v1/operator/devices/FP-OTHER");
        expect(patchRequests.single.data, {"label": "Chef's Desk"});
        expect(adapter.requests.where((r) => r.method == "GET"),
            hasLength(2));
        expect(find.text("Chef's Desk"), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "empty input is rejected client-side without calling the service",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-OTHER", label: "Pixel 9"),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key("rename-action-FP-OTHER")));
        await tester.pumpAndSettle();

        await tester.enterText(
            find.byKey(const Key("rename-input-field")), "   ");
        await tester.tap(find.byKey(const Key("rename-confirm-action")));
        await tester.pumpAndSettle();

        expect(find.text("Name cannot be empty"), findsOneWidget);
        expect(adapter.requests.where((r) => r.method == "PATCH"), isEmpty);
        // Dialog stays open so the operator can fix the input.
        expect(find.text("Rename device"), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "a server error surfaces as friendly text, never a raw exception",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-OTHER", label: "Pixel 9"),
            ],
          })
          ..renameStatus = 404
          ..renameBody = const {"detail": "device not found"};

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key("rename-action-FP-OTHER")));
        await tester.pumpAndSettle();

        await tester.enterText(
            find.byKey(const Key("rename-input-field")), "New Name");
        await tester.tap(find.byKey(const Key("rename-confirm-action")));
        await tester.pumpAndSettle();

        expect(find.textContaining("already gone"), findsOneWidget);
        expect(find.textContaining("DioException"), findsNothing);
        expect(find.textContaining("Exception"), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "a row whose labelSource is operator renders WITHOUT the untrusted "
      "styling or marker, while client and derived rows still render with "
      "it, after a rename flips one to operator",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.addAll([
            {
              "devices": [
                _device(
                    fp: "FP-CLIENT", label: "Self-Named", labelSource: "client"),
                _device(
                    fp: "FP-DERIVED", label: "Chrome on Linux",
                    labelSource: "derived"),
              ],
            },
            {
              "devices": [
                _device(
                    fp: "FP-CLIENT", label: "Self-Named", labelSource: "client"),
                _device(
                    fp: "FP-DERIVED", label: "Chef's Desk",
                    labelSource: "operator"),
              ],
            },
          ]);

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        // Before renaming: derived renders untrusted (italic), no marker.
        final beforeText =
            tester.widget<Text>(find.text("Chrome on Linux"));
        expect(beforeText.style?.fontStyle, FontStyle.italic);

        await tester.tap(find.byKey(const Key("rename-action-FP-DERIVED")));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const Key("rename-input-field")), "Chef's Desk");
        await tester.tap(find.byKey(const Key("rename-confirm-action")));
        await tester.pumpAndSettle();

        // After the rename round-trips through the server (label_source
        // "operator"), the row renders trusted: no italic, no marker.
        final afterText = tester.widget<Text>(find.text("Chef's Desk"));
        expect(afterText.style?.fontStyle, isNot(FontStyle.italic));

        // The untouched client row is still untrusted with its marker.
        expect(find.text("self-named: Self-Named"), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group("no operator session banner (shared X-Operator-Token, no session)", () {
    testWidgets(
      "shows an explanatory banner when no row is marked current",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-A", label: "Device A"),
              _device(fp: "FP-B", label: "Device B"),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key("no-operator-session-banner")),
            findsOneWidget);
      },
    );

    testWidgets(
      "the banner is absent once a row is marked current",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
              _device(fp: "FP-OTHER", label: "Pixel 9"),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key("no-operator-session-banner")),
            findsNothing);
      },
    );
  });

  group("unlink one device", () {
    testWidgets(
      "tapping Unlink opens a confirm dialog naming the device and only "
      "calls the service on confirm",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
              _device(fp: "FP-OTHER", label: "Pixel 9"),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key("unlink-action-FP-OTHER")));
        await tester.pumpAndSettle();

        expect(find.text("Unlink this device?"), findsOneWidget);
        expect(find.textContaining("Pixel 9"), findsWidgets);
        expect(adapter.requests.where((r) => r.method == "DELETE"), isEmpty);

        // Cancel: no DELETE sent, dialog closes.
        await tester.tap(find.text("Cancel"));
        await tester.pumpAndSettle();
        expect(find.text("Unlink this device?"), findsNothing);
        expect(adapter.requests.where((r) => r.method == "DELETE"), isEmpty);

        // Re-open and this time confirm.
        await tester.tap(find.byKey(const Key("unlink-action-FP-OTHER")));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key("unlink-confirm-action")));
        await tester.pumpAndSettle();

        final deleteRequests =
            adapter.requests.where((r) => r.method == "DELETE").toList();
        expect(deleteRequests, hasLength(1));
        expect(deleteRequests.single.uri.path,
            "/api/v1/operator/devices/FP-OTHER");
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "a successful unlink refreshes the list, the unlinked row is gone",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.addAll([
            {
              "devices": [
                _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
                _device(fp: "FP-OTHER", label: "Pixel 9"),
              ],
            },
            {
              "devices": [
                _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
              ],
            },
          ])
          ..unlinkBody = {
            "device_fp": "FP-OTHER",
            "sessions_revoked": true,
            "slots_removed": <String>[],
            "slots_failed": <String>[],
            "registry_had_no_slots": false,
            "store_removed": true,
            "capauth_revoked": true,
            "capauth_records_failed": 0,
            "registry_marked": true,
          };

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();
        expect(find.text("Pixel 9"), findsOneWidget);

        await tester.tap(find.byKey(const Key("unlink-action-FP-OTHER")));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key("unlink-confirm-action")));
        await tester.pumpAndSettle();

        expect(find.text("Pixel 9"), findsNothing);
        expect(find.text("This Laptop"), findsOneWidget);
        expect(adapter.requests.where((r) => r.method == "GET"),
            hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "a self-unlink 400 shows a friendly message, never a raw exception",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
              _device(fp: "FP-OTHER", label: "Pixel 9"),
            ],
          })
          ..unlinkStatus = 400
          ..unlinkBody = {
            "detail": "cannot unlink the device you are using; unlink it "
                "from another device, or use unlink-others",
          };

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key("unlink-action-FP-OTHER")));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key("unlink-confirm-action")));
        await tester.pumpAndSettle();

        expect(find.textContaining("Cannot unlink the device you are using"),
            findsOneWidget);
        expect(find.textContaining("DioException"), findsNothing);
        expect(find.textContaining("Exception"), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group("unlink all other devices", () {
    testWidgets(
      "is hidden when there is only the current device",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.add({
            "devices": [
              _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
            ],
          });

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key("unlink-all-others-action")),
            findsNothing);
      },
    );

    testWidgets(
      "behind a confirmation, unlinks every other device and refreshes",
      (tester) async {
        final adapter = _FakeAdapter()
          ..listResponses.addAll([
            {
              "devices": [
                _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
                _device(fp: "FP-A", label: "Device A"),
                _device(fp: "FP-B", label: "Device B"),
              ],
            },
            {
              "devices": [
                _device(fp: "FP-SELF", label: "This Laptop", isCurrent: true),
              ],
            },
          ])
          ..unlinkOthersBody = {
            "unlinked": ["FP-A", "FP-B"],
            "reports": <String, dynamic>{},
            "skipped": <String>[],
            "degraded": <String>[],
          };

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key("unlink-all-others-action")));
        await tester.pumpAndSettle();

        expect(find.text("Unlink all other devices?"), findsOneWidget);
        expect(
          adapter.requests.where(
            (r) =>
                r.method == "POST" &&
                r.uri.path == "/api/v1/operator/devices/unlink-others",
          ),
          isEmpty,
        );

        await tester.tap(find.byKey(const Key("unlink-all-confirm-action")));
        await tester.pumpAndSettle();

        expect(find.text("Device A"), findsNothing);
        expect(find.text("Device B"), findsNothing);
        expect(find.text("This Laptop"), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group("loading / empty / error states", () {
    testWidgets("shows a loading indicator on the very first frame",
        (tester) async {
      final adapter = _FakeAdapter()..listResponses.add({"devices": []});

      await tester.pumpWidget(_wrap(_service(adapter)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();
    });

    testWidgets("shows an empty state with no devices", (tester) async {
      final adapter = _FakeAdapter()..listResponses.add({"devices": []});

      await tester.pumpWidget(_wrap(_service(adapter)));
      await tester.pumpAndSettle();

      expect(find.text("No linked devices"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      "shows a friendly error state on a failed load, never a raw exception",
      (tester) async {
        final adapter = _FakeAdapter()..listStatus = 500;

        await tester.pumpWidget(_wrap(_service(adapter)));
        await tester.pumpAndSettle();

        expect(find.text("Could not load devices"), findsOneWidget);
        expect(find.textContaining("DioException"), findsNothing);
        expect(find.textContaining("Exception"), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
