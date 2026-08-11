@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skcode_client/skcode_client.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'package:skcode_standalone/src/standalone_app.dart';
import 'package:skcode_standalone/src/standalone_scaffold.dart';

/// The standalone boot gate (card C-2, spec section 4.1, acceptance criterion
/// "standalone boot test passes with shell == null"): `skcode_standalone`
/// boots headless and the hosted module runs with `shell == null`. This is
/// the guarantee that the standalone runner never depends on a shell being
/// present. Mirrors `apps/skchat_standalone/test/standalone_boot_test.dart`.

/// A probe module that records the [ShellContext] it is built with, so a test
/// can assert the standalone host passes null.
class _RecordingModule implements SkworldModule {
  ShellContext? received;
  bool built = false;

  @override
  String get id => 'probe';

  @override
  ModuleNav get nav =>
      const ModuleNav(label: 'Probe', icon: Icons.bug_report, order: 0);

  @override
  Widget build(BuildContext context, ShellContext? shell) {
    built = true;
    received = shell;
    return const SizedBox.shrink();
  }
}

void main() {
  testWidgets('standalone contract hosts modules with shell == null', (
    tester,
  ) async {
    final probe = _RecordingModule();
    await tester.pumpWidget(
      MaterialApp(
        home: StandaloneScaffold(module: probe),
      ),
    );

    // The named standalone contract is null by construction.
    expect(kStandaloneShell, isNull);
    // The scaffold actually built the module, and did so with a null shell.
    expect(probe.built, isTrue);
    expect(probe.received, isNull);
  });

  testWidgets('SkcodeStandaloneApp boots headless and mounts skcode_client', (
    tester,
  ) async {
    await tester.pumpWidget(const SkcodeStandaloneApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The standalone login gate renders first (its own capauth seam).
    expect(find.text('Enter'), findsOneWidget);

    // Enter the app.
    await tester.tap(find.text('Enter'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The skcode_client subapp surface is now mounted inside the standalone
    // chrome, and it booted without a shell (no exceptions were thrown
    // pumping it). Standalone has no AuthContext yet (card C-4's doc
    // comment on SkcodeSurface: the real capauth login is a follow-up on
    // this same seam), so the sessions rail's poll never fires and renders
    // its honest empty state rather than a session list.
    expect(find.byType(SkcodeSurface), findsOneWidget);
    // `find.text('Code')` alone would match twice here (the surface's own
    // AppBar title AND the standalone chrome's bottom-nav destination
    // label, `StandaloneScaffold` feeding it straight from `nav.label`), so
    // this scopes to the surface's AppBar specifically.
    expect(find.widgetWithText(AppBar, 'Code'), findsOneWidget);
    expect(find.text('No sessions yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
