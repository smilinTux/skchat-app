import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/join_service.dart";

/// Canned-response adapter — resolves each request from [routes] by path and
/// records the last request for body/path assertions. (Same pattern as
/// spaces_service_test.)
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
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

/// Fake signer — records the claim it was asked to sign and returns a
/// deterministic signature. Avoids real RSA / isolates in unit tests.
class _FakeSigner implements SovereignSigner {
  String? signedClaim;

  @override
  Future<String> sign(String claim) async {
    signedClaim = claim;
    return "sig-of:${claim.hashCode}";
  }
}

void main() {
  group("JoinLink.tryParse", () {
    test("guest link (room + invite)", () {
      final link = JoinLink.tryParse("/join?room=town-hall&invite=ABC123");
      expect(link, isNotNull);
      expect(link!.room, "town-hall");
      expect(link.inviteToken, "ABC123");
      expect(link.hasGuest, isTrue);
      expect(link.sovereign, isFalse);
    });

    test("sovereign link (room + sovereign=1)", () {
      final link = JoinLink.tryParse("/join?room=town-hall&sovereign=1");
      expect(link, isNotNull);
      expect(link!.sovereign, isTrue);
      expect(link.hasGuest, isFalse);
    });

    test("both paths offered", () {
      final link =
          JoinLink.tryParse("/join?room=r1&invite=tok&sovereign=true");
      expect(link!.hasGuest, isTrue);
      expect(link.sovereign, isTrue);
    });

    test("full https deep-link URL with display name", () {
      final link = JoinLink.tryParse(
        "https://noroc2027.ts.net/join?room=r1&invite=tok&name=Dave",
      );
      expect(link!.room, "r1");
      expect(link.displayName, "Dave");
    });

    test("rejects missing room", () {
      expect(JoinLink.tryParse("/join?invite=ABC"), isNull);
    });

    test("rejects a room with no join path", () {
      expect(JoinLink.tryParse("/join?room=r1"), isNull);
    });
  });

  group("JoinService", () {
    late _CannedAdapter adapter;
    late Dio dio;
    late JoinService svc;

    setUp(() {
      adapter = _CannedAdapter({});
      dio = Dio()..httpClientAdapter = adapter;
      svc = JoinService(dio: dio, webuiBaseUrl: "https://test.local");
    });

    test("joinGuest posts invite_token + display_name, parses lk_token", () async {
      adapter.routes["/guest/join"] = {
        "lk_token": "jwt-guest",
        "lk_url": "wss://lk.test/ws",
        "room": "town-hall",
        "identity": "guest-Dave",
      };

      final join = await svc.joinGuest(
        room: "town-hall",
        inviteToken: "ABC123",
        displayName: "Dave",
      );

      expect(join.token, "jwt-guest");
      expect(join.lkUrl, "wss://lk.test/ws");
      expect(join.room, "town-hall");
      expect(join.identity, "guest-Dave");

      final sent = adapter.lastRequest!.data as Map;
      expect(adapter.lastRequest!.uri.path, "/guest/join");
      expect(sent["room"], "town-hall");
      expect(sent["invite_token"], "ABC123");
      expect(sent["display_name"], "Dave");
    });

    test("joinSovereign signs the claim and posts {claim, sig}", () async {
      adapter.routes["/join/sovereign"] = {
        "token": "jwt-sov",
        "space_id": "sp-1",
        "identity": "FPRINT",
        "role": "speaker",
        "conf_ws_url": "wss://lk.test/sov",
      };

      final signer = _FakeSigner();
      final join = await svc.joinSovereign(
        room: "town-hall",
        identity: "FPRINT",
        signer: signer,
        issuedAt: DateTime.utc(2026, 6, 20, 12),
      );

      // Returned token + ws url normalized for connectWithToken.
      expect(join.token, "jwt-sov");
      expect(join.lkUrl, "wss://lk.test/sov");
      expect(join.role, "speaker");
      expect(join.spaceId, "sp-1");
      expect(join.identity, "FPRINT");

      // The signer saw the exact canonical claim string...
      final sent = adapter.lastRequest!.data as Map;
      expect(adapter.lastRequest!.uri.path, "/join/sovereign");
      expect(sent["claim"], signer.signedClaim);
      expect(sent["sig"], "sig-of:${signer.signedClaim.hashCode}");

      // ...and the claim binds identity + room + a UTC timestamp.
      final claim = jsonDecode(sent["claim"] as String) as Map<String, dynamic>;
      expect(claim["room"], "town-hall");
      expect(claim["identity"], "FPRINT");
      expect(claim["purpose"], "conf-join");
      expect(claim["iss"], "2026-06-20T12:00:00.000Z");
    });

    test("buildSovereignClaim has stable alphabetical key order", () {
      final claim = JoinService.buildSovereignClaim(
        room: "r",
        identity: "id",
        issuedAt: DateTime.utc(2026, 1, 1),
      );
      // Keys serialized in insertion order; assert the canonical layout the
      // server re-derives before verifying the signature.
      expect(
        claim,
        '{"identity":"id","iss":"2026-01-01T00:00:00.000Z",'
        '"purpose":"conf-join","room":"r"}',
      );
    });
  });
}
