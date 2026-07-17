import "dart:async";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";
import "package:livekit_client/livekit_client.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/livekit_call_service.dart";
import "../../services/spaces_service.dart";
import "../call_shared/call_elapsed_timer.dart";
import "../call_shared/reactions.dart";
import "../call_shared/screen_share_source.dart";
import "../calls/cast_sheet.dart";
import "space_chat_panel.dart";
import "watch_panel.dart";
import "screen_share_panel.dart";
import "screen_share_helper.dart";
import "fullscreen_video_stage.dart";
import "terminal_panel.dart";
import "doc_panel.dart";
import "whiteboard_panel.dart";
import "space_models.dart";
import "space_share_sheet.dart";

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
    this.externalMuteNonce = 0,
    this.invitePromptDismissed = false,
    this.error,
  });

  final List<LiveKitParticipantSnapshot> participants;
  final bool isConnected;
  final bool isMicEnabled;
  final bool handRaised;

  /// Bumped every time [LiveKitCallService.externalMuteEvents] fires (a
  /// server-initiated mute of OUR mic, e.g. a host force-mute). Not a
  /// boolean flag: the UI layer watches for a CHANGE in this value (see
  /// `_SpaceRoomScreenState.build`'s `ref.listen`) so a "muted by host"
  /// notice fires exactly once per event, including two in a row with the
  /// same underlying isMicEnabled==false state.
  final int externalMuteNonce;

  /// X1: true once the local participant has tapped "Not now" on the
  /// "invited to speak" banner for the CURRENT invite. Local-only, no
  /// endpoint call (see [SpaceRoomNotifier.dismissInvitePrompt]). Reset to
  /// false automatically the next time the participants listener in
  /// [SpaceRoomNotifier.connect] observes a fresh invitedToStage
  /// false -> true transition (a new invite re-arms the prompt).
  final bool invitePromptDismissed;
  final String? error;

  SpaceRoomState copyWith({
    List<LiveKitParticipantSnapshot>? participants,
    bool? isConnected,
    bool? isMicEnabled,
    bool? handRaised,
    int? externalMuteNonce,
    bool? invitePromptDismissed,
    String? error,
  }) {
    return SpaceRoomState(
      participants: participants ?? this.participants,
      isConnected: isConnected ?? this.isConnected,
      isMicEnabled: isMicEnabled ?? this.isMicEnabled,
      handRaised: handRaised ?? this.handRaised,
      externalMuteNonce: externalMuteNonce ?? this.externalMuteNonce,
      invitePromptDismissed:
          invitePromptDismissed ?? this.invitePromptDismissed,
      error: error,
    );
  }
}

// ── Notifier ─────────────────────────────────────────────────────────────────

/// The local participant's current LiveKit publish grant, sourced from the
/// snapshot list (not [SpaceJoin.isHost]). False when the local snapshot has
/// not arrived yet, e.g. the very first connecting frame.
bool _localCanPublish(List<LiveKitParticipantSnapshot> participants) {
  for (final p in participants) {
    if (p.isLocal) return p.canPublish;
  }
  return false;
}

/// The local participant's snapshot, or null before the first participants
/// emission arrives.
LiveKitParticipantSnapshot? _localSnapshot(
    List<LiveKitParticipantSnapshot> participants) {
  for (final p in participants) {
    if (p.isLocal) return p;
  }
  return null;
}

/// True when the local participant has an outstanding host invite to the
/// stage (the moderation layer wrote `invited_to_stage: true` into their
/// metadata). Sourced from the snapshot list the same way [_localCanPublish]
/// is.
bool _localInvited(List<LiveKitParticipantSnapshot> participants) {
  return _localSnapshot(participants)?.invitedToStage ?? false;
}

/// X1: whether to offer "Join stage" (the invited-prompt banner and the
/// control-bar button relabel) for [local] - a host invite that has not yet
/// been acted on (hand not yet raised to accept it) and has not yet
/// completed the publish gate (still a listener). Both surfaces share this
/// one condition so the banner and the button never disagree.
bool _shouldOfferJoinStage(LiveKitParticipantSnapshot? local) {
  if (local == null) return false;
  return local.invitedToStage && !local.handRaised && !local.canPublish;
}

