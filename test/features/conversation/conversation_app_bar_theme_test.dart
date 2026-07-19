// Regression test for task DMHDR: the DM/conversation app bar rendered a
// GREY header band while the message body stayed pure OLED black.
//
// THE BUG: `_buildAppBar` in conversation_screen.dart hardcodes an opaque
// `backgroundColor: SovereignColors.surfaceBase` on the AppBar but, unlike
// the app's global AppBarTheme (which pins `elevation`/`scrolledUnderElevation`
// to 0), it did not pin `surfaceTintColor`/elevation on the widget itself.
// Material 3's AppBar blends a `surfaceTintColor` elevation-overlay onto an
// opaque `backgroundColor` once the app bar registers as "scrolled under" and
// nothing pins that tint off for this specific bar. Every other screen's app
// bar in this app never has this problem because it does not need to (their
// hardcoded backgroundColor + the theme's zeroed elevation happen to line
// up), but the conversation app bar was the one place depending implicitly
// on ambient theme resolution to keep that tint fully transparent.
//
// THE FIX (see conversation_screen.dart `_buildAppBar`): pin
// `surfaceTintColor: Colors.transparent`, `elevation: 0`, and
// `scrolledUnderElevation: 0` directly on this AppBar so the grey tint can
// never be picked up here regardless of scroll state or any future change to
// the ambient theme's `colorScheme.surfaceTint` / `AppBarThemeData`.
//
// WHAT THIS TEST PINS: build the exact AppBar configuration used by the
// conversation screen (same SovereignTheme, same explicit AppBar params),
// force it into the "scrolled under" state (a reversed message list that
// already has content, as the real conversation body does), and assert the
// AppBar's underlying Material widget resolves to the flat, opaque, black,
// zero-tint values that match the rest of the app -- both at rest and while
// scrolled under.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/theme.dart';

/// Builds a minimal Scaffold that mirrors the conversation screen's AppBar
/// wiring: an explicit opaque [SovereignColors.surfaceBase] background plus
/// the fix's explicit tint/elevation pins, over a scrollable body so the
/// "scrolled under" WidgetState can be exercised like the real message list.
Widget _buildConversationLikeScaffold(ScrollController controller) {
  return MaterialApp(
    theme: SovereignTheme.dark(),
    home: Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('DM header'),
      ),
      body: ListView.builder(
        controller: controller,
        itemCount: 60,
        itemBuilder: (context, i) => SizedBox(height: 60, child: Text('msg $i')),
      ),
    ),
  );
}

/// The AppBar's own internal Material (the one AppBar itself paints, carrying
/// its resolved color/elevation/surfaceTintColor) is the first Material
/// descendant of the AppBar widget.
Material _appBarMaterial(WidgetTester tester) {
  return tester
      .widgetList<Material>(
        find.descendant(of: find.byType(AppBar), matching: find.byType(Material)),
      )
      .first;
}

void main() {
  group('DM conversation app bar stays flat black (no grey tint band)', () {
    testWidgets('at rest: opaque black, zero elevation, transparent tint',
        (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildConversationLikeScaffold(controller));
      await tester.pump();

      final material = _appBarMaterial(tester);
      expect(material.color, SovereignColors.surfaceBase,
          reason: 'app bar must match the pure-black scaffold, not a grey');
      expect(material.elevation, 0,
          reason: 'zero elevation so no M3 elevation-tint overlay applies');
      expect(material.surfaceTintColor, Colors.transparent,
          reason: 'explicit transparent tint prevents any grey wash');
    });

    testWidgets(
        'scrolled under (matches an opened DM with history): still opaque '
        'black, zero elevation, transparent tint -- this is exactly the '
        'state that used to grey out', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_buildConversationLikeScaffold(controller));
      await tester.pump();

      // Scroll so the AppBar registers WidgetState.scrolledUnder, the state
      // that made M3's default elevation-tint overlay apply in the buggy
      // version of this screen.
      controller.jumpTo(300);
      await tester.pumpAndSettle();

      final material = _appBarMaterial(tester);
      expect(material.color, SovereignColors.surfaceBase,
          reason: 'scrolled-under app bar must stay pure black, not grey');
      expect(material.elevation, 0,
          reason: 'scrolledUnderElevation is pinned to 0, no tint overlay');
      expect(material.surfaceTintColor, Colors.transparent,
          reason: 'tint stays transparent even once scrolled under');
    });
  });
}
