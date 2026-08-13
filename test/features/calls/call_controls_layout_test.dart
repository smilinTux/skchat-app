import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The in-call control bar on a phone.
///
/// Two faults reported from real calls, both at the bottom-right corner and
/// both hitting the ONE control you must never have to hunt for:
///
///  1. The collab-panels FAB is a Scaffold `floatingActionButton`, which parks
///     bottom-right by default: it sat directly ON TOP of Leave.
///  2. Eight 56px controls plus labels need ~450px. On a ~390dp phone the bar
///     has ~342px of usable width, so the row overflowed and pushed the
///     rightmost items off: the device picker's label truncated to "Devic" and
///     Leave was jammed against the screen edge.
///
/// These reproduce the geometry rather than the whole call screen, which needs
/// a live LiveKit room. That keeps them honest about what they cover: the
/// layout rule, not the call.
void main() {
  // A Pixel-class phone, matching the reported screenshots.
  const phone = Size(390, 844);

  const controlCount = 8;
  const controlSize = 56.0;
  const barHPadding = 24.0 * 2;
  const controlBarHeight = 116.0;

  Widget _bar({required bool pinLeave}) {
    final scrolling = List.generate(
      controlCount - 1,
      (i) => Container(
        key: ValueKey('control-$i'),
        width: controlSize,
        height: controlSize,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: Colors.blue,
      ),
    );
    final leave = Container(
      key: const Key('leave'),
      width: controlSize,
      height: controlSize,
      color: Colors.red,
    );

    return MaterialApp(
      home: Scaffold(
        floatingActionButton: Padding(
          padding: const EdgeInsets.only(bottom: controlBarHeight),
          child: FloatingActionButton(
            key: const Key('panels-fab'),
            onPressed: () {},
            child: const Icon(Icons.dashboard),
          ),
        ),
        body: Stack(
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                child: pinLeave
                    ? Row(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(children: scrolling),
                            ),
                          ),
                          const SizedBox(width: 12),
                          leave,
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [...scrolling, leave],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  group('in-call control bar on a phone', () {
    testWidgets('the controls genuinely do not fit, so this is a real constraint',
        (tester) async {
      // Guards the premise: if controls ever shrink enough to fit, the pinning
      // below stops being load-bearing and this test should be revisited.
      const needed = controlCount * (controlSize + 8);
      expect(needed, greaterThan(phone.width - barHPadding),
          reason: 'controls should overflow a phone width, else the fix is moot');
    });

    testWidgets('Leave stays fully on screen when the row overflows',
        (tester) async {
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(pinLeave: true));
      await tester.pumpAndSettle();

      final leave = tester.getRect(find.byKey(const Key('leave')));
      expect(leave.right, lessThanOrEqualTo(phone.width),
          reason: 'Leave must not be pushed past the right edge');
      expect(leave.left, greaterThanOrEqualTo(0));
      expect(leave.width, controlSize, reason: 'Leave must not be squeezed');
    });

    testWidgets('the other controls scroll rather than overflowing',
        (tester) async {
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(pinLeave: true));
      await tester.pumpAndSettle();

      // A RenderFlex overflow would have been recorded as an exception.
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('the panels FAB does not cover Leave', (tester) async {
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(pinLeave: true));
      await tester.pumpAndSettle();

      final fab = tester.getRect(find.byKey(const Key('panels-fab')));
      final leave = tester.getRect(find.byKey(const Key('leave')));

      // The whole bug in one assertion: these two must not intersect.
      expect(fab.overlaps(leave), isFalse,
          reason: 'the panels FAB sat on top of the hangup button');
      expect(fab.bottom, lessThanOrEqualTo(leave.top),
          reason: 'the FAB should sit ABOVE the control bar');
    });

    testWidgets('without the lift the FAB really does overlap, proving the guard',
        (tester) async {
      // A negative control: if this ever stops overlapping, the assertion above
      // would pass for the wrong reason and quietly stop protecting anything.
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            floatingActionButton: FloatingActionButton(
              key: const Key('panels-fab'),
              onPressed: () {},
              child: const Icon(Icons.dashboard),
            ),
            body: Align(
              alignment: Alignment.bottomRight,
              child: Container(
                key: const Key('leave'),
                width: controlSize,
                height: controlSize,
                margin: const EdgeInsets.fromLTRB(0, 0, 24, 20),
                color: Colors.red,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fab = tester.getRect(find.byKey(const Key('panels-fab')));
      final leave = tester.getRect(find.byKey(const Key('leave')));
      expect(fab.overlaps(leave), isTrue,
          reason: 'the unlifted FAB should reproduce the reported collision');
    });
  });
}
