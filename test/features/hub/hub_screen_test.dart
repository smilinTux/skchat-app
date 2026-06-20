import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:skchat/features/hub/hub_screen.dart";
import "package:skchat/features/profile/profile_screen.dart";

/// Wrap the HubScreen in a minimal router that registers the operator
/// destinations, so tapping a tile can be verified to navigate.
///
/// [localIdentityProvider] is overridden with a fixed identity so the screen
/// doesn't reach for the (test-unavailable) Hive box / SKComms daemon.
Widget _wrap(GoRouter router) {
  return ProviderScope(
    overrides: [
      localIdentityProvider.overrideWith(_StubIdentityNotifier.new),
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
    ],
  );
}

void main() {
  testWidgets("renders all operator tiles", (tester) async {
    await tester.pumpWidget(_wrap(_router()));
    await tester.pump();

    expect(find.text("Operator Hub"), findsOneWidget);
    expect(find.text("Cluster"), findsOneWidget);
    expect(find.text("Coord Board"), findsOneWidget);
    expect(find.text("Recordings"), findsOneWidget);
    expect(find.text("Conferences"), findsOneWidget);
    expect(find.text("Groups"), findsOneWidget);
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
}
