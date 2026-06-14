import "dart:async";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";
import "package:livekit_client/livekit_client.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/livekit_call_service.dart";
import "../../services/spaces_service.dart";
import "space_chat_panel.dart";
import "watch_panel.dart";
import "screen_share_panel.dart";
import "terminal_panel.dart";
import "doc_panel.dart";
import "whiteboard_panel.dart";
import "space_models.dart";

// ── Soul color ──────────────────────────────────────────────────────────────

Color _soulColorFor(String identity) {
  final key = identity.toLowerCase().split("@").first;
  const known = <String, Color>{
    "lumina": SovereignColors.soulLumina,
    "jarvis": SovereignColors.soulJarvis,
    "chef": SovereignColors.soulChef,
  };
  return known[key] ?? SovereignColors.fromFingerprint(identity);
}

// ── Room state ───────────────────────────────────────────────────────────────

class SpaceRoomState {
  const SpaceRoomState({
    required this.participants,
    required this.isConnected,
    required this.isMicEnabled,
    required this.handRaised,
    this.error,
  });

  final List<LiveKitParticipantSnapshot> participants;
  final bool isConnected;
  final bool isMicEnabled;
  final bool handRaised;
  final String? error;

  SpaceRoomState copyWith({
    List<LiveKitParticipantSnapshot>? participants,
    bool? isConnected,
    bool? isMicEnabled,
    bool? handRaised,
    String? error,
  }) {
    return SpaceRoomState(
      participants: participants ?? this.participants,
      isConnected: isConnected ?? this.isConnected,
      isMicEnabled: isMicEnabled ?? this.isMicEnabled,
      handRaised: handRaised ?? this.handRaised,
      error: error,
    );
  }
}

// ── Notifier ─────────────────────────────────────────────────────────────────

