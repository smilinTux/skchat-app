import "package:flutter/material.dart";
import "package:livekit_client/livekit_client.dart";

import "../../../core/theme/theme.dart";
import "../../../services/livekit_call_service.dart";
import "grid_geometry.dart";
import "participant_tile.dart";

/// The shared multi-party video grid.
///
/// Lifted out of `features/calls/livekit_call_screen.dart`, where it was
/// private and was the only grid in the app that actually rendered unbounded
/// simultaneous video. Spaces had nothing comparable, so this is an
/// extraction, not a rewrite: the screen-share stage, the tile chrome and the
/// unbounded participant count all came across unchanged, and the calls
/// screen's own suite is the regression net that proves it.
///
/// The ONE thing that did change is where the layout decision comes from. The
/// original picked a shape from a hardcoded table (1 full screen, 2 split
/// vertically, up to 4 a fixed 2x2, 5+ a scrolling 2-column grid), which
/// silently encoded one device: a landscape-ish phone. Two people on a
/// desktop got a letterboxed vertical split with the width wasted, and three
/// people got a 2x2 with a hole in the corner. The shape now comes from
/// [computeGridDimensions] and [computeRowDistribution], which answer the same
/// question as a function of the space actually available, so the same widget
/// is correct on a phone, a desktop window and a Space stage without a second
/// table.
///
/// Requires BOUNDED constraints (it is a stage: `Positioned.fill`, `Expanded`,
/// a fixed box). Handing it an unbounded height is a caller bug and the
/// geometry module will throw on it rather than quietly laying out one tile.
class ParticipantGrid extends StatelessWidget {
  const ParticipantGrid({
    super.key,
    required this.participants,
    required this.room,
    this.onTileLongPress,
  });

  final List<LiveKitParticipantSnapshot> participants;
  final Room? room;

  /// Optional per-tile long-press hook, e.g. a conference host removing an
  /// invited agent. Returns null for a participant with no such action
  /// available; the tile then has no gesture layer at all. Unused by every
  /// existing caller (calls, Spaces), so it changes nothing there.
  final VoidCallback? Function(LiveKitParticipantSnapshot)? onTileLongPress;

