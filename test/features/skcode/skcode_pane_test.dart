import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/skcode/skcode_pane.dart';
import 'package:skchat/services/daemon_config.dart';

/// Stub the daemon-URL notifier so the pane resolves an origin without opening
/// Hive in a widget test.
class _StubDaemonConfig extends DaemonConfigNotifier {
  @override
  String build() => 'https://test.local';
}

void main() {
  testWidgets('SkcodePane builds and shows its Code header + pairing hint',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [daemonUrlProvider.overrideWith(_StubDaemonConfig.new)],
      child: const MaterialApp(home: Scaffold(body: SkcodePane())),
    ));
    await tester.pump();
    expect(find.text('Code'), findsOneWidget);
    expect(find.textContaining('paired'), findsOneWidget);
  });
}
