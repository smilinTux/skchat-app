import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:skchat/features/conf/conf_screen.dart" show ConfArgs;
import "package:skchat/features/hub/hub_screen.dart";
import "package:skchat/features/profile/profile_screen.dart";
import "package:skchat/services/consent_service.dart";
import "package:skchat/services/operator_session_service.dart";
import "package:skchat/services/self_identity.dart";
import "package:skchat/services/self_identity_provider.dart";

/// Stands in for [OperatorSessionService] so `hub_screen.dart`'s
/// operator-aware synchronous fallback (`selfFingerprintNowFromWidget`,
/// exercised during the microsecond before the overridden
/// [selfIdentityProvider] below has resolved) never reaches the REAL
/// service, whose default construction watches the Hive-backed
/// `daemonUrlProvider` (not initialized in this test).
class _FakeOp extends OperatorSessionService {
  _FakeOp({required this.hasSession});

  final bool hasSession;

  @override
  bool hasLiveSession() => hasSession;
}

/// Wrap the HubScreen in a minimal router that registers the operator
/// destinations, so tapping a tile can be verified to navigate.
///
/// [localIdentityProvider] is overridden with a fixed identity so the screen
/// doesn't reach for the (test-unavailable) Hive box / SKComms daemon.
/// [selfIdentityProvider] defaults to that same fixed identity (as an
/// operator-tier [SelfIdentity]) unless [self] overrides it, so existing
/// tests that only care about navigation keep working unchanged while Task 7
/// tests can pin a guest identity to prove the Conferences tile resolves its
/// OWN self identity rather than the shared daemon identity.
/// [operatorSessionServiceProvider] is overridden to match [self]'s tier
/// (see [_FakeOp]'s doc) since the pre-resolution fallback path reads it.
Widget _wrap(GoRouter router, {SelfIdentity? self}) {
  final effectiveSelf = self ?? _defaultSelfIdentity;
  return ProviderScope(
    overrides: [
      localIdentityProvider.overrideWith(_StubIdentityNotifier.new),
      selfIdentityProvider.overrideWith(
        (ref) async => effectiveSelf,
      ),
      operatorSessionServiceProvider.overrideWithValue(
        _FakeOp(hasSession: effectiveSelf.isOperator),
      ),
      // The Contact Requests tile reads the consent badge count, which would
      // otherwise reach the daemon (via the Hive-backed daemonUrlProvider) —
      // pin it to 0 so the Hub renders without a live daemon / Hive box.
      consentPendingCountProvider.overrideWithValue(0),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

class _StubIdentityNotifier extends LocalIdentityNotifier {
  @override
  LocalIdentity build() => const LocalIdentity(
        displayName: "Test Node",
        fingerprint: "ABCDEF0123456789",
      );
}

/// Mirrors [_StubIdentityNotifier]'s values as the operator-tier
/// [SelfIdentity] shape, the default when a test doesn't care about the
/// self-identity split.
const _defaultSelfIdentity = SelfIdentity(
  displayName: "Test Node",
  id: "ABCDEF0123456789",
  fingerprint: "ABCDEF0123456789",
  tier: SelfTrustTier.green,
  isOperator: true,
);

/// The per-device guest fingerprint, deliberately different from
/// [_StubIdentityNotifier]'s daemon fingerprint so "the Conferences tile
/// used MY per-device identity, not the operator's" can be asserted by
/// equality (and inequality against the daemon value).
const _guestSelfIdentity = SelfIdentity(
  displayName: "Guest-Otter42",
  id: "GUEST0000111122223333",
  fingerprint: "GUEST0000111122223333",
  tier: SelfTrustTier.red,
  isOperator: false,
);

GoRouter _router() {
  Widget stub(String label) => Scaffold(body: Center(child: Text(label)));
  Widget Function(BuildContext, GoRouterState) build(Widget child) =>
      (context, state) => child;
  return GoRouter(
    initialLocation: "/hub",
    routes: [
      GoRoute(path: "/hub", builder: build(const HubScreen())),
      GoRoute(path: "/cluster", builder: build(stub("CLUSTER"))),
      GoRoute(path: "/coord", builder: build(stub("COORD"))),
      GoRoute(path: "/recordings", builder: build(stub("RECORDINGS"))),
      GoRoute(path: "/groups", builder: build(stub("GROUPS"))),
      // Captures the ConfArgs the Conferences tile builds (via `extra`) so
      // Task 7's identity-split assertions can inspect it directly, rather
      // than trying to reconstruct it from rendered text.
      GoRoute(
        path: "/conf",
        builder: (context, state) {
          _lastConfArgs = state.extra as ConfArgs?;
          return const Scaffold(body: Center(child: Text("CONF")));
        },
      ),
    ],
  );
}

/// Set by the `/conf` route builder above; read by the Conferences-tile
/// identity tests below. Reset at the top of each such test.
ConfArgs? _lastConfArgs;

void main() {
  testWidgets("renders all operator tiles", (tester) async {
    await tester.pumpWidget(_wrap(_router()));
    await tester.pump();

    expect(find.text("Operator Hub"), findsOneWidget);
    expect(find.text("Cluster"), findsOneWidget);
    expect(find.text("Coord Board"), findsOneWidget);
    expect(find.text("Recordings"), findsOneWidget);
    expect(find.text("Conferences"), findsOneWidget);

    // Groups + the new Contact Requests tile sit lower in the lazy list — scroll
    // them into view before asserting (the list grew past one viewport).
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text("Groups"), 200,
        scrollable: scrollable);
    expect(find.text("Groups"), findsOneWidget);
    await tester.scrollUntilVisible(find.text("Contact Requests"), 200,
        scrollable: scrollable);
    expect(find.text("Contact Requests"), findsOneWidget);
  });

  testWidgets("Cluster tile navigates to /cluster", (tester) async {
    await tester.pumpWidget(_wrap(_router()));
    await tester.pump();

    await tester.tap(find.text("Cluster"));
    await tester.pumpAndSettle();

    expect(find.text("CLUSTER"), findsOneWidget);
  });

  testWidgets("Coord tile navigates to /coord", (tester) async {
    await tester.pumpWidget(_wrap(_router()));
    await tester.pump();

    await tester.tap(find.text("Coord Board"));
    await tester.pumpAndSettle();

    expect(find.text("COORD"), findsOneWidget);
  });

  testWidgets("Recordings tile navigates to /recordings", (tester) async {
    await tester.pumpWidget(_wrap(_router()));
    await tester.pump();

    await tester.tap(find.text("Recordings"));
    await tester.pumpAndSettle();

    expect(find.text("RECORDINGS"), findsOneWidget);
  });

  // Task 7: the Conferences tile builds ConfArgs.identity from the resolved
  // SELF identity (selfIdentityProvider), not the shared daemon identity
  // (localIdentityProvider). An operator device must still resolve to the
  // daemon fingerprint (unchanged); a guest device must resolve to its own
  // per-device fingerprint, never the operator's.
  group("Conferences tile identity (Task 7)", () {
    setUp(() => _lastConfArgs = null);

    testWidgets("operator: ConfArgs.identity equals the daemon fingerprint",
        (tester) async {
      await tester.pumpWidget(_wrap(_router(), self: _defaultSelfIdentity));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      await tester.tap(find.text("Conferences"));
      await tester.pumpAndSettle();

      expect(_lastConfArgs, isNotNull);
      expect(_lastConfArgs!.identity, _defaultSelfIdentity.fingerprint);
      expect(_lastConfArgs!.name, _defaultSelfIdentity.displayName);
    });

    testWidgets(
        "guest: ConfArgs.identity equals the per-device fingerprint, not "
        "the operator's", (tester) async {
      await tester.pumpWidget(_wrap(_router(), self: _guestSelfIdentity));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      await tester.tap(find.text("Conferences"));
      await tester.pumpAndSettle();

      expect(_lastConfArgs, isNotNull);
      expect(_lastConfArgs!.identity, _guestSelfIdentity.fingerprint);
      expect(_lastConfArgs!.name, _guestSelfIdentity.displayName);
      expect(_lastConfArgs!.identity, isNot(_defaultSelfIdentity.fingerprint));
    });
  });
}
