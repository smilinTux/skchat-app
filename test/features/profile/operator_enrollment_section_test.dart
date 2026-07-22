import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/profile/profile_screen.dart";
import "package:skchat/features/profile/widgets/operator_enrollment_section.dart";
import "package:skchat/services/guest_identity.dart";
import "package:skchat/services/operator_session_service.dart";
import "package:skchat/services/self_identity.dart";
import "package:skchat/services/self_identity_provider.dart";
import "package:skchat/services/spaces_identity_service.dart";

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

/// A [LocalIdentityNotifier] that returns a fixed [LocalIdentity] on build
/// and never schedules `_fetchFromDaemon`, keeping the invalidation test
/// below network-free for the daemon-identity side.
class _FakeLocal extends LocalIdentityNotifier {
  _FakeLocal(this._value);

  final LocalIdentity _value;

  @override
  LocalIdentity build() => _value;
}

/// A [SpacesIdentityNotifier] that returns a fixed [SpacesIdentity] on build
/// instead of reading/generating one from storage, so the pre-enroll (guest)
/// side of [selfIdentityProvider] resolves deterministically too.
class _FakeSpaces extends SpacesIdentityNotifier {
  _FakeSpaces(this._value);

  final SpacesIdentity _value;

  @override
  Future<SpacesIdentity> build() async => _value;
}

String _fakeJwt(int expUnixSeconds) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll("=", "");
  final header = seg({"alg": "none", "typ": "JWT"});
  final payload = seg({"exp": expUnixSeconds, "sub": "operator"});
  return "$header.$payload.SIGNATURE";
}

