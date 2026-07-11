import "package:flutter/material.dart";

import "../../core/theme/sovereign_colors.dart";
import "../spaces/space_chat_panel.dart";
import "../spaces/whiteboard_panel.dart";
import "../spaces/watch_panel.dart";
import "../spaces/terminal_panel.dart";
import "../spaces/screen_share_panel.dart";

/// Shared in-call collaboration panels.
///
/// This is the single reusable substrate that mounts the same collab lanes a
/// Space room offers (chat, whiteboard, watch-together, terminal, screen share)
/// into ANY LiveKit call surface: the sovereign conference screen and the
/// generic SFU call screen. Each panel is the exact widget the Spaces screen
/// uses, driven by [LaneService] over the CURRENT room's LiveKit data channel
/// (the panels bind to the singleton `liveKitCallServiceProvider`) and the
/// server lane store keyed by [roomId] (send + receive live, plus server-mirror
/// catch-up on join). Chat is first and default-selected.
///
/// [roomId] is used as the lane-store key (the conf room id / call room name).
/// It plays the same role the Space id plays in a Space room, so a call gets an
/// isolated lane namespace that late joiners can catch up on.
class InCallPanels extends StatelessWidget {
  const InCallPanels({
    super.key,
    required this.roomId,
    required this.identity,
    this.initialLane = 0,
  });

  /// Lane-store key for this call (conf room id / call room name).
  final String roomId;

  /// Local participant identity (fqid / agent name) used as the "from" tag.
  final String identity;

  /// Index of the lane shown first (0 = Chat).
  final int initialLane;

  static const List<_LaneDef> _lanes = [
    _LaneDef("Chat", Icons.chat_bubble_outline_rounded),
    _LaneDef("Board", Icons.draw_outlined),
    _LaneDef("Watch", Icons.smart_display_outlined),
    _LaneDef("Terminal", Icons.terminal_rounded),
    _LaneDef("Screen", Icons.screen_share_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.92;
    return DefaultTabController(
      length: _lanes.length,
      initialIndex: initialLane.clamp(0, _lanes.length - 1),
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(maxHeight: maxH),
          decoration: const BoxDecoration(
            color: SovereignColors.surfaceCard,
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 6),
                decoration: BoxDecoration(
                  color: SovereignColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.center,
                indicatorColor: SovereignColors.accentEncrypt,
                labelColor: SovereignColors.textPrimary,
                unselectedLabelColor: SovereignColors.textTertiary,
                labelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                tabs: [
                  for (final l in _lanes)
                    Tab(
                      height: 44,
                      icon: Icon(l.icon, size: 18),
                      text: l.label,
                      iconMargin: const EdgeInsets.only(bottom: 2),
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  // Physics off so a horizontal swipe inside a panel (e.g. the
                  // whiteboard canvas) does not accidentally change tabs.
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _fill(SpaceChatPanel(spaceId: roomId, identity: identity)),
                    _fill(WhiteboardPanel(spaceId: roomId, identity: identity)),
                    _fill(WatchPanel(spaceId: roomId, identity: identity)),
                    _fill(TerminalPanel(spaceId: roomId, identity: identity)),
                    _fill(ScreenSharePanel(spaceId: roomId, identity: identity)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Each Spaces panel sizes itself to a fraction of the screen height. Pinning
  /// it to the top of the (bounded) tab view keeps that intrinsic height without
  /// letting it overflow the sheet.
  Widget _fill(Widget panel) => Align(
        alignment: Alignment.topCenter,
        child: panel,
      );
}

class _LaneDef {
  const _LaneDef(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Open the shared in-call collab panels as a scroll-controlled bottom sheet.
///
/// Mount this from any call screen once media is connected. [roomId] is the
/// conf room id / call room name (the lane-store key); [identity] is the local
/// participant identity.
Future<void> showInCallPanels(
  BuildContext context, {
  required String roomId,
  required String identity,
  int initialLane = 0,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => InCallPanels(
      roomId: roomId,
      identity: identity,
      initialLane: initialLane,
    ),
  );
}

/// A floating action button that opens [showInCallPanels] for the current room.
///
/// Drop into a call [Scaffold.floatingActionButton] (shown once connected) to
/// give the call the same collab lanes a Space room has.
class InCallPanelsFab extends StatelessWidget {
  const InCallPanelsFab({
    super.key,
    required this.roomId,
    required this.identity,
  });

  final String roomId;
  final String identity;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      heroTag: "in-call-panels-fab",
      backgroundColor: SovereignColors.surfaceRaised,
      tooltip: "Collab panels",
      onPressed: roomId.isEmpty
          ? null
          : () => showInCallPanels(context, roomId: roomId, identity: identity),
      child: const Icon(
        Icons.dashboard_customize_outlined,
        color: SovereignColors.textPrimary,
      ),
    );
  }
}
