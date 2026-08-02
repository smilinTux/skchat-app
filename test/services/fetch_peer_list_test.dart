import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/pq_dm_codec.dart";
import "package:skchat/services/pq_prekey_service.dart";

/// Task 6 (multi-device DM fanout, Phase 1): `GET /api/v1/prekey/<peer>` now
/// returns `{prekeys: [<slot>...], prekey: <newest>}`. `fetchPeer` parses the
/// slot LIST so the sender can fan out to every device, while still tolerating
/// the OLD single-bundle shapes (`{prekey: {...}}` and a bare bundle) from a
/// daemon that predates the multi-slot response. `fetchPeerNewest` keeps the
/// single-bundle contract for the pqdm1 fallback path.

/// Canned-response adapter keyed by path (mirrors the project's service-test
/// mocking style, see operator_session_service_test.dart).
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = routes[options.path] ?? routes[options.uri.path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

PqPrekeyService _service(Map<String, Object?> routes) {
  final dio = Dio(BaseOptions(baseUrl: "http://127.0.0.1:9385"))
    ..httpClientAdapter = _CannedAdapter(routes);
  return PqPrekeyService(
    storage: const FlutterSecureStorage(),
    baseUrl: "http://127.0.0.1:9385",
    deviceId: "test-device",
    dio: dio,
  );
}

Map<String, dynamic> _slot(String keyId) => {
      "suite": PqDmCodec.hybridSuite,
      "hybrid_public_hex": "00" * 16 + keyId,
      "key_id": keyId,
      "device_id": "dev-$keyId",
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("fetchPeer parses the slot list", () {
    test("returns every slot from the new prekeys[] shape, newest first",
        () async {
      final newest = _slot("bbbbbbbbbbbbbbbb");
      final older = _slot("aaaaaaaaaaaaaaaa");
      final svc = _service({
        "/api/v1/prekey/chef": {
          "prekeys": [newest, older],
          "prekey": newest,
        },
      });
      final list = await svc.fetchPeer("chef");
      expect(list, hasLength(2));
      expect(list.map((b) => b.keyId).toList(),
          ["bbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaa"]);
      expect(list.first.isHybrid, isTrue);
    });

    test("tolerates the old {prekey: {...}} single-bundle shape", () async {
      final svc = _service({
        "/api/v1/prekey/chef": {"prekey": _slot("aaaaaaaaaaaaaaaa")},
      });
      final list = await svc.fetchPeer("chef");
      expect(list, hasLength(1));
      expect(list.single.keyId, "aaaaaaaaaaaaaaaa");
    });

    test("tolerates a bare-bundle response (no wrapper)", () async {
      final svc = _service({
        "/api/v1/prekey/chef": _slot("aaaaaaaaaaaaaaaa"),
      });
      final list = await svc.fetchPeer("chef");
      expect(list, hasLength(1));
      expect(list.single.keyId, "aaaaaaaaaaaaaaaa");
    });

    test("empty prekeys[] yields an empty list", () async {
      final svc = _service({
        "/api/v1/prekey/nobody": {
          "prekeys": [],
          "prekey": {"suite": PqDmCodec.classicalSuite, "hybrid_public_hex": ""},
        },
      });
      expect(await svc.fetchPeer("nobody"), isEmpty);
    });
  });

  group("fetchPeerNewest (pqdm1 fallback)", () {
    test("returns the newest slot from the list", () async {
      final newest = _slot("bbbbbbbbbbbbbbbb");
      final svc = _service({
        "/api/v1/prekey/chef": {
          "prekeys": [newest, _slot("aaaaaaaaaaaaaaaa")],
          "prekey": newest,
        },
      });
      final bundle = await svc.fetchPeerNewest("chef");
      expect(bundle.keyId, "bbbbbbbbbbbbbbbb");
      expect(bundle.isHybrid, isTrue);
    });

    test("returns a classical bundle when the peer published nothing", () async {
      final svc = _service({
        "/api/v1/prekey/nobody": {
          "prekeys": [],
          "prekey": {"suite": PqDmCodec.classicalSuite, "hybrid_public_hex": ""},
        },
      });
      final bundle = await svc.fetchPeerNewest("nobody");
      expect(bundle.isHybrid, isFalse);
    });
  });
}
