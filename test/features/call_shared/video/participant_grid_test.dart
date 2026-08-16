// The shared multi-party video grid.
//
// The grid itself is a MOVE out of livekit_call_screen.dart (it was private
// there, and Spaces had no equivalent at all), so the regression net for the
// tile chrome is the existing calls suite. What is genuinely NEW, and what
// this file covers, is that the layout decision now comes from the pure
// grid_geometry module instead of a hardcoded 1 / 2 / <=4 / 5+ branch table.
//
// That distinction is the reason the assertions below are about GEOMETRY
// (where the tiles land, how many rows, does the short row centre) rather
// than about pixels of chrome: the shape is what changed hands, from a table
// that only ever knew about a landscape phone to a function of the actual
// available space.
//
// room is deliberately null throughout: with no room there is no track to
// resolve, so every tile falls back to its avatar and no test here needs the
// flutter_webrtc platform channel.
import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/call_shared/video/participant_grid.dart";
import "package:skchat/features/call_shared/video/participant_tile.dart";
import "package:skchat/services/livekit_call_service.dart";

LiveKitParticipantSnapshot _snap(String identity, {bool sharing = false}) =>
    LiveKitParticipantSnapshot(
      identity: identity,
      isLocal: false,
      isMuted: false,
      isCameraEnabled: false,
      isScreenSharing: sharing,
    );

List<LiveKitParticipantSnapshot> _people(int n) =>
    [for (var i = 0; i < n; i++) _snap("member$i")];

/// Mount [grid] inside a box of exactly [width] x [height] so the geometry
/// under test is the geometry asserted, not whatever the default test surface
/// happens to be.
Widget _sized({
  required Widget grid,
  double width = 800,
  double height = 600,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: grid),
        ),
      ),
    ),
  );
}

void main() {
  Finder tiles() => find.byType(ParticipantTile);

  testWidgets("an empty room shows the waiting placeholder, not a grid",
      (t) async {
    await t.pumpWidget(_sized(
      grid: const ParticipantGrid(participants: [], room: null),
    ));
    await t.pump();

    expect(find.byType(EmptyRoomPlaceholder), findsOneWidget);
    expect(tiles(), findsNothing);
  });

  testWidgets("a single participant takes the whole stage", (t) async {
    await t.pumpWidget(_sized(
      grid: ParticipantGrid(participants: [_snap("solo")], room: null),
    ));
    await t.pump();

    expect(tiles(), findsOneWidget);
    // Full stage means exactly that: the tile is the box, with no grid
    // margin eating into it.
    expect(t.getSize(tiles()), const Size(800, 600));
  });

  testWidgets(
      "four participants land on a 2x2 grid: two rows, two distinct columns",
      (t) async {
    await t.pumpWidget(_sized(
      grid: ParticipantGrid(participants: _people(4), room: null),
    ));
    await t.pump();

    expect(tiles(), findsNWidgets(4));
    final rects = [for (var i = 0; i < 4; i++) t.getRect(tiles().at(i))];
    // Row 1 and row 2 sit at different heights.
    expect(rects[0].top, equals(rects[1].top));
    expect(rects[2].top, greaterThan(rects[0].top));
    expect(rects[2].top, equals(rects[3].top));
    // Two columns per row.
    expect(rects[1].left, greaterThan(rects[0].left));
    expect(rects[3].left, greaterThan(rects[2].left));
  });

  testWidgets(
      "a short row is CENTRED rather than left-aligned: three tiles lay out "
      "1 over 2, which the old fixed GridView could not express", (t) async {
    await t.pumpWidget(_sized(
      grid: ParticipantGrid(participants: _people(3), room: null),
    ));
    await t.pump();

    expect(tiles(), findsNWidgets(3));
    final rects = [for (var i = 0; i < 3; i++) t.getRect(tiles().at(i))];
    // computeRowDistribution(3, 2) is [1, 2]: the lone tile is the top row.
    expect(rects[1].top, greaterThan(rects[0].top));
    expect(rects[2].top, equals(rects[1].top));
    // And it is centred over the pair below it.
    final pairCentre = (rects[1].center.dx + rects[2].center.dx) / 2;
    expect(rects[0].center.dx, closeTo(pairCentre, 0.5));
  });

  testWidgets(
      "the shape follows the available space, not the head count: two people "
      "sit side by side in a landscape box and stacked in a portrait one",
      (t) async {
    await t.pumpWidget(_sized(
      grid: ParticipantGrid(participants: _people(2), room: null),
    ));
    await t.pump();
    var rects = [for (var i = 0; i < 2; i++) t.getRect(tiles().at(i))];
    expect(rects[1].left, greaterThan(rects[0].left),
        reason: "landscape: one row of two");
    expect(rects[1].top, equals(rects[0].top));

    await t.pumpWidget(_sized(
      grid: ParticipantGrid(participants: _people(2), room: null),
      width: 400,
      height: 800,
    ));
    await t.pump();
    rects = [for (var i = 0; i < 2; i++) t.getRect(tiles().at(i))];
    expect(rects[1].top, greaterThan(rects[0].top),
        reason: "portrait: two rows of one");
    expect(rects[1].left, equals(rects[0].left));
  });

  testWidgets(
      "more participants than the geometry can fit still shows everyone: the "
      "grid scrolls rather than dropping people", (t) async {
    await t.pumpWidget(_sized(
      grid: ParticipantGrid(participants: _people(8), room: null),
    ));
    await t.pump();

    // Every participant is built, including the ones below the fold.
    expect(tiles(), findsNWidgets(8));
    expect(find.byType(Scrollable), findsWidgets);
    // The last tiles really are off the bottom of the box, which is what
    // "scrolls" has to mean: an unbounded call cannot silently shrink people
    // out of existence to make the head count fit one screen.
    expect(t.getRect(tiles().at(7)).top, greaterThan(600));
  });

  testWidgets(
      "a screen sharer keeps the stage-plus-filmstrip layout, untouched by "
      "the geometry swap", (t) async {
    final people = [
      _snap("viewer0"),
      _snap("sharer", sharing: true),
      _snap("viewer1"),
    ];
    await t.pumpWidget(_sized(
      grid: ParticipantGrid(participants: people, room: null),
    ));
    await t.pump();

    expect(tiles(), findsNWidgets(3));
    // The sharer is promoted to the first (stage) tile and is far larger than
    // the filmstrip tiles below it.
    final stage = t.getRect(tiles().at(0));
    final strip = t.getRect(tiles().at(1));
    expect(stage.height, greaterThan(strip.height * 3));
    expect(strip.top, greaterThan(stage.top));
  });
}
