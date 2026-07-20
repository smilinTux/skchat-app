import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/profile/widgets/operator_enrollment_section.dart";
import "package:skchat/services/guest_identity.dart";
import "package:skchat/services/operator_session_service.dart";

/// Canned-response adapter keyed by path; mirrors the mocking style already
/// established in operator_session_service_test.dart (same project, same
/// service), so this widget test drives the REAL [OperatorSessionService]
/// (no crypto/HTTP reimplemented) against fake wire responses.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
  final Map<String, int> statusOverride = {};
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    final status = statusOverride[path] ?? 200;
    final body = routes[path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Deterministic in-test identity, same shape as the fake used by
/// operator_session_service_test.dart.
class _FakeIdentity implements GuestIdentity {
  bool _cached = false;

  @override
  Future<bool> hasCached() async => _cached;

  @override
  Future<GuestKeypair> ensure() async {
    _cached = true;
    return const GuestKeypair(
      publicKeyB64: "PUB-KEY-B64",
      fingerprint: "deadbeefdeadbeef",
    );
  }

  @override
  Future<String> sign(String data) async =>
      "SIG-${base64Encode(utf8.encode(data))}";

  @override
  Future<void> clear() async {
    _cached = false;
  }
}

/// In-memory token store so an "already linked" test case can prime a live
/// session without depending on the web-only localStorage implementation.
class _FakeTokenStore {
  String? value;
  String? read() => value;
  void write(String? v) => value = v;
}

String _fakeJwt(int expUnixSeconds) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll("=", "");
  final header = seg({"alg": "none", "typ": "JWT"});
  final payload = seg({"exp": expUnixSeconds, "sub": "operator"});
  return "$header.$payload.SIGNATURE";
}

Widget _wrap(OperatorSessionService service, {bool isWeb = true}) {
  return ProviderScope(
    overrides: [
      operatorSessionServiceProvider.overrideWithValue(service),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: OperatorEnrollmentSection(isWeb: isWeb),
        ),
      ),
    ),
  );
}

void main() {
  group("non-web platform", () {
    testWidgets("shows a web-only note instead of the control, no crash",
        (tester) async {
      final adapter = _CannedAdapter({});
      final dio = Dio()..httpClientAdapter = adapter;
      final service = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: _FakeIdentity(),
      );

      await tester.pumpWidget(_wrap(service, isWeb: false));
      await tester.pump();

      expect(
        find.textContaining("supported on the web app for now"),
        findsOneWidget,
      );
      expect(find.byKey(const Key("operator-enroll-action")), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group("happy path", () {
    testWidgets(
        "open -> enroll -> session succeeds and shows the device fingerprint",
        (tester) async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final adapter = _CannedAdapter({
        "/api/v1/auth/enroll/open": {"window_nonce": "WIN-1", "exp": future},
        "/api/v1/auth/enroll": {"device_fp": "deadbeefdeadbeef"},
        "/api/v1/auth/challenge": {"nonce": "N1", "exp": future},
        "/api/v1/auth/session": {
          "session_token": _fakeJwt(future),
          "expires_at": future,
        },
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final service = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: _FakeIdentity(),
      );

      await tester.pumpWidget(_wrap(service));
      await tester.pump();

      // No cached session yet: starts in the "Link this device" state, and
      // the mount-time check must NOT have hit the wire (zero requests).
      expect(find.text("Link this device"), findsOneWidget);
      expect(adapter.requests, isEmpty);

      await tester.tap(find.byKey(const Key("operator-enroll-action")));
      await tester.pump(); // enters the "linking" state
      await tester.pumpAndSettle();

      expect(find.text("This device is linked"), findsOneWidget);
      expect(find.textContaining("DEAD BEEF DEAD BEEF"), findsOneWidget);

      // The three wire calls happened in order: open, enroll, then the
      // challenge-response pair inside ensureSession().
      expect(adapter.requests.map((r) => r.uri.path), [
        "/api/v1/auth/enroll/open",
        "/api/v1/auth/enroll",
        "/api/v1/auth/challenge",
        "/api/v1/auth/session",
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets("an already-live session on mount shows linked immediately",
        (tester) async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final store = _FakeTokenStore()..value = _fakeJwt(future);
      final adapter = _CannedAdapter({});
      final dio = Dio()..httpClientAdapter = adapter;
      final service = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: _FakeIdentity(),
        tokenReader: store.read,
        tokenWriter: store.write,
      );

      await tester.pumpWidget(_wrap(service));
      await tester.pump();
      await tester.pump();

      expect(find.text("This device is linked"), findsOneWidget);
      // hasLiveSession() is a pure cache read, no network call.
      expect(adapter.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group("not-a-trusted-operator error path", () {
    testWidgets(
        "a 403 from enroll/open shows the friendly message, never a raw "
        "exception, and never crashes", (tester) async {
      final adapter = _CannedAdapter({});
      adapter.statusOverride["/api/v1/auth/enroll/open"] = 403;
      final dio = Dio()..httpClientAdapter = adapter;
      final service = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: _FakeIdentity(),
      );

      await tester.pumpWidget(_wrap(service));
      await tester.pump();

      await tester.tap(find.byKey(const Key("operator-enroll-action")));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text(kNotTrustedOperatorMessage), findsOneWidget);
      expect(find.textContaining("DioException"), findsNothing);
      expect(find.textContaining("Exception"), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets("a 401 from enroll/open also shows the friendly message",
        (tester) async {
      final adapter = _CannedAdapter({});
      adapter.statusOverride["/api/v1/auth/enroll/open"] = 401;
      final dio = Dio()..httpClientAdapter = adapter;
      final service = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: _FakeIdentity(),
      );

      await tester.pumpWidget(_wrap(service));
      await tester.pump();

      await tester.tap(find.byKey(const Key("operator-enroll-action")));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text(kNotTrustedOperatorMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets("a generic network failure shows a friendly fallback message",
        (tester) async {
      final adapter = _CannedAdapter({});
      adapter.statusOverride["/api/v1/auth/enroll/open"] = 500;
      final dio = Dio()..httpClientAdapter = adapter;
      final service = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: _FakeIdentity(),
      );

      await tester.pumpWidget(_wrap(service));
      await tester.pump();

      await tester.tap(find.byKey(const Key("operator-enroll-action")));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text(kNotTrustedOperatorMessage), findsNothing);
      expect(
        find.textContaining(
          "Could not link this device",
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
