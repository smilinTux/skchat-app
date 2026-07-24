import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/calls/widgets/pip_overlay.dart';

class _Fixed extends CallSession {
  _Fixed(this._seed);
  final CallSessionState? _seed;
  @override
  CallSessionState? build() => _seed;
}

Widget _host(CallSessionState? seed) => ProviderScope(
      overrides: [callSessionProvider.overrideWith(() => _Fixed(seed))],
      child: const MaterialApp(home: PiPOverlay(child: Scaffold(body: SizedBox()))),
    );

void main() {
  testWidgets('minimized session shows the pill', (tester) async {
    await tester.pumpWidget(_host(const CallSessionState(
        peer: 'a', peerName: 'A', status: CallSessionStatus.minimized, isMinimized: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsOneWidget);
  });

  testWidgets('no session shows no pill', (tester) async {
    await tester.pumpWidget(_host(null));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsNothing);
  });

  testWidgets('active non-minimized session shows no pill', (tester) async {
    await tester.pumpWidget(_host(const CallSessionState(
        peer: 'a', peerName: 'A', status: CallSessionStatus.active)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsNothing);
  });

  testWidgets('tapping the pill calls restore() and the pill disappears',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        callSessionProvider.overrideWith(() => _Fixed(const CallSessionState(
            peer: 'a',
            peerName: 'A',
            status: CallSessionStatus.minimized,
            isMinimized: true))),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: PiPOverlay(child: Scaffold(body: SizedBox())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsOneWidget);

    await tester.tap(find.byKey(const Key('call-pip-window')));
    await tester.pumpAndSettle();

    final state = container.read(callSessionProvider);
    expect(state!.status, CallSessionStatus.active);
    expect(state.isMinimized, isFalse);
    expect(find.byKey(const Key('call-pip-window')), findsNothing);
  });
}
