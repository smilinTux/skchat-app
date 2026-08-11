import "dart:async";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";
import "package:livekit_client/livekit_client.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/livekit_call_service.dart";
import "../../services/peer_trust_store.dart";
import "../identity/widgets/trust_badge.dart";
import "../../services/spaces_service.dart";
import "../call_shared/call_elapsed_timer.dart";
import "../call_shared/reactions.dart";
import "../call_shared/screen_share_source.dart";
import "../calls/call_device_picker.dart";
import "../calls/cast_sheet.dart";
import "space_chat_panel.dart";
import "watch_panel.dart";
import "screen_share_panel.dart";
import "screen_share_helper.dart";
import "stage_content.dart";
import "watch_session.dart";
import "watch_video_stub.dart" if (dart.library.html) "watch_video_web.dart";
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
    this.cameraFacing = CameraPosition.front,
    this.isSharingSystemAudio = false,
    this.error,
  });

  final List<LiveKitParticipantSnapshot> participants;
  final bool isConnected;
  final bool isMicEnabled;
  final bool handRaised;

  /// DECOUPLE: whether the local participant currently has a live content-
  /// audio (system audio) share, mirroring
  /// [LiveKitCallService.isSharingSystemAudio]. Independent of
  /// [isMicEnabled] now (the two tracks no longer collide); used to default
  /// the mic to muted the moment a content share with system audio starts
  /// (see [SpaceRoomNotifier.connect]'s participants listener) and to show
  /// the "mic muted to avoid echo" note near the mic control while both
  /// conditions hold.
  final bool isSharingSystemAudio;

  /// Which way the local camera is currently facing (front/selfie, the
  /// default, or back). Local-only UI state: LiveKit does not surface camera
  /// facing on the participant snapshot, so [SpaceRoomNotifier.goLiveCamera] /
  /// [SpaceRoomNotifier.flipCamera] track it here, seeded by whichever option
  /// the "Go live" chooser picked. Drives the Flip control's target facing
  /// and stays put (harmless) once the camera stops; the next go-live starts
  /// fresh from whatever the chooser is tapped with.
  final CameraPosition cameraFacing;

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
    CameraPosition? cameraFacing,
    bool? isSharingSystemAudio,
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
      cameraFacing: cameraFacing ?? this.cameraFacing,
      isSharingSystemAudio: isSharingSystemAudio ?? this.isSharingSystemAudio,
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
/// DECOUPLE: a speaker sharing system audio (see
/// LiveKitCallService.startScreenShareSystemAudio) now publishes that track
/// as its own distinct TrackSource.screenShareAudio, not
/// TrackSource.microphone, so this lookup unambiguously resolves the VOICE
/// mic only. A host "Mute mic" on that speaker mutes their real mic and
/// leaves their content-audio share untouched (previously it muted whichever
/// microphone-source publication happened to match first, which in practice
/// was the content audio; that ambiguity is gone now that the two are
/// distinct wire sources).
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

  /// DECOUPLE: tracks the previous
  /// [LiveKitCallService.isSharingSystemAudio] value so the participants
  /// listener in [connect] can detect the false -> true transition (a
  /// content share with system audio just started) exactly once, regardless
  /// of which widget triggered [LiveKitCallService.startScreenShareSystemAudio]
  /// (the control bar's own [toggleScreenShare], or ScreenSharePanel calling
  /// the service directly). Not part of [SpaceRoomState]: it is bookkeeping
  /// for edge detection, not UI-observable state (state.isSharingSystemAudio
  /// is the observable mirror).
  bool _wasSharingSystemAudio = false;

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
      final previousLocal = _localSnapshot(state.participants);
      state = state.copyWith(participants: list);
      final isSpeaker = _localCanPublish(list);
      final isInvited = _localInvited(list);
      final currentLocal = _localSnapshot(list);
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
      // DECOUPLE: content audio and the voice mic are independent tracks
      // now (see LiveKitCallService.setMicEnabled / startScreenShareSystemAudio),
      // so nothing stops the mic when a content share with system audio
      // starts. To avoid the speaker's own mic picking up the acoustic echo
      // of their content audio playing out of their speakers, default the
      // mic to MUTED exactly once on the false -> true transition of
      // isSharingSystemAudio, whichever widget started the share (the
      // control bar's toggleScreenShare or ScreenSharePanel calling the
      // service directly both flow through the same svc.participants
      // re-emit). The mic control stays fully available immediately after:
      // this only sets the initial state, it is not a lock.
      final sharingSystemAudioNow = svc.isSharingSystemAudio;
      if (!_wasSharingSystemAudio &&
          sharingSystemAudioNow &&
          state.isMicEnabled) {
        await svc.setMicEnabled(false);
        if (_disposed) return;
        state = state.copyWith(isMicEnabled: false);
      }
      _wasSharingSystemAudio = sharingSystemAudioNow;
      state = state.copyWith(isSharingSystemAudio: sharingSystemAudioNow);
      // SHARECTL-app: the host revoked THIS speaker's video sharing while
      // they were already live (camera or screen). The Stop control is the
      // SAME _RoundButton as Go live, gated on canPublishVideo (see
      // _ControlBar), so it disappears the instant the grant flips,
      // leaving no in-app way to stop an already-live share. Mirrors the
      // demotion auto-mute above: detect the true -> false transition on
      // the LOCAL participant's canPublishVideo and auto-stop whichever
      // video source is still live via the same stopLive path the Stop
      // button itself calls, so the control reverts cleanly to the
      // disabled "Go live" state instead of leaving a stuck live share.
      // This is the cooperative client-side half; a server force-unpublish
      // backstop is being added in parallel for the uncooperative case.
      final wasCanPublishVideo = previousLocal?.canPublishVideo ?? true;
      final isCanPublishVideo = currentLocal?.canPublishVideo ?? true;
      if (wasCanPublishVideo &&
          !isCanPublishVideo &&
          currentLocal != null &&
          (currentLocal.isCameraEnabled || currentLocal.isScreenSharing)) {
        await stopLive(
          isCameraLive: currentLocal.isCameraEnabled,
          isScreenLive: currentLocal.isScreenSharing,
        );
        if (_disposed) return;
      }
    });
    _connSub = svc.connectionState.listen((cs) {
      state = state.copyWith(isConnected: cs == ConnectionState.connected);
    });
    // Mirrors the mic-enabled state whenever LiveKitCallService changes it,
    // for ANY reason (today: an explicit caller toggle). DECOUPLE: content
    // audio (TrackSource.screenShareAudio) is an independent coexisting
    // source and never flips the mic internally, so it is not one of those
    // reasons; see the DECOUPLE doc comment on LiveKitCallService.
    // setMicEnabled. Without this listener, the control-bar label goes
    // stale until the user taps mute/unmute.
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

  /// Go live on camera with the chosen [position] (front, the chooser's
  /// default, or back). Reuses [LiveKitCallService.setCameraEnabled], which
  /// also enforces the camera / screen mutual exclusion (stops an active
  /// screen share first). Records [position] on state so [flipCamera] and
  /// the control bar's Flip control know the current facing.
  ///
  /// Resolves the capture device BEFORE publishing (persisted choice, or the
  /// smart non-virtual default via [LiveKitCallService.resolveCameraDeviceId])
  /// so a bare go-live never lands on the first enumerated device, which on
  /// Linux can be a dead Droidcam/v4l2loopback virtual camera ahead of the
  /// real webcam. Enumeration failure falls back to null (the SDK default
  /// device), matching the pre-fix behavior.
  Future<void> goLiveCamera(CameraPosition position) async {
    final svc = ref.read(liveKitCallServiceProvider);
    String? deviceId;
    try {
      final cams = await svc.enumerateVideoInputs();
      final saved = await CallDevicePrefs.loadCamera();
      deviceId = LiveKitCallService.resolveCameraDeviceId(cams, saved);
    } catch (_) {
      deviceId = null; // fall back to the SDK default device
    }
    await svc.setCameraEnabled(true,
        cameraPosition: position, deviceId: deviceId);
    if (_disposed) return;
    state = state.copyWith(cameraFacing: position);
  }

  /// Flip the live camera between front and back without stopping. Reuses
  /// [LiveKitCallService.switchCameraPosition] (restarts the published
  /// track in place, no unpublish/republish). Visible only while the
  /// camera is the live source (see the control bar's Flip control).
  Future<void> flipCamera() async {
    final next = state.cameraFacing == CameraPosition.front
        ? CameraPosition.back
        : CameraPosition.front;
    await ref.read(liveKitCallServiceProvider).switchCameraPosition(next);
    if (_disposed) return;
    state = state.copyWith(cameraFacing: next);
  }

  /// Stop whichever video source (camera and/or screen) is currently live.
  /// The Go live control becomes "Stop" the moment either is live and tears
  /// down exactly what is live, nothing more.
  Future<void> stopLive({
    required bool isCameraLive,
    required bool isScreenLive,
  }) async {
    final svc = ref.read(liveKitCallServiceProvider);
    if (isCameraLive) await svc.setCameraEnabled(false);
    if (isScreenLive) await svc.setScreenShareEnabled(false);
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

  /// SHARECTL-app: host-only. Disables or restores a speaker's video
  /// sharing (camera + screen-share); their mic is untouched either way.
  /// See the host sheet's "Disable sharing" / "Allow sharing" action above.
  Future<void> setSharing(String requester, String identity,
          {required bool allow}) =>
      ref.read(spacesServiceProvider).setSharing(
            arg.spaceId,
            requester: requester,
            identity: identity,
            allow: allow,
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
      // The multitool used to be a floatingActionButton. A FAB floats ABOVE
      // the body at the bottom-right corner, which is exactly where the
      // control bar draws Leave, so it covered the one control a user needs
      // most when a call goes wrong. It now sits IN the control row with the
      // other controls, where it cannot overlap anything by construction.
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
                    onOpenLanes: () => _openLanes(context, join),
                  ),
                ],
              ),
            ),
    );
  }

  // Y3: the tools menu is a draggable, scrollable, safe-area-aware bottom
  // sheet (was a plain fixed Column that cut the lower tiles off behind
  // mobile Safari's bottom toolbar with no way to reach them). The tiles
  // live in a ListView wired to the sheet's own scrollController, the
  // standard DraggableScrollableSheet pattern, so the sheet drags AND the
  // list scrolls; a grab handle makes it tactile by default.
  void _openLanes(BuildContext context, SpaceJoin join) {
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.30,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Material(
            color: SovereignColors.surfaceCard,
            child: ListView(
              key: const Key("lanesList"),
              controller: scrollController,
              padding: EdgeInsets.only(bottom: bottomSafeArea + 12),
              children: [
                Center(
                  child: Container(
                    key: const Key("lanesGrabHandle"),
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: SovereignColors.textSecondary
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                _laneTile(sheetCtx, context, Icons.chat_bubble_outline_rounded, "Chat", SpaceChatPanel(spaceId: join.spaceId, identity: join.identity)),
                _laneTile(sheetCtx, context, Icons.smart_display_outlined, "Watch together", WatchPanel(spaceId: join.spaceId, identity: join.identity)),
                _laneTile(sheetCtx, context, Icons.draw_outlined, "Whiteboard", WhiteboardPanel(spaceId: join.spaceId, identity: join.identity)),
                _laneTile(sheetCtx, context, Icons.description_outlined, "Shared doc", DocPanel(spaceId: join.spaceId, identity: join.identity)),
                _laneTile(sheetCtx, context, Icons.screen_share_outlined, "Screen share", ScreenSharePanel(spaceId: join.spaceId, identity: join.identity)),
                _laneTile(sheetCtx, context, Icons.terminal_rounded, "Terminal", TerminalPanel(spaceId: join.spaceId, identity: join.identity)),
              ],
            ),
          ),
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
      // Flutter's own handle, not the decorative Container each panel draws.
      // A lane panel is mostly gesture-handling widgets (text fields, buttons,
      // scrollables), and any drag that starts on one of those never reaches
      // the sheet, so there was no reliable place to grab and lower it.
      showDragHandle: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        // An explicit close, because gestures have proven unreliable here and
        // a panel you cannot dismiss traps the whole screen. A button does not
        // care which widget swallowed the drag, whether a platform view ate
        // the pointer, or what the sheet's drag threshold is: it is one tap on
        // a target Flutter definitely owns. The drag handle above stays for
        // people who expect to swipe.
        child: Stack(
          children: [
            panel,
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                icon: const Icon(Icons.close_rounded),
                color: SovereignColors.textSecondary,
                tooltip: "Close",
                onPressed: () => Navigator.of(sheetCtx).pop(),
              ),
            ),
          ],
        ),
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
    // a screen-share OR goes live on camera, it becomes the big main stage
    // above the speaker rings for EVERY role (host, speaker, listener). No
    // live video = normal audio-room layout. resolveStageVideos generalizes
    // the old screen-share-only lookup to also include camera go-lives
    // (TrackSource.camera), see screen_share_helper.dart.
    final videos =
        resolveStageVideos(ref.read(liveKitCallServiceProvider).room,
            state.participants);

    // Watch Together: same shared session the "Watch together" lane tile
    // (WatchPanel) targets, watched here so the stage learns the moment a
    // video is loaded. See resolveStageKind (stage_content.dart) for why
    // live video outranks it.
    final watchArgs =
        WatchSessionArgs(spaceId: join.spaceId, identity: join.identity);
    final watchActive = ref.watch(watchSessionProvider(watchArgs)).isActive;
    final kind = resolveStageKind(videos: videos, watchActive: watchActive);
    final liveVideoOnTop = kind == StageKind.liveVideo;
    // Whether the Watch Together surface belongs in the tree at all right
    // now: either it OWNS the stage (kind == watch) or live video has taken
    // over ON TOP of an already-active watch session, in which case it stays
    // mounted (see _WatchTogetherStage's Offstage wrapper below) instead of
    // being torn down and rebuilt from scratch the next time video ends.
    // (kind == watch) implies watchActive by construction, and the
    // liveVideo-on-top branch below re-checks watchActive directly, so this
    // reduces to watchActive itself; spelled out via the two branches above
    // for what it means, not what it is.
    final watchMounted = watchActive;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (liveVideoOnTop) ...[
          _WatchStage(videos: videos),
          const SizedBox(height: 24),
        ],
        if (watchMounted) ...[
          // Keyed so this stays the SAME element (and therefore the same
          // WatchVideo State) whether it renders right here (kind == watch)
          // or, offstage, after the live-video block above (kind ==
          // liveVideo). Without a stable key, the live-video block above
          // being added/removed shifts this widget's position in the list,
          // which Flutter would (with no key to match on) treat as an
          // unrelated widget appearing at that new slot: it would tear down
          // the old element and mount a fresh one instead of reusing it,
          // exactly the remount this Offstage wrapper exists to prevent.
          Offstage(
            key: ValueKey("watch-together-${join.spaceId}"),
            offstage: liveVideoOnTop,
            child: _WatchTogetherStage(join: join),
          ),
          if (!liveVideoOnTop) const SizedBox(height: 24),
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
              // SHARECTL-app: host-only per-speaker video sharing toggle.
              // Reflects the target's CURRENT permission
              // ([LiveKitParticipantSnapshot.canPublishVideo], derived from
              // their live LiveKit canPublishSources grant): "Disable
              // sharing" while they can still share video, flipping to
              // "Allow sharing" once the host has revoked it. Their mic
              // (canPublish) is untouched by this action either way.
              ListTile(
                leading: Icon(
                  target.canPublishVideo
                      ? Icons.screen_share_outlined
                      : Icons.stop_screen_share_outlined,
                  color: SovereignColors.accentWarning,
                ),
                title: Text(target.canPublishVideo
                    ? "Disable sharing"
                    : "Allow sharing"),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  notifier.setSharing(
                    join.identity,
                    identity,
                    allow: !target.canPublishVideo,
                  );
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
  const _WatchStage({required this.videos});

  final List<StageVideo> videos;

  @override
  Widget build(BuildContext context) {
    final primary = videos.first;
    final others = videos.length - 1;
    final soul = _soulColorFor(primary.identity);
    final who = primary.isLocal ? "You" : primary.identity;
    final verb = primary.isCamera ? "is live on camera" : "is sharing their screen";
    final label = primary.isCamera ? "Live: $who" : "Streaming: $who";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // FullscreenableVideo owns the fullscreen toggle (overlay button,
        // double-tap, Esc / exit control on the pushed route) and pops
        // itself automatically if this tile is removed from the tree
        // (i.e. the share/go-live ends while the viewer is fullscreen). It
        // also wraps this video (screen-share or camera go-live alike) in a
        // ZoomableVideo internally, so the viewer can pinch-to-zoom and pan
        // it both here inline and in fullscreen.
        FullscreenableVideo(
          aspectRatio: 16 / 9,
          borderRadius: 14,
          semanticsLabel: "$who $verb. Pinch to zoom, double-tap for fullscreen.",
          video: VideoTrackRenderer(primary.track),
          // "Streaming: <identity>" / "Live: <identity>" label pill,
          // top-left, in both modes.
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
                    label,
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
            others == 1 ? "+1 other is also live" : "+$others others are also live",
            style: const TextStyle(
              color: SovereignColors.textTertiary,
              fontSize: 11,
            ),
          ),
        ],
        // The system-audio hint only applies to a screen share (the
        // dedicated toggle lives in the Screen share panel); a camera
        // go-live has no such control, so the hint stays screen-only.
        if (primary.isLocal && !primary.isCamera) ...[
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

/// The Watch Together surface on the main stage: the shared video (YouTube /
/// Rumble / direct file) at 16:9, driven by the room's shared
/// [watchSessionProvider] so playback and sync are the SAME session the
/// "Watch together" lane tile (WatchPanel) can also drive, not a second,
/// disconnected player.
///
/// [session.controller]'s declared type is the platform-neutral
/// [WatchController] interface (watch_sync.dart), but the object behind it is
/// always the concrete, platform-specific `WatchVideoController` (the
/// `watchControllerFactoryProvider` default builds one, see
/// watch_session.dart); [WatchVideo] itself needs that concrete type, not
/// just the interface, since its native build() reads fields
/// (`isFilePlayerReady`, `fileController`, `url`) that [WatchController]
/// deliberately does not expose.
class _WatchTogetherStage extends ConsumerWidget {
  const _WatchTogetherStage({required this.join});

  final SpaceJoin join;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args =
        WatchSessionArgs(spaceId: join.spaceId, identity: join.identity);
    final session = ref.watch(watchSessionProvider(args).notifier);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          children: [
            // Stop taking pointers whenever something is pushed over the room
            // (a lane panel, the go-live chooser, any dialog).
            //
            // On web this surface is a platform view, a REAL DOM element, not
            // canvas. DOM elements win pointer events over their own area
            // regardless of what Flutter has drawn on top, so while a bottom
            // sheet is open every drag and tap landing over the video goes to
            // the iframe instead of to the sheet or its scrim. That is a sheet
            // the user cannot lower or dismiss. isCurrent is false exactly
            // while another route sits above this one.
            Positioned.fill(
              child: Builder(builder: (context) {
                // True exactly while nothing is pushed over this route.
                final live = ModalRoute.of(context)?.isCurrent ?? true;
                return IgnorePointer(
                  ignoring: !live,
                  // IgnorePointer alone is not enough on web, which is why the
                  // lane panels' own buttons were unclickable wherever they
                  // overlapped the video: it removes this from FLUTTER's hit
                  // test, but the surface is a real DOM element and the browser
                  // hands a click over it straight to that element first.
                  // `interactive` is what sets pointer-events on the node, and
                  // it is the only part the browser honors.
                  child: WatchVideo(
                    controller: session.controller as WatchVideoController,
                    interactive: live,
                  ),
                );
              }),
            ),
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color:
                          SovereignColors.accentEncrypt.withValues(alpha: 0.6)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.smart_display_outlined,
                        size: 14, color: SovereignColors.textPrimary),
                    SizedBox(width: 6),
                    Text(
                      "Watching together",
                      style: TextStyle(
                        color: SovereignColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A speaker avatar with a soul-colored ring that pulses when speaking.
class _SpeakerRing extends ConsumerWidget {
  const _SpeakerRing({
    required this.snapshot,
    required this.isHost,
    this.onTap,
  });

  final LiveKitParticipantSnapshot snapshot;
  final bool isHost;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaReduced =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final soul = _soulColorFor(snapshot.identity);
    final speaking = snapshot.isSpeaking;
    final initials =
        snapshot.identity.isNotEmpty ? snapshot.identity[0].toUpperCase() : "?";
    // Per-speaker trust tier from the server-set soul_fingerprint (M1b). A
    // missing/keyless fingerprint resolves to `unverifiable` -> no badge.
    final tier = ref
        .watch(peerTrustTierProvider((
          peerId: snapshot.identity,
          fingerprint: snapshot.soulFingerprint,
        )))
        .valueOrNull;
    // Never badge your own tile ("You") — no self record -> false red.
    final showBadge = !snapshot.isLocal &&
        (tier == PeerTrustTier.red || tier == PeerTrustTier.amber);

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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
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
                  if (showBadge) ...[
                    const SizedBox(width: 4),
                    TrustBadge(tier: selfTierForPeer(tier!), compact: true),
                  ],
                ],
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

// ── Go live chooser ─────────────────────────────────────────────────────────

/// The three options the "Go live" chooser offers a speaker: camera facing
/// front (the default) or back, or a desktop screen share.
enum _GoLiveChoice { cameraFront, cameraBack, screen }

/// "Go live" source chooser sheet: Camera (front) [default emphasis], Camera
/// (back), and Screen share (desktop only, hidden on mobile web via the
/// existing isMobileWebProvider guard - Z1: screen capture is impossible on
/// a mobile browser). Matches the room's other action sheets
/// (_hostActions / _laneTile above): a SafeArea'd Column of ListTiles in a
/// rounded surfaceRaised sheet.
///
/// Returns the tapped choice, or null if the sheet was dismissed without a
/// pick (a silent no-op for the caller, same cancelled-pick contract as
/// [resolveScreenShareSource]).
Future<_GoLiveChoice?> _showGoLiveChooser(
  BuildContext context,
  WidgetRef ref,
) {
  final showScreen = !ref.read(isMobileWebProvider);
  return showModalBottomSheet<_GoLiveChoice>(
    context: context,
    backgroundColor: SovereignColors.surfaceRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(
              children: [
                Text(
                  "Go live with",
                  style: TextStyle(
                    color: SovereignColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.videocam_rounded,
                color: SovereignColors.accentEncrypt),
            title: const Text("Camera (front)"),
            onTap: () =>
                Navigator.of(sheetCtx).pop(_GoLiveChoice.cameraFront),
          ),
          ListTile(
            leading: const Icon(Icons.cameraswitch_rounded,
                color: SovereignColors.accentEncrypt),
            title: const Text("Camera (back)"),
            onTap: () =>
                Navigator.of(sheetCtx).pop(_GoLiveChoice.cameraBack),
          ),
          if (showScreen)
            ListTile(
              leading: const Icon(Icons.screen_share_outlined,
                  color: SovereignColors.accentEncrypt),
              title: const Text("Screen share"),
              onTap: () => Navigator.of(sheetCtx).pop(_GoLiveChoice.screen),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

// ── Control bar ──────────────────────────────────────────────────────────────

class _ControlBar extends ConsumerWidget {
  const _ControlBar({
    required this.join,
    required this.state,
    required this.onLeave,
    required this.onOpenLanes,
  });

  final SpaceJoin join;
  final SpaceRoomState state;
  final VoidCallback onLeave;
  final VoidCallback onOpenLanes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(spaceRoomProvider(join).notifier);

    // Local participant snapshot: drives the Go live affordance. Anyone the
    // LiveKit grant lets publish (host or an invited speaker) can go live
    // with a camera or a screen-share; listeners cannot.
    LiveKitParticipantSnapshot? local;
    for (final p in state.participants) {
      if (p.isLocal) {
        local = p;
        break;
      }
    }
    final canShare = join.isHost || (local?.canPublish ?? false);
    final isCameraLive = local?.isCameraEnabled ?? false;
    final isScreenLive = local?.isScreenSharing ?? false;
    // Camera XOR screen: at most one is ever true at a time (enforced
    // service-side, see LiveKitCallService.setCameraEnabled /
    // setScreenShareEnabled), so either flag alone means "live".
    final isLive = isCameraLive || isScreenLive;
    // Mute/unmute is gated on the actual LiveKit publish grant (host OR a
    // promoted speaker), not [SpaceJoin.isHost]: a promoted speaker must get
    // real mic controls without rejoining, and a demoted one must lose them.
    final canPublish = local?.canPublish ?? false;
    // SHARECTL-app: the host can revoke video sources (camera + screen-
    // share) from a speaker independent of their mic. Defaults true (see
    // LiveKitParticipantSnapshot.canPublishVideo doc comment) so this only
    // ever narrows the existing [canShare] affordance, never widens it.
    final canPublishVideoLocal = local?.canPublishVideo ?? true;
    // X1: an outstanding, not-yet-accepted host invite. Independent of the
    // banner's own dismissal (see _InvitedToStageBanner / invitePromptDismissed
    // above): the button stays the accept path even after "Not now".
    final isInvited = _shouldOfferJoinStage(local);

    // Screen-share start: resolves the capture source (desktop needs an
    // explicit one; web keeps its own native picker), then publishes. Shared
    // by the "Screen share" chooser option below.
    Future<void> startScreenShare() async {
      try {
        final resolve = ref.read(screenShareSourceResolverProvider);
        final picked = await resolve(context);
        if (!picked.proceed) return;
        // Content audio. This is the PRIMARY way a host goes live in a Space,
        // so it has to carry desktop audio the same way the Screen share panel
        // does. It used to publish video only, and listeners heard nothing but
        // the host's microphone. The workaround that invites is pointing the
        // MIC input at the loopback device, which collapses content and voice
        // into a single track: muting the mic then also kills the content, and
        // the real microphone stops working. Keep them separate tracks.
        String? systemAudioDeviceId;
        try {
          systemAudioDeviceId = (await ref
                  .read(liveKitCallServiceProvider)
                  .defaultSystemAudioSource())
              ?.deviceId;
        } catch (_) {
          // Best effort, exactly like the panel: a share with no desktop audio
          // is still better than no share at all.
        }
        await notifier.toggleScreenShare(true,
            systemAudioDeviceId: systemAudioDeviceId,
            sourceId: picked.sourceId);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Screen share failed: $e")),
          );
        }
      }
    }

    // Camera go-live: publishes with the chosen facing via
    // SpaceRoomNotifier.goLiveCamera (which reuses
    // LiveKitCallService.setCameraEnabled). A getUserMedia permission deny /
    // no-camera error is non-fatal, mirrors the mic error handling: a plain
    // SnackBar, the room stays connected.
    Future<void> startCamera(CameraPosition position) async {
      try {
        await notifier.goLiveCamera(position);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Camera unavailable: $e")),
          );
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // SHARECTL-app: the host disabled this speaker's own sharing.
          // Go live is hidden below (the canShare && canPublishVideoLocal
          // gate on the _RoundButton further down); mic mute/unmute stays
          // available via the separate canPublish branch, which this flag
          // does not touch.
          if (canShare && !canPublishVideoLocal)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                "The host turned off your sharing",
                style: TextStyle(
                  color: SovereignColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          // DECOUPLE: shown only right after a content share with system
          // audio defaulted the mic to muted (see SpaceRoomNotifier.connect's
          // participants listener). The mic control right below stays fully
          // independent and usable the whole time; this is just the
          // one-time echo-avoidance explainer, not a lock notice.
          if (state.isSharingSystemAudio && !state.isMicEnabled)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                "Mic muted to avoid echo. Unmute to talk; headphones "
                "recommended.",
                style: TextStyle(
                  color: SovereignColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          Row(
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
            // Go live: prominent affordance for the host and any speaker with
            // publish, NOT buried in the lane sheet. Tapping it while NOT live
            // opens the source chooser (Camera front/back, Screen desktop-
            // only); tapping it while EITHER video source is live stops
            // whichever one is live.
            if (canShare && canPublishVideoLocal)
              _RoundButton(
                icon: isLive ? Icons.stop_circle_outlined : Icons.videocam_rounded,
                label: isLive ? "Stop" : "Go live",
                active: isLive,
                activeColor: SovereignColors.accentEncrypt,
                onTap: () async {
                  if (isLive) {
                    await notifier.stopLive(
                      isCameraLive: isCameraLive,
                      isScreenLive: isScreenLive,
                    );
                    return;
                  }
                  final choice = await _showGoLiveChooser(context, ref);
                  if (choice == null) return; // sheet dismissed, silent no-op
                  switch (choice) {
                    case _GoLiveChoice.cameraFront:
                      await startCamera(CameraPosition.front);
                    case _GoLiveChoice.cameraBack:
                      await startCamera(CameraPosition.back);
                    case _GoLiveChoice.screen:
                      // Z1: mobile browsers (iOS Safari, Android Chrome) have
                      // no getDisplayMedia, so a share can never actually
                      // start here. The chooser already hides this option on
                      // mobile web (see _showGoLiveChooser), so this is a
                      // defensive re-check, not the primary guard.
                      if (ref.read(isMobileWebProvider)) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Screen sharing needs the desktop app. Native "
                                "mobile screen share is coming soon. You can "
                                "still watch shares here.",
                              ),
                            ),
                          );
                        }
                        return;
                      }
                      await startScreenShare();
                  }
                },
              ),
            // Flip the live camera between front and back without stopping.
            // Only meaningful (and shown) while the camera is the actual live
            // video source; a live screen share has no facing to flip.
            if (canShare && isCameraLive && canPublishVideoLocal)
              _RoundButton(
                icon: Icons.cameraswitch_rounded,
                label: "Flip",
                activeColor: SovereignColors.soulLumina,
                onTap: notifier.flipCamera,
              ),
            // Live camera/mic device picker (same 1:1-call widget, same
            // liveKitCallServiceProvider): lets a Linux user with a phantom
            // Droidcam/v4l2loopback device switch to the real webcam.
            // Gated the same as "Go live" (can publish video), NOT on
            // isCameraLive: the picker MUST be reachable before the camera is
            // live so a user whose camera did not come up on the right device
            // can select a working one (picking a device publishes it). Gating
            // on isCameraLive was a chicken-and-egg trap (no live camera means
            // no picker means no way to fix a bad default device).
            if (canShare && canPublishVideoLocal)
              const CallDevicePickerButton(size: 56),
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
            // Multitool. Lives here rather than as a floating action button:
            // a FAB sits in the bottom-right corner, on top of Leave.
            _RoundButton(
              icon: Icons.dashboard_customize_outlined,
              label: "Tools",
              onTap: onOpenLanes,
            ),
            _LeaveButton(onTap: onLeave),
            ],
          ),
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