  @override
  Widget build(BuildContext context) {
    if (participants.isEmpty) {
      return const EmptyRoomPlaceholder();
    }

    // Screen-share stage: if anyone is sharing their screen, promote that tile
    // to a large stage and drop everyone else into a horizontal filmstrip so
    // viewers see the shared content (e.g. Kodi) big. The stage tile resolves
    // to the screen-share video track (screen share wins over camera in
    // resolveTileVideoTrack), and its audio (tab audio or a selected monitor
    // source) plays because LiveKit auto-plays every subscribed audio track.
    // If several people share at once, the first sharer takes the stage.
    //
    // This deliberately does NOT go through the grid geometry: a share is a
    // stage, not a grid, and "one big thing plus everyone else small" is the
    // answer at every size.
    final sharerIndex = participants.indexWhere((p) => p.isScreenSharing);
    if (sharerIndex >= 0) {
      return _buildScreenShareStage(sharerIndex);
    }

    // A lone participant is the stage presentation (no margin, no border, no
    // corner ring), which is also the only case where the tile count cannot
    // teach the geometry anything. Keeping it as an explicit branch means a
    // degenerate box (zero height, not yet measured) can never resolve the
    // grid to 1x1 and hide everybody else behind the first tile.
    if (participants.length == 1) {
      return ParticipantTile(
        snapshot: participants.first,
        room: room,
        fullScreen: true,
        onLongPress: onTileLongPress?.call(participants.first),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final dims = computeGridDimensions(
          tileCount: participants.length,
          availableWidth: constraints.maxWidth,
          availableHeight: constraints.maxHeight,
          // previousRows / previousColumns are left at their defaults: the
          // hysteresis seed needs somewhere to remember the last shape across
          // frames, which is a stateful concern this card does not own. The
          // parameters are the seam for it; nothing here has to change to
          // start feeding them.
        );

        // Everyone fits on one screen: no scrolling, rows share the height.
        if (dims.rows * dims.columns >= participants.length) {
          return Column(
            children: [
              for (final row
                  in _chunk(computeRowDistribution(
                participants.length,
                dims.rows,
              )))
                Expanded(child: _buildRow(row, dims.columns)),
            ],
          );
        }

        // More people than the space can hold at a legible tile size. The old
        // 5+ branch scrolled, and scrolling is still the right answer: a call
        // must never quietly drop participants to make the head count fit,
        // and the alternative (shrinking tiles without limit) reaches
        // unreadable long before it reaches a large room.
        //
        // The geometry still decides how WIDE the grid is and how TALL a tile
        // is, so tiles look the same size they would if everyone had fitted.
        // Only the row count is recomputed, from the columns the geometry
        // chose.
        final scrollRows = (participants.length / dims.columns).ceil();
        final rowHeight =
            (constraints.maxHeight - gridGap * (dims.rows - 1)) / dims.rows;
        return SingleChildScrollView(
          // The control bar floats over the bottom of the stage, so the last
          // row needs room to scroll clear of it.
          padding: const EdgeInsets.only(bottom: 120),
          child: Column(
            children: [
              for (final row in _chunk(computeRowDistribution(
                participants.length,
                scrollRows,
              )))
                SizedBox(
                  height: rowHeight,
                  child: _buildRow(row, dims.columns),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Split [participants] into consecutive rows of the sizes in
  /// [distribution], which is [computeRowDistribution]'s output. Reading order
  /// is preserved: the participant list's order is the only ordering this card
  /// knows about (speaker-driven promotion and pinning are separate work).
  List<List<LiveKitParticipantSnapshot>> _chunk(List<int> distribution) {
    final rows = <List<LiveKitParticipantSnapshot>>[];
    var index = 0;
    for (final count in distribution) {
      rows.add(participants.sublist(index, index + count));
      index += count;
    }
    return rows;
  }

  /// One row of the grid, centred inside a grid [columns] tiles wide.
  ///
  /// Centring uses the geometry module's half-column arithmetic
  /// ([rowStartHalfColumn], [tileColumnSpan]) expressed as flex weights: a
  /// full tile is [tileColumnSpan] flex units and the leading / trailing
  /// padding is however many half columns are left over. Doing it in flex
  /// rather than by measuring keeps the widget free of layout arithmetic of
  /// its own, which is the whole reason the geometry is a pure module.
  Widget _buildRow(List<LiveKitParticipantSnapshot> row, int columns) {
    final leading = rowStartHalfColumn(row.length, columns) - 1;
    final trailing =
        columns * tileColumnSpan - leading - row.length * tileColumnSpan;
    return Row(
      children: [
        if (leading > 0) Spacer(flex: leading),
        for (final p in row)
          Expanded(
            flex: tileColumnSpan,
            child: ParticipantTile(
              snapshot: p,
              room: room,
              onLongPress: onTileLongPress?.call(p),
            ),
          ),
        if (trailing > 0) Spacer(flex: trailing),
      ],
    );
  }

  /// The sharer on a full stage with everyone else in a filmstrip below.
  Widget _buildScreenShareStage(int sharerIndex) {
    final sharer = participants[sharerIndex];
    final others = <LiveKitParticipantSnapshot>[
      for (var i = 0; i < participants.length; i++)
        if (i != sharerIndex) participants[i],
    ];
    return Column(
      children: [
        Expanded(
          child: ParticipantTile(
            snapshot: sharer,
            room: room,
            fullScreen: true,
            onLongPress: onTileLongPress?.call(sharer),
          ),
        ),
        if (others.isNotEmpty)
          SizedBox(
            height: 104,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              itemCount: others.length,
              separatorBuilder: (_, _) => const SizedBox(width: 2),
              itemBuilder: (_, i) => AspectRatio(
                aspectRatio: 1,
                child: ParticipantTile(
                  snapshot: others[i],
                  room: room,
                  onLongPress: onTileLongPress?.call(others[i]),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Empty-room placeholder shown before anyone else joins.
class EmptyRoomPlaceholder extends StatelessWidget {
  const EmptyRoomPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.people_outline_rounded,
            color: SovereignColors.textTertiary,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            'Waiting for participants…',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: SovereignColors.textSecondary,
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w400,
                ),
          ),
        ],
      ),
    );
  }
}