/// The published mic track sid of a REMOTE participant, or null when they
/// have no mic publication (never went live). The server's mute moderation
/// call (MuteRoomTrackRequest) is per-track, so the host mute action resolves
/// the sid from the live room graph, the same identity-keyed lookup
/// resolveScreenShares uses for share tracks.
///
/// NOTE (system audio): a speaker sharing system audio (see
/// LiveKitCallService.startScreenShareSystemAudio) publishes that track at
/// the WIRE level as TrackSource.microphone too, since this SDK version has
/// no supported way to tag a device-captured track screenShareAudio, so this
/// lookup resolves it the same as a voice mic. A host "Mute mic" on that
/// speaker therefore mutes their shared content audio, not a voice mic. That
/// is intended moderation behavior (the host can silence whatever comes out
/// of that participant's microphone-source publication), not a bug.
String? _micTrackSidFor(Room? room, String identity) {
  final remote = room?.remoteParticipants[identity];
  return remote?.getTrackPublicationBySource(TrackSource.microphone)?.sid;
}

class SpaceRoomNotifier
    extends AutoDisposeFamilyNotifier<SpaceRoomState, SpaceJoin> {
  StreamSubscription<List<LiveKitParticipantSnapshot>>? _partSub;
  StreamSubscription<ConnectionState>? _connSub;
  StreamSubscription<bool>? _micSub;
  StreamSubscription<void>? _extMuteSub;

  /// Set by [_cancel] (leave / provider dispose). The async participants
  /// listener below can resume AFTER a fast demote-then-leave has already
  /// disposed this notifier; writing state then throws, so every write
  /// after an await checks this first (mirrors the call_device_picker
  /// mounted guards).
  bool _disposed = false;

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

    _partSub = svc.participants.listen((list) async {
      final wasSpeaker = _localCanPublish(state.participants);
      final wasInvited = _localInvited(state.participants);
      state = state.copyWith(participants: list);
      final isSpeaker = _localCanPublish(list);
      final isInvited = _localInvited(list);
      if (isInvited && !wasInvited) {
        // X1: a fresh invite (false -> true). Clear any earlier dismissal
        // so the "invited to speak" banner (re)appears for THIS invite,
        // even if the local participant dismissed a previous one.
        state = state.copyWith(invitePromptDismissed: false);
      }
      if (wasSpeaker && !isSpeaker && state.isMicEnabled) {
        // Demoted mid-session: the publish grant was revoked. Stop
        // publishing and drop back to the listener control (X Spaces model,
        // no lingering hot mic once the grant is gone).
        await svc.setMicEnabled(false);
        // The await may resume after leave() disposed this notifier.
        if (_disposed) return;
        state = state.copyWith(isMicEnabled: false);
      }
    });
    _connSub = svc.connectionState.listen((cs) {
      state = state.copyWith(isConnected: cs == ConnectionState.connected);
    });
    // Mirrors the mic-enabled state whenever LiveKitCallService changes it
    // for ANY reason, including the system-audio mutual exclusion silently
    // flipping it internally (system audio starting force-disables the mic;
    // enabling the mic force-stops system audio). Without this, the
    // control-bar label goes stale until the user taps mute/unmute.
    _micSub = svc.micEnabledChanges.listen((enabled) {
      if (_disposed) return;
      state = state.copyWith(isMicEnabled: enabled);
    });
    // Surfaces a server-initiated mute (host force-mute) that WE never
    // requested, so the UI can show a "muted by host" notice. The label
    // flip itself is already covered by the micEnabledChanges listener
    // above (the service emits false on that stream too); this is purely
    // the "someone else did this" signal, see LiveKitCallService.
    // externalMuteEvents.
    _extMuteSub = svc.externalMuteEvents.listen((_) {
      if (_disposed) return;
      state = state.copyWith(externalMuteNonce: state.externalMuteNonce + 1);
    });

    try {
      await svc.connectWithToken(wsUrl: arg.url, token: arg.token);
      // The await may resume after leave() disposed this notifier (mirrors
      // the participants-listener guard above).
      if (_disposed) return;
      // ONLY the host goes live on mic at connect time. Any non-host
      // participant, even a speaker rejoining with a pre-authorized
      // publish grant, starts MUTED and self-unmutes via the button (X
      // Spaces convention, no hot-mic surprises on rejoin). Mic control
      // VISIBILITY is separately gated on the actual publish grant in the
      // control bar, and a grant gained later via promotion (see
      // [raiseHand] and the participants listener above) never
      // auto-unmutes either.
      final goLive = arg.isHost;
      if (goLive) {
        await svc.setMicEnabled(true);
        if (_disposed) return;
      }
      state = state.copyWith(
        participants: svc.currentParticipants,
        isConnected: true,
        isMicEnabled: goLive,
      );
    } on Object catch (e) {
      if (_disposed) return;
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> toggleMic() async {
    final svc = ref.read(liveKitCallServiceProvider);
    final next = !state.isMicEnabled;
    await svc.setMicEnabled(next);
    // The await may resume after leave() disposed this notifier (mirrors
    // the participants-listener guard above).
    if (_disposed) return;
    state = state.copyWith(isMicEnabled: next);
  }

  /// Start / stop sharing the local screen (WITH audio) as the watch-party
  /// stream. Reuses [LiveKitCallService.setScreenShareEnabled], which captures
  /// screen audio so the shared surface plays with sound for every listener.
  /// The `isScreenSharing` flag on the participants snapshot drives the UI, so
  /// no extra state is tracked here: the stream update flips the controls and
  /// raises the stage for everyone.
  Future<void> toggleScreenShare(bool enabled,
      {String? systemAudioDeviceId, String? sourceId}) async {
    await ref.read(liveKitCallServiceProvider).setScreenShareEnabled(
          enabled,
          systemAudioDeviceId: systemAudioDeviceId,
          sourceId: sourceId,
        );
  }

  Future<void> raiseHand(String identity) async {
    final spaces = ref.read(spacesServiceProvider);
    try {
      final onStage = await spaces.raiseHand(arg.spaceId, identity: identity);
      state = state.copyWith(handRaised: !onStage);
      // X Spaces model: promotion flips the publish grant (surfaced through
      // the participants stream, see connect() above) but never auto-
      // unmutes. Mic controls become available in the MUTED state; the
      // speaker self-unmutes via toggleMic.
    } on Object {
      // Best-effort, leave hand state as-is on failure.
    }
  }

  /// X1: dismiss the "invited to speak" banner locally for the current
  /// invite. NO endpoint call: declining to join the stage right now is a
  /// local-only choice, the server's invited_to_stage flag (and therefore
  /// the control-bar "Join stage" relabel) is untouched, so the guest can
  /// still tap the control bar later to accept the same invite. Stays
  /// dismissed until [connect]'s participants listener observes a fresh
  /// invite (a false -> true invitedToStage transition), which re-arms it.
  void dismissInvitePrompt() {
    state = state.copyWith(invitePromptDismissed: true);
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

  /// Host force-mutes a speaker's live mic (X Spaces model: strictly
  /// one-directional; there is NO force-unmute anywhere, the speaker
  /// self-unmutes via their own mic control).
  ///
  /// Returns false (no-op, no API call made) when the speaker has no
  /// published mic track to mute, so the caller can surface feedback (e.g.
  /// a snackbar) instead of the action silently doing nothing.
  Future<bool> muteSpeaker(String requester, String identity) async {
    final room = ref.read(liveKitCallServiceProvider).room;
    final trackSid = _micTrackSidFor(room, identity);
    if (trackSid == null) return false;
    await ref.read(spacesServiceProvider).mute(
          arg.spaceId,
          requester: requester,
          identity: identity,
          trackSid: trackSid,
        );
    return true;
  }

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
    await stopActiveCast(ref);
    await ref.read(liveKitCallServiceProvider).leaveRoom();
  }

  void _cancel() {
    _disposed = true;
    _partSub?.cancel();
    _connSub?.cancel();
    _micSub?.cancel();
    _extMuteSub?.cancel();
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

    // A server-initiated mute (host force-mute) arrived: the label already
    // flips via isMicEnabled (state.isMicEnabled watched above), this is
    // the extra non-blocking notice so the target actually notices the
    // mute happened rather than just seeing a stale-looking button flip.
    ref.listen<SpaceRoomState>(spaceRoomProvider(widget.join), (prev, next) {
      if (prev != null && next.externalMuteNonce != prev.externalMuteNonce) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Muted by host")),
        );
      }
    });

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
                    onShare: () => _share(context, join),
                  ),
                  Expanded(
                    child: st.isConnected
                        ? Stack(
                            children: [
                              _Stage(join: join, state: st),
                              // Floating emoji reactions (great for a watch
                              // party) over the stage.
                              const Positioned.fill(child: ReactionsOverlay()),
                            ],
                          )
                        : _buildConnecting(),
                  ),
                  // X1: "The host invited you to speak" prompt. Shown above
                  // the control bar, non-blocking, only while there is an
                  // outstanding invite the local participant has neither
                  // accepted nor dismissed (_shouldOfferJoinStage +
                  // invitePromptDismissed). The control-bar "Join stage"
                  // relabel below stays available even after a dismissal
                  // (dismissing only hides THIS banner, not the invite).
                  if (st.isConnected &&
                      _shouldOfferJoinStage(_localSnapshot(st.participants)) &&
                      !st.invitePromptDismissed)
                    _InvitedToStageBanner(join: join),
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

  /// Opens the Share sheet (share to a skchat chat/group, the OS native
  /// share sheet, or copy-link) for the join link of this Space.
  void _share(BuildContext context, SpaceJoin join) {
    showShareSpaceSheet(context, spaceId: join.spaceId, title: join.title);
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

// ── Invited-to-stage banner (X1) ────────────────────────────────────────────

/// "The host invited you to speak" prompt, shown above the control bar for
/// the local participant while an invite is outstanding (see
/// [_shouldOfferJoinStage]). Non-blocking: it does not stop the guest from
/// doing anything else in the Space, it just offers the accept path so the
/// invite is not otherwise-invisible (the reported X1 bug: "the guest sees
/// NOTHING and never becomes a speaker").
class _InvitedToStageBanner extends ConsumerWidget {
  const _InvitedToStageBanner({required this.join});

  final SpaceJoin join;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(spaceRoomProvider(join).notifier);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: SovereignColors.soulLumina.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: SovereignColors.soulLumina.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.campaign_rounded,
            color: SovereignColors.soulLumina,
            size: 20,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              "The host invited you to speak.",
              style: TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            onPressed: notifier.dismissInvitePrompt,
            child: const Text("Not now"),
          ),
          const SizedBox(width: 4),
          FilledButton(
            // Same accept path as the control-bar "Join stage" button
            // (the existing raise-hand call, which completes the server's
            // AND-gate since invited_to_stage is already true).
            onPressed: () => notifier.raiseHand(join.identity),
            child: const Text("Join stage"),
          ),
        ],
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
    required this.onShare,
  });

  final SpaceJoin join;
  final SpaceRoomState state;
  final bool recording;
  final VoidCallback onClose;
  final VoidCallback onShare;

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
                Row(
                  children: [
                    Text(
                      state.isConnected
                          ? "$listeners listening"
                          : "connecting...",
                      style: const TextStyle(
                        color: SovereignColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    if (state.isConnected) ...[
                      const Text(
                        "  ·  ",
                        style: TextStyle(
                          color: SovereignColors.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                      CallElapsedTimer(isConnected: state.isConnected),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onShare,
            icon: const Icon(
              Icons.ios_share_rounded,
              color: SovereignColors.textPrimary,
              size: 22,
            ),
            tooltip: "Share Space",
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

    // Watch-party stage: the moment ANY participant (local or remote) publishes
    // a screen-share, it becomes the big main stage above the speaker rings for
    // EVERY role (host, speaker, listener). No share = normal audio-room layout.
    final shares =
        resolveScreenShares(ref.read(liveKitCallServiceProvider).room,
            state.participants);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (shares.isNotEmpty) ...[
          _WatchStage(shares: shares),
          const SizedBox(height: 24),
        ],
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
                    ? () => _hostActions(context, ref, p)
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
                      ? () => _hostActions(context, ref, p)
                      : null,
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Host tapped a raised hand, invite them straight to the stage.
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

  /// Host moderation sheet for a participant tile. Actions follow the
  /// target's CURRENT stage state ([LiveKitParticipantSnapshot.canPublish]):
  ///
  /// - Listener (off stage): "Invite to speak" only.
  /// - Speaker (on stage): "Mute mic" + "Remove from stage" (demote). Mute is
  ///   ONE-DIRECTIONAL (X Spaces model): the host can force-mute a live mic
  ///   but there is deliberately NO unmute-participant action; only the
  ///   speaker self-unmutes.
  /// - Everyone: "Remove from Space" (kick).
  ///
  /// Only reachable by the host on someone ELSE's tile (the onTap wiring
  /// above gates on `join.isHost && !p.isLocal`).
  Future<void> _hostActions(
    BuildContext context,
    WidgetRef ref,
    LiveKitParticipantSnapshot target,
  ) async {
    final notifier = ref.read(spaceRoomProvider(join).notifier);
    final identity = target.identity;
    final onStage = target.canPublish;
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
            if (!onStage)
              ListTile(
                leading: const Icon(Icons.upgrade_rounded,
                    color: SovereignColors.accentEncrypt),
                title: const Text("Invite to speak"),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  notifier.invite(join.identity, identity);
                },
              ),
            if (onStage) ...[
              ListTile(
                leading: const Icon(Icons.mic_off_rounded,
                    color: SovereignColors.accentWarning),
                title: const Text("Mute mic"),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  final muted = await notifier.muteSpeaker(
                      join.identity, identity);
                  // No published mic track to mute (e.g. a promoted speaker
                  // who never went live): surface feedback instead of the
                  // action silently doing nothing.
                  if (!muted && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("No live mic to mute")),
                    );
                  }
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
            ],
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

// ── Watch stage ──────────────────────────────────────────────────────────────

/// The big main stage for a watch party: renders the live screen-share
/// [VideoTrack] full-width at 16:9 above the speaker rings, so every
/// participant (host, speaker, listener) sees the shared screen (e.g. the
/// fight) the moment someone goes live. If several people are sharing, the
/// first / most recent is on the stage and the rest are noted below.
///
/// Audio: the shared surface's audio (captured via `captureScreenAudio`) plus
/// the host's mic ride normal LiveKit tracks that autoplay for every
/// subscribed listener. Nothing here mutes or gates them, so the fight is
/// heard as well as seen.
class _WatchStage extends StatelessWidget {
  const _WatchStage({required this.shares});

  final List<ScreenShare> shares;

  @override
  Widget build(BuildContext context) {
    final primary = shares.first;
    final others = shares.length - 1;
    final soul = _soulColorFor(primary.identity);
    final who = primary.isLocal ? "You" : primary.identity;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // FullscreenableVideo owns the fullscreen toggle (overlay button,
        // double-tap, Esc / exit control on the pushed route) and pops
        // itself automatically if this tile is removed from the tree
        // (i.e. the share ends while the viewer is fullscreen).
        FullscreenableVideo(
          aspectRatio: 16 / 9,
          borderRadius: 14,
          semanticsLabel: "$who is sharing their screen",
          video: VideoTrackRenderer(primary.track),
          // "Streaming: <identity>" label pill, top-left, in both modes.
          overlay: Positioned(
            left: 10,
            top: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: soul.withValues(alpha: 0.6)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: soul,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    "Streaming: $who",
                    style: const TextStyle(
                      color: SovereignColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (others > 0) ...[
          const SizedBox(height: 8),
          Text(
            others == 1 ? "+1 other is also sharing" : "+$others others are also sharing",
            style: const TextStyle(
              color: SovereignColors.textTertiary,
              fontSize: 11,
            ),
          ),
        ],
        if (primary.isLocal) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 14,
                color: SovereignColors.textTertiary,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  // The dedicated system-audio toggle in the Screen share
                  // panel (ScreenSharePanel, "Share system audio") captures
                  // and publishes desktop audio directly, so this hint just
                  // points there instead of asking listeners to hand-pick a
                  // PulseAudio monitor device as their mic.
                  "Desktop audio? Turn on \"Share system audio\" in the Screen share panel so listeners hear it.",
                  style: TextStyle(
                    color: SovereignColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
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

    // Local participant snapshot: drives the share affordance. Anyone the
    // LiveKit grant lets publish (host or an invited speaker) can go live with
    // a screen-share; listeners cannot.
    LiveKitParticipantSnapshot? local;
    for (final p in state.participants) {
      if (p.isLocal) {
        local = p;
        break;
      }
    }
    final canShare = join.isHost || (local?.canPublish ?? false);
    final isSharing = local?.isScreenSharing ?? false;
    // Mute/unmute is gated on the actual LiveKit publish grant (host OR a
    // promoted speaker), not [SpaceJoin.isHost]: a promoted speaker must get
    // real mic controls without rejoining, and a demoted one must lose them.
    final canPublish = local?.canPublish ?? false;
    // X1: an outstanding, not-yet-accepted host invite. Independent of the
    // banner's own dismissal (see _InvitedToStageBanner / invitePromptDismissed
    // above): the button stays the accept path even after "Not now".
    final isInvited = _shouldOfferJoinStage(local);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (canPublish)
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
              label: isInvited
                  ? "Join stage"
                  : (state.handRaised ? "Lower" : "Raise hand"),
              active: state.handRaised || isInvited,
              activeColor: SovereignColors.soulLumina,
              // Same call either way (raise hand / accept invite / lower):
              // the server's raise-hand endpoint is what completes the
              // AND-gate when invited_to_stage is already true (X1).
              onTap: () => notifier.raiseHand(join.identity),
            ),
          // Go live: prominent screen-share affordance for the host and any
          // speaker with publish, NOT buried in the lane sheet. Reuses
          // setScreenShareEnabled (which captures screen audio). Doubles as the
          // stop control once live.
          if (canShare)
            _RoundButton(
              icon: isSharing
                  ? Icons.stop_screen_share_rounded
                  : Icons.screen_share_rounded,
              label: isSharing ? "Stop" : "Go live",
              active: isSharing,
              activeColor: SovereignColors.accentEncrypt,
              onTap: () async {
                try {
                  final goingLive = !isSharing;
                  String? sourceId;
                  if (goingLive) {
                    // Desktop needs an explicit capture source before
                    // getDisplayMedia can resolve one; web keeps using its
                    // own native picker. A cancelled desktop pick aborts
                    // silently, no share, no error. Routed through
                    // screenShareSourceResolverProvider (same DI seam as
                    // conf_screen.dart / livekit_call_screen.dart) so a test
                    // can inject a fake resolver; the default IS
                    // resolveScreenShareSource, unchanged.
                    final resolve = ref.read(screenShareSourceResolverProvider);
                    final picked = await resolve(context);
                    if (!picked.proceed) return;
                    sourceId = picked.sourceId;
                  }
                  await notifier.toggleScreenShare(
                    goingLive,
                    sourceId: sourceId,
                  );
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Screen share failed: $e")),
                    );
                  }
                }
              },
            ),
          // Quick emoji reactions: floats to everyone in the Space.
          ReactionsButton(identity: join.identity),
          // Cast the Space's shared video to a TV (Chromecast / AirPlay) over
          // HLS. The Space's live audio + chat stay on the phone.
          _RoundButton(
            icon: Icons.cast_rounded,
            label: ref.watch(activeCastSessionProvider) != null
                ? "Casting"
                : "Cast",
            active: ref.watch(activeCastSessionProvider) != null,
            activeColor: SovereignColors.soulLumina,
            onTap: () => showCastToTvSheet(
              context,
              ref,
              room: join.room,
              // Forward the room token so the backend authorizes the egress
              // start even when casting from a phone over the public Funnel.
              token: join.token,
            ),
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