Widget _wrap(
  OperatorSessionService service, {
  String? Function()? tokenReader,
  void Function(String?)? tokenWriter,
}) {
  return ProviderScope(
    overrides: [operatorSessionServiceProvider.overrideWithValue(service)],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: OperatorEnrollmentSection(
            tokenReader: tokenReader,
            tokenWriter: tokenWriter,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group("platform-agnostic control", () {
    testWidgets("renders the real link control on every platform, no crash", (
      tester,
    ) async {
      final adapter = _CannedAdapter({});
      final dio = Dio()..httpClientAdapter = adapter;
      final service = OperatorSessionService(
        dio: dio,
        baseUrl: "http://localhost:9384",
        identity: _FakeIdentity(),
      );

      await tester.pumpWidget(_wrap(service));
      await tester.pump();

      expect(find.text("Link this device"), findsOneWidget);
      expect(find.byKey(const Key("operator-token-field")), findsOneWidget);
      expect(find.byKey(const Key("operator-enroll-action")), findsOneWidget);
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
      },
    );

    testWidgets("an already-live session on mount shows linked immediately", (
      tester,
    ) async {
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
      "exception, and never crashes",
      (tester) async {
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
      },
    );

    testWidgets("a 401 from enroll/open also shows the friendly message", (
      tester,
    ) async {
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

    testWidgets("a generic network failure shows a friendly fallback message", (
      tester,
    ) async {
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
      expect(find.textContaining("Could not link this device"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group("operator token field (Fix B: paste the token, then link)", () {
    testWidgets("with no token entered, a 403 from enroll/open still shows the "
        "friendly message", (tester) async {
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

      expect(find.byKey(const Key("operator-token-field")), findsOneWidget);

      await tester.tap(find.byKey(const Key("operator-enroll-action")));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text(kNotTrustedOperatorMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      "entering a token and tapping Link sends it as X-Operator-Token on "
      "enroll/open, and enrollment succeeds",
      (tester) async {
        final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        final adapter = _CannedAdapter({
          "/api/v1/auth/enroll/open": {
            "window_nonce": "WIN-TOK",
            "exp": future,
          },
          "/api/v1/auth/enroll": {"device_fp": "deadbeefdeadbeef"},
          "/api/v1/auth/challenge": {"nonce": "N1", "exp": future},
          "/api/v1/auth/session": {
            "session_token": _fakeJwt(future),
            "expires_at": future,
          },
        });
        final dio = Dio()..httpClientAdapter = adapter;
        // Shared, in-memory store standing in for the (web-only, no-op under
        // `flutter test`'s VM target) real operator_token.dart localStorage: the
        // widget's field writes into it, and the service's operatorTokenReader
        // reads from it, exactly mirroring how the real seam connects them in
        // production.
        final tokenStore = _FakeTokenStore();
        final service = OperatorSessionService(
          dio: dio,
          baseUrl: "http://localhost:9384",
          identity: _FakeIdentity(),
          operatorTokenReader: tokenStore.read,
        );

        await tester.pumpWidget(
          _wrap(
            service,
            tokenReader: tokenStore.read,
            tokenWriter: tokenStore.write,
          ),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key("operator-token-field")),
          "SHARED-OPERATOR-SECRET",
        );
        await tester.pump();

        expect(tokenStore.value, "SHARED-OPERATOR-SECRET");

        await tester.tap(find.byKey(const Key("operator-enroll-action")));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.text("This device is linked"), findsOneWidget);

        final openReq = adapter.requests.firstWhere(
          (r) => r.uri.path == "/api/v1/auth/enroll/open",
        );
        expect(openReq.headers["X-Operator-Token"], "SHARED-OPERATOR-SECRET");
        expect(tester.takeException(), isNull);
      },
    );
  });

  group("selfIdentityProvider refresh on enroll (Finding I-1)", () {
    testWidgets(
      "a successful link invalidates selfIdentityProvider, so the trust "
      "tier recomputes to green immediately instead of staying red until "
      "some unrelated rebuild happens to notice hasLiveSession() flipped",
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
        // In-memory token store (NOT the default, real, web-only localStorage
        // seam, a no-op under flutter test's VM target): without a working
        // store, enroll()'s write and hasLiveSession()'s read would not
        // round-trip and this test could not tell a real fix from a no-op.
        final tokenStore = _FakeTokenStore();
        // The REAL OperatorSessionService, not a hasLiveSession()-only fake:
        // selfIdentityProvider reads hasLiveSession(), which is a pure cache
        // read backed by this service's own token store. A successful
        // enroll here genuinely flips it false -> true, the exact condition
        // Finding I-1 is about (Riverpod has no reactive way to observe a
        // plain method call on its own, so without an explicit invalidate,
        // selfIdentityProvider would never notice).
        final service = OperatorSessionService(
          dio: dio,
          baseUrl: "http://localhost:9384",
          identity: _FakeIdentity(),
          tokenReader: tokenStore.read,
          tokenWriter: tokenStore.write,
        );

        final container = ProviderContainer(
          overrides: [
            operatorSessionServiceProvider.overrideWithValue(service),
            localIdentityProvider.overrideWith(
              () => _FakeLocal(
                const LocalIdentity(
                  displayName: "Operator",
                  fingerprint: "deadbeefdeadbeef",
                  pgpKeySize: 4096,
                ),
              ),
            ),
            spacesIdentityProvider.overrideWith(
              () => _FakeSpaces(
                const SpacesIdentity(id: "guestid", displayName: "Guest-X"),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Pre-enroll: no live session yet, so selfIdentityProvider resolves
        // red (guest).
        final before = await container.read(selfIdentityProvider.future);
        expect(before.tier, SelfTrustTier.red);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: OperatorEnrollmentSection(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key("operator-enroll-action")));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.text("This device is linked"), findsOneWidget);

        final after = await container.read(selfIdentityProvider.future);
        expect(after.tier, SelfTrustTier.green);
        expect(after.isOperator, isTrue);
        expect(after.fingerprint, "deadbeefdeadbeef");
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "refreshing an already-linked session also invalidates "
      "selfIdentityProvider",
      (tester) async {
        final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        final store = _FakeTokenStore()..value = _fakeJwt(future);
        final adapter = _CannedAdapter({
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
          tokenReader: store.read,
          tokenWriter: store.write,
        );

        final container = ProviderContainer(
          overrides: [
            operatorSessionServiceProvider.overrideWithValue(service),
            localIdentityProvider.overrideWith(
              () => _FakeLocal(
                const LocalIdentity(
                  displayName: "Operator",
                  fingerprint: "deadbeefdeadbeef",
                  pgpKeySize: 4096,
                ),
              ),
            ),
            spacesIdentityProvider.overrideWith(
              () => _FakeSpaces(
                const SpacesIdentity(id: "guestid", displayName: "Guest-X"),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Already linked (a live cached token), so this starts green.
        final before = await container.read(selfIdentityProvider.future);
        expect(before.tier, SelfTrustTier.green);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: OperatorEnrollmentSection(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text("This device is linked"), findsOneWidget);

        await tester.tap(find.byKey(const Key("operator-enroll-refresh")));
        await tester.pump();
        await tester.pumpAndSettle();

        // Still green (unchanged, no regression), and the refresh path's
        // invalidate did not crash or leave a stale/broken provider state.
        final after = await container.read(selfIdentityProvider.future);
        expect(after.tier, SelfTrustTier.green);
        expect(after.fingerprint, "deadbeefdeadbeef");
        expect(tester.takeException(), isNull);
      },
    );
  });
}