class SpaceRoomNotifier
    extends AutoDisposeFamilyNotifier<SpaceRoomState, SpaceJoin> {
  StreamSubscription<List<LiveKitParticipantSnapshot>>? _partSub;
  StreamSubscription<ConnectionState>? _connSub;

  @override
  SpaceRoomState build(SpaceJoin arg) {
    ref.onDispose(_cancel);
    return const SpaceRoomState(
      participants: [],
      isConnected: false,
      isMicEnabled: false,
      handRaised: false,
    );
  }

  Future<void> connect() async {
    final svc = ref.read(liveKitCallServiceProvider);

    _partSub = svc.participants.listen((list) {
      state = state.copyWith(participants: list);
    });
    _connSub = svc.connectionState.listen((cs) {
      state = state.copyWith(isConnected: cs == ConnectionState.connected);
    });

    try {
      await svc.connectWithToken(wsUrl: arg.url, token: arg.token);
      // Host (or any role granted publish) goes live on mic immediately.
      final canPublish = arg.isHost;
      if (canPublish) {
        await svc.setMicEnabled(true);
      }
      state = state.copyWith(
        participants: svc.currentParticipants,
        isConnected: true,
        isMicEnabled: canPublish,
      );
    } on Object catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> toggleMic() async {
    final svc = ref.read(liveKitCallServiceProvider);
    final next = !state.isMicEnabled;
    await svc.setMicEnabled(next);
    state = state.copyWith(isMicEnabled: next);
  }

  Future<void> raiseHand(String identity) async {
    final spaces = ref.read(spacesServiceProvider);
    try {
      final onStage = await spaces.raiseHand(arg.spaceId, identity: identity);
      state = state.copyWith(handRaised: !onStage);
      if (onStage) {
        // Promoted to speaker — go live.
        await ref.read(liveKitCallServiceProvider).setMicEnabled(true);
        state = state.copyWith(isMicEnabled: true);
      }
    } on Object {
      // Best-effort — leave hand state as-is on failure.
    }
  }

  Future<void> invite(String requester, String identity) =>
      ref.read(spacesServiceProvider).invite(
            arg.spaceId,
            requester: requester,
            identity: identity,
          );

  Future<void> removeFromStage(String requester, String identity) =>
      ref.read(spacesServiceProvider).removeFromStage(
            arg.spaceId,
            requester: requester,
            identity: identity,
          );

  Future<void> kick(String requester, String identity) =>
      ref.read(spacesServiceProvider).kick(
            arg.spaceId,
            requester: requester,
            identity: identity,
          );

  Future<void> end(String requester) =>
      ref.read(spacesServiceProvider).end(arg.spaceId, requester: requester);

  Future<void> leave() async {
    _cancel();
    await ref.read(liveKitCallServiceProvider).leaveRoom();
  }

  void _cancel() {
    _partSub?.cancel();
    _connSub?.cancel();
  }
}

final spaceRoomProvider = AutoDisposeNotifierProviderFamily<SpaceRoomNotifier,
    SpaceRoomState, SpaceJoin>(SpaceRoomNotifier.new);

// ── Screen ───────────────────────────────────────────────────────────────────

/// Live audio-room screen for an SK Space.
///
/// Connects via [LiveKitCallService.connectWithToken] using the role-scoped
/// token in [join]. Renders speaker rings (pulse when speaking), a listener
/// count, host controls, a raise-hand button for listeners, and a REC pill.
class SpaceRoomScreen extends ConsumerStatefulWidget {
  const SpaceRoomScreen({super.key, required this.join, this.recording = false});

  final SpaceJoin join;

  /// Initial recording state (from the directory summary, if known).
  final bool recording;

  @override
  ConsumerState<SpaceRoomScreen> createState() => _SpaceRoomScreenState();
}

class _SpaceRoomScreenState extends ConsumerState<SpaceRoomScreen> {
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  Future<void> _connect() async {
    if (_connected) return;
    _connected = true;
    await ref.read(spaceRoomProvider(widget.join).notifier).connect();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(spaceRoomProvider(widget.join));
    final join = widget.join;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceCard,
      floatingActionButton: st.isConnected
          ? FloatingActionButton(
              heroTag: "lanes-fab",
              backgroundColor: SovereignColors.surfaceRaised,
              onPressed: () => _openLanes(context, join),
              child: const Icon(Icons.dashboard_customize_outlined,
                  color: SovereignColors.textPrimary),
            )
          : null,
      body: st.error != null
          ? _buildError(st.error!)
          : SafeArea(
              child: Column(
                children: [
                  _Header(
                    join: join,
                    state: st,
                    recording: widget.recording,
                    onClose: _leave,
                  ),
                  Expanded(
                    child: st.isConnected
                        ? _Stage(join: join, state: st)
                        : _buildConnecting(),
                  ),
                  _ControlBar(
                    join: join,
                    state: st,
                    onLeave: _leave,
                  ),
                ],
              ),
            ),
    );
  }

  void _openLanes(BuildContext context, SpaceJoin join) {
    showModalBottomSheet(
      context: context,
      backgroundColor: SovereignColors.surfaceCard,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _laneTile(sheetCtx, context, Icons.chat_bubble_outline_rounded, "Chat", SpaceChatPanel(spaceId: join.spaceId, identity: join.identity)),
            _laneTile(sheetCtx, context, Icons.smart_display_outlined, "Watch together", WatchPanel(spaceId: join.spaceId, identity: join.identity)),
            _laneTile(sheetCtx, context, Icons.draw_outlined, "Whiteboard", WhiteboardPanel(spaceId: join.spaceId, identity: join.identity)),
            _laneTile(sheetCtx, context, Icons.description_outlined, "Shared doc", DocPanel(spaceId: join.spaceId, identity: join.identity)),
            _laneTile(sheetCtx, context, Icons.screen_share_outlined, "Screen share", ScreenSharePanel(spaceId: join.spaceId, identity: join.identity)),
            _laneTile(sheetCtx, context, Icons.terminal_rounded, "Terminal", TerminalPanel(spaceId: join.spaceId, identity: join.identity)),
          ],
        ),
      ),
    );
  }

  Widget _laneTile(BuildContext sheetCtx, BuildContext context, IconData icon,
      String label, Widget panel) {
    return ListTile(
      leading: Icon(icon, color: SovereignColors.textSecondary),
      title: Text(label,
          style: const TextStyle(color: SovereignColors.textPrimary)),
      onTap: () {
        Navigator.of(sheetCtx).pop();
        _openLane(context, panel);
      },
    );
  }

  void _openLane(BuildContext context, Widget panel) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: panel,
      ),
    );
  }

  Future<void> _leave() async {
    await ref.read(spaceRoomProvider(widget.join).notifier).leave();
    if (mounted && context.canPop()) context.pop();
  }

  Widget _buildConnecting() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              color: _soulColorFor(widget.join.identity),
              strokeWidth: 2.5,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            "Joining Space...",
            style: TextStyle(
              color: SovereignColors.textSecondary,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: SovereignColors.accentDanger,
              size: 44,
            ),
            const SizedBox(height: 16),
            const Text(
              "Couldn't join Space",
              style: TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 12,
                fontFamily: "JetBrainsMono",
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                if (context.canPop()) context.pop();
              },
              child: const Text("Close"),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Header ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.join,
    required this.state,
    required this.recording,
    required this.onClose,
  });

  final SpaceJoin join;
  final SpaceRoomState state;
  final bool recording;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final listeners =
        state.participants.where((p) => !p.canPublish).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: SovereignColors.textPrimary,
              size: 28,
            ),
            tooltip: "Minimise",
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  join.title.isNotEmpty ? join.title : "Space",
                  style: const TextStyle(
                    color: SovereignColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  state.isConnected
                      ? "$listeners listening"
                      : "connecting...",
                  style: const TextStyle(
                    color: SovereignColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (recording)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: SovereignColors.accentDanger.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: SovereignColors.accentDanger,
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    "REC",
                    style: TextStyle(
                      color: SovereignColors.accentDanger,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      fontFamily: "JetBrainsMono",
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Stage ────────────────────────────────────────────────────────────────────

class _Stage extends ConsumerWidget {
  const _Stage({required this.join, required this.state});

  final SpaceJoin join;
  final SpaceRoomState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Speakers = anyone the LiveKit grant lets publish (a self-muted speaker
    // is still a speaker, just muted) OR the local participant if host (the
    // host's publish grant may not have propagated on the very first frame).
    final speakers = state.participants
        .where((p) => p.canPublish || (p.isLocal && join.isHost))
        .toList();
    final listeners =
        state.participants.where((p) => !speakers.contains(p)).toList();
    // Raised hands: listeners (cannot publish) who asked for the stage.
    final raisedHands = listeners.where((p) => p.handRaised).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (join.isHost && raisedHands.isNotEmpty) ...[
          _sectionLabel("Raised hands", raisedHands.length),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final p in raisedHands)
                _RaisedHand(
                  snapshot: p,
                  onTap: () => _inviteRaisedHand(ref, p.identity),
                ),
            ],
          ),
          const SizedBox(height: 28),
        ],
        _sectionLabel("Speakers", speakers.length),
        const SizedBox(height: 12),
        Wrap(
          spacing: 20,
          runSpacing: 20,
          children: [
            for (final p in speakers)
              _SpeakerRing(
                snapshot: p,
                isHost: join.isHost && p.isLocal,
                onTap: join.isHost && !p.isLocal
                    ? () => _hostActions(context, ref, p.identity)
                    : null,
              ),
          ],
        ),
        if (listeners.isNotEmpty) ...[
          const SizedBox(height: 28),
          _sectionLabel("Listeners", listeners.length),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final p in listeners)
                _ListenerDot(
                  snapshot: p,
                  onTap: join.isHost && !p.isLocal
                      ? () => _hostActions(context, ref, p.identity)
                      : null,
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Host tapped a raised hand — invite them straight to the stage.
  void _inviteRaisedHand(WidgetRef ref, String identity) {
    ref
        .read(spaceRoomProvider(join).notifier)
        .invite(join.identity, identity);
  }

  Widget _sectionLabel(String label, int count) {
    return Row(
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: SovereignColors.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          "$count",
          style: const TextStyle(
            color: SovereignColors.textTertiary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Future<void> _hostActions(
    BuildContext context,
    WidgetRef ref,
    String identity,
  ) async {
    final notifier = ref.read(spaceRoomProvider(join).notifier);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Text(
                    identity,
                    style: const TextStyle(
                      color: SovereignColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.upgrade_rounded,
                  color: SovereignColors.accentEncrypt),
              title: const Text("Invite to speak"),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                notifier.invite(join.identity, identity);
              },
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward_rounded,
                  color: SovereignColors.accentWarning),
              title: const Text("Remove from stage"),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                notifier.removeFromStage(join.identity, identity);
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_rounded,
                  color: SovereignColors.accentDanger),
              title: const Text("Remove from Space"),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                notifier.kick(join.identity, identity);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// A speaker avatar with a soul-colored ring that pulses when speaking.
class _SpeakerRing extends StatelessWidget {
  const _SpeakerRing({
    required this.snapshot,
    required this.isHost,
    this.onTap,
  });

  final LiveKitParticipantSnapshot snapshot;
  final bool isHost;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mediaReduced =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final soul = _soulColorFor(snapshot.identity);
    final speaking = snapshot.isSpeaking;
    final initials =
        snapshot.identity.isNotEmpty ? snapshot.identity[0].toUpperCase() : "?";

    final ringWidth = speaking ? 3.5 : 2.0;

    return Semantics(
      label: "${snapshot.identity}"
          "${snapshot.isLocal ? " (you)" : ""}"
          "${speaking ? ", speaking" : ""}"
          "${snapshot.isMuted ? ", muted" : ""}",
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: Duration(milliseconds: mediaReduced ? 0 : 200),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: soul.withValues(alpha: 0.15),
                border: Border.all(color: soul, width: ringWidth),
                boxShadow: speaking && !mediaReduced
                    ? [
                        BoxShadow(
                          color: soul.withValues(alpha: 0.55),
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                children: [
                  Center(
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: soul,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (snapshot.isMuted)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: SovereignColors.surfaceCard,
                        ),
                        child: const Icon(
                          Icons.mic_off_rounded,
                          size: 13,
                          color: SovereignColors.accentWarning,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 80,
              child: Text(
                snapshot.isLocal ? "You" : snapshot.identity,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: SovereignColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (isHost)
              const Text(
                "host",
                style: TextStyle(
                  color: SovereignColors.textTertiary,
                  fontSize: 10,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ListenerDot extends StatelessWidget {
  const _ListenerDot({required this.snapshot, this.onTap});

  final LiveKitParticipantSnapshot snapshot;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final soul = _soulColorFor(snapshot.identity);
    final initials =
        snapshot.identity.isNotEmpty ? snapshot.identity[0].toUpperCase() : "?";
    return Semantics(
      label: "${snapshot.identity}, listener",
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: soul.withValues(alpha: 0.12),
                border: Border.all(
                  color: soul.withValues(alpha: 0.4),
                  width: 1.5,
                ),
              ),
              child: Center(
                child: Text(
                  initials,
                  style: TextStyle(
                    color: soul.withValues(alpha: 0.9),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 60,
              child: Text(
                snapshot.isLocal ? "You" : snapshot.identity,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: SovereignColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A listener who raised their hand (✋), shown in the host's invite queue.
/// Tapping invites them to the stage.
class _RaisedHand extends StatelessWidget {
  const _RaisedHand({required this.snapshot, required this.onTap});

  final LiveKitParticipantSnapshot snapshot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final soul = _soulColorFor(snapshot.identity);
    final initials =
        snapshot.identity.isNotEmpty ? snapshot.identity[0].toUpperCase() : "?";
    return Semantics(
      label: "${snapshot.identity}, raised hand. Tap to invite to speak.",
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: soul.withValues(alpha: 0.15),
                    border: Border.all(
                      color: SovereignColors.soulLumina,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: soul,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: SovereignColors.surfaceCard,
                    ),
                    child: const Icon(
                      Icons.back_hand_rounded,
                      size: 14,
                      color: SovereignColors.soulLumina,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 68,
              child: Text(
                snapshot.isLocal ? "You" : snapshot.identity,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: SovereignColors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Text(
              "tap to invite",
              style: TextStyle(
                color: SovereignColors.textTertiary,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Control bar ──────────────────────────────────────────────────────────────

class _ControlBar extends ConsumerWidget {
  const _ControlBar({
    required this.join,
    required this.state,
    required this.onLeave,
  });

  final SpaceJoin join;
  final SpaceRoomState state;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(spaceRoomProvider(join).notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (join.isHost)
            _RoundButton(
              icon: state.isMicEnabled
                  ? Icons.mic_rounded
                  : Icons.mic_off_rounded,
              label: state.isMicEnabled ? "Mute" : "Unmute",
              active: !state.isMicEnabled,
              activeColor: SovereignColors.accentWarning,
              onTap: notifier.toggleMic,
            )
          else
            _RoundButton(
              icon: state.handRaised
                  ? Icons.back_hand_rounded
                  : Icons.back_hand_outlined,
              label: state.handRaised ? "Lower" : "Raise hand",
              active: state.handRaised,
              activeColor: SovereignColors.soulLumina,
              onTap: () => notifier.raiseHand(join.identity),
            ),
          if (join.isHost)
            _RoundButton(
              icon: Icons.stop_circle_outlined,
              label: "End",
              active: true,
              activeColor: SovereignColors.accentDanger,
              onTap: () async {
                await notifier.end(join.identity);
                onLeave();
              },
            ),
          _LeaveButton(onTap: onLeave),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final accent = activeColor ?? SovereignColors.soulLumina;
    final bg = active
        ? accent.withValues(alpha: 0.18)
        : const Color(0xFF1A1D22);
    final border = active
        ? accent.withValues(alpha: 0.55)
        : const Color(0xFF2A2D34);

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: bg,
                border: Border.all(color: border, width: 1.5),
              ),
              child: Icon(
                icon,
                color: active ? accent : SovereignColors.textPrimary,
                size: 24,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeaveButton extends StatelessWidget {
  const _LeaveButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: "Leave Space",
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: SovereignColors.accentDanger,
              ),
              child: const Icon(
                Icons.call_end_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Leave",
              style: TextStyle(
                color: SovereignColors.accentDanger,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
