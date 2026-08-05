import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/skcode/skcode_pane.dart';
import 'package:skchat/services/audience_token_service.dart';
import 'package:skchat/services/daemon_config.dart';

/// Stub the daemon-URL notifier so the pane resolves an origin without opening
/// Hive in a widget test.
class _StubDaemonConfig extends DaemonConfigNotifier {
  @override
  String build() => 'https://test.local';
}

/// Pump [SkcodePane] with the daemon URL stubbed and the audience-token
/// provider overridden to [token] (null models the mint being off / failed).
/// Overriding the token provider directly keeps the test off the real
/// SKCommsClient / operator-session chain, so it stays deterministic.
Future<void> _pumpPane(WidgetTester tester, {required String? token}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      daemonUrlProvider.overrideWith(_StubDaemonConfig.new),
      audienceTokenForAudienceProvider(kSkcodeAudience).overrideWith(
        (ref) async => token,
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: SkcodePane())),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('SkcodePane builds and shows its Code header + subtitle',
      (tester) async {
    await _pumpPane(tester, token: null);
    expect(find.text('Code'), findsOneWidget);
    expect(find.textContaining('steer agent sessions'), findsOneWidget);
  });

  testWidgets('injects the audience wire token into the hostd client URL',
      (tester) async {
    await _pumpPane(tester, token: 'WIRE-TOK-123');
    // On the (non-web) test VM the embed is the host-URL stub, which renders
    // the resolved URL as selectable text: assert the token is appended as a
    // query param on the /skcode/app client URL.
    expect(
      find.textContaining('/skcode/app?token=WIRE-TOK-123'),
      findsOneWidget,
    );
  });

  testWidgets('loads the client tokenless when minting is off (null token)',
      (tester) async {
    await _pumpPane(tester, token: null);
    // No token query param: the client loads and hostd returns its own gated
    // empty state (honest degrade).
    expect(find.textContaining('/skcode/app'), findsOneWidget);
    expect(find.textContaining('token='), findsNothing);
  });
}
