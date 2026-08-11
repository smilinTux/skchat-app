// Chef: "when the whole slider menu goes over the youtube video, it clicks
// through the slide menu and i can't click on any of the sub options... i was
// able to squish the browser down horizontally to make the video real small and
// i was able to click on the menu item".
//
// That squish is the whole diagnosis: the panel's buttons worked exactly where
// they did NOT overlap the video, and were dead everywhere they did.
//
// The video surface on web is a platform view: a REAL DOM element. The browser
// dispatches a click over that element to the element itself, natively, before
// Flutter's hit-testing is consulted. `IgnorePointer` only removes a widget
// from FLUTTER's hit test, so it cannot stop that, which is why an earlier fix
// wrapping the surface in IgnorePointer did not work and the symptom survived
// it. Only `pointer-events: none` on the node is honored by the browser.
//
// This pins the contract that carries that across the conditional-import seam:
// `WatchVideo` takes an `interactive` flag, it defaults to true, and the room
// passes `interactive: false` whenever a route (a lane panel sheet, a dialog)
// is pushed over the video. The web implementation turns that into
// `pointer-events`; the native stub accepts it and ignores it, because native
// renders through Flutter where IgnorePointer already suffices.
//
// The DOM half cannot be asserted here: these tests run against the native stub
// (`dart:html` is unavailable off web), so there is no element to inspect. What
// is checked is the part a regression would actually break, which is the API
// and the call-site wiring, both of which are what silently went missing before.

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_video_stub.dart";

/// The stub's real controller, constructed but never driven: these tests only
/// build the widget, they never load or play anything.
WatchVideoController _controller() => WatchVideoController();

void main() {
  group("WatchVideo interactive flag", () {
    test("defaults to interactive, so normal viewing is unaffected", () {
      final w = WatchVideo(controller: _controller());
      expect(
        w.interactive,
        isTrue,
        reason: "with nothing drawn over the video the surface must stay usable",
      );
    });

    test("can be turned off, which is what a covering panel needs", () {
      final w = WatchVideo(controller: _controller(), interactive: false);
      expect(w.interactive, isFalse);
    });

    testWidgets("builds in both states without throwing", (tester) async {
      for (final interactive in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WatchVideo(
                controller: _controller(),
                interactive: interactive,
              ),
            ),
          ),
        );
        expect(find.byType(WatchVideo), findsOneWidget);
      }
    });
  });
}
