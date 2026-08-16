import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/core/deploy_freshness.dart";
import "package:skchat/core/widgets/deploy_freshness_banner.dart";
import "package:skchat/services/deploy_freshness_service.dart";

/// A fake that pins the provider's state without ever touching the real
/// [DeployFreshnessNotifier.build] (so no tracker, no probe/HTTP call is
/// ever constructed): `checkNow`/`acknowledge` are inherited unmodified,
/// and both degrade to safe no-ops against a null tracker, exactly like the
/// real notifier does when nothing has completed a first check yet. That is
/// enough for `acknowledge()` to still flip state back to `none`, which is
/// exactly what the "dismiss" and "reload" affordances call.
class _FixedNotifier extends DeployFreshnessNotifier {
  _FixedNotifier(this._initial);
  final DeployFreshnessAction _initial;

  @override
  DeployFreshnessAction build() => _initial;
}

Widget _app(DeployFreshnessAction initial) => ProviderScope(
      overrides: [
        deployFreshnessProvider.overrideWith(() => _FixedNotifier(initial)),
      ],
      child: const MaterialApp(
        home: DeployFreshnessBanner(child: Scaffold(body: Text("app body"))),
      ),
    );

void main() {
  testWidgets("no prompt: the banner does not render at all", (tester) async {
    await tester.pumpWidget(_app(DeployFreshnessAction.none));
    await tester.pump();
    expect(find.byKey(const Key("deploy-freshness-banner")), findsNothing);
    expect(find.text("app body"), findsOneWidget);
  });

  testWidgets("a prompt shows the banner over the app, app content still there",
      (tester) async {
    await tester.pumpWidget(_app(DeployFreshnessAction.prompt));
    await tester.pump();
    expect(find.byKey(const Key("deploy-freshness-banner")), findsOneWidget);
    expect(find.text("app body"), findsOneWidget,
        reason: "the prompt overlays the app, it must not replace it");
  });

  testWidgets("dismissing the banner hides it, without reloading",
      (tester) async {
    await tester.pumpWidget(_app(DeployFreshnessAction.prompt));
    await tester.pump();
    expect(find.byKey(const Key("deploy-freshness-banner")), findsOneWidget);

    await tester.tap(find.byKey(const Key("deploy-freshness-dismiss")));
    await tester.pump();

    expect(find.byKey(const Key("deploy-freshness-banner")), findsNothing);
    // The app is still here: dismissing must never navigate away or reload.
    expect(find.text("app body"), findsOneWidget);
  });

  testWidgets("tapping Reload also clears the banner (and does not crash)",
      (tester) async {
    await tester.pumpWidget(_app(DeployFreshnessAction.prompt));
    await tester.pump();

    await tester.tap(find.byKey(const Key("deploy-freshness-reload")));
    await tester.pump();

    expect(find.byKey(const Key("deploy-freshness-banner")), findsNothing);
  });
}
