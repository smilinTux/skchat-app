import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import '../../core/theme/sovereign_colors.dart';
import '../../services/livekit_call_service.dart';
import '../../services/recordings_service.dart';

// ── Soul-color map for well-known agents ───────────────────────────────────

/// Maps well-known agent identity names to their soul accent colors.
/// Falls back to [SovereignColors.fromFingerprint] for unknown identities.
const Map<String, Color> _kSoulColors = {
  'lumina':   SovereignColors.soulLumina,
  'jarvis':   SovereignColors.soulJarvis,
  'chef':     SovereignColors.soulChef,
  'opus':     Color(0xFFFFA726), // amber — distinct from Jarvis cyan
  'ava':      Color(0xFFEC407A), // rose
  'ara':      Color(0xFF26C6DA), // teal-cyan
  'sentinel': Color(0xFFFF7043), // deep-orange
  'herald':   Color(0xFF66BB6A), // green
  'architect':Color(0xFF5C6BC0), // indigo
  'scholar':  Color(0xFFAB47BC), // purple
  'steward':  Color(0xFF26A69A), // teal
  'coder':    Color(0xFF42A5F5), // blue
};

Color _soulColorFor(String identity) {
  final key = identity.toLowerCase().split('@').first;
  return _kSoulColors[key] ?? SovereignColors.fromFingerprint(identity);
}

// ── Riverpod state for active LiveKit session ─────────────────────────────

/// Immutable state held while the LiveKit screen is mounted.
class LiveKitCallState {
  const LiveKitCallState({
    required this.roomName,
    required this.identity,
    required this.participants,
    required this.isMicEnabled,
    required this.isCameraEnabled,
    required this.isConnected,
    this.isRecording = false,
    this.isScreenSharing = false,
    this.error,
  });

  final String roomName;
  final String identity;
  final List<LiveKitParticipantSnapshot> participants;
  final bool isMicEnabled;
  final bool isCameraEnabled;
  final bool isConnected;

  /// True while a server-side recording is active for this room.
  final bool isRecording;

  /// True while the local participant is publishing a screen-share track.
  final bool isScreenSharing;
  final String? error;

  LiveKitCallState copyWith({
    List<LiveKitParticipantSnapshot>? participants,
    bool? isMicEnabled,
    bool? isCameraEnabled,
    bool? isConnected,
    bool? isRecording,
    bool? isScreenSharing,
    String? error,
  }) {
    return LiveKitCallState(
      roomName: roomName,
      identity: identity,
      participants: participants ?? this.participants,
      isMicEnabled: isMicEnabled ?? this.isMicEnabled,
      isCameraEnabled: isCameraEnabled ?? this.isCameraEnabled,
      isConnected: isConnected ?? this.isConnected,
      isRecording: isRecording ?? this.isRecording,
      isScreenSharing: isScreenSharing ?? this.isScreenSharing,
      error: error,
    );
  }
}

// ── Notifier ──────────────────────────────────────────────────────────────

class LiveKitCallNotifier extends AutoDisposeNotifier<LiveKitCallState?> {
  StreamSubscription<List<LiveKitParticipantSnapshot>>? _participantSub;
  StreamSubscription<ConnectionState>? _connSub;

  @override
  LiveKitCallState? build() => null;

  /// Join the room — mints a token, connects, publishes mic (+ optional cam).
  Future<void> join({
    required String roomName,
    required String identity,
    bool withVideo = false,
  }) async {
    state = LiveKitCallState(
      roomName: roomName,
      identity: identity,
      participants: const [],
      isMicEnabled: true,
      isCameraEnabled: withVideo,
      isConnected: false,
    );

    ref.onDispose(_cancelSubs);
    final svc = ref.read(liveKitCallServiceProvider);

    // Subscribe to participant stream BEFORE joining so we don't miss events.
    _participantSub = svc.participants.listen((list) {
      if (state != null) {
        state = state!.copyWith(participants: list);
      }
    });

    _connSub = svc.connectionState.listen((cs) {
      if (state != null) {
        state = state!.copyWith(
          isConnected: cs == ConnectionState.connected,
        );
      }
    });

    try {
      await svc.joinRoom(
        roomName: roomName,
        identity: identity,
        withVideo: withVideo,
      );
      // Emit initial snapshot.
      if (state != null) {
        state = state!.copyWith(
          participants: svc.currentParticipants,
          isConnected: true,
        );
      }
    } catch (e) {
      state = state?.copyWith(error: e.toString());
    }
  }

  /// Join using a **pre-minted, role-scoped** token (guest/sovereign conf
  /// join) — connects via [LiveKitCallService.connectWithToken] rather than
  /// minting a generic token. Publishes the mic once connected.
  Future<void> joinWithToken({
    required String roomName,
    required String identity,
    required String wsUrl,
    required String token,
    bool withVideo = false,
  }) async {
    state = LiveKitCallState(
      roomName: roomName,
      identity: identity,
      participants: const [],
      isMicEnabled: true,
      isCameraEnabled: withVideo,
      isConnected: false,
    );

    ref.onDispose(_cancelSubs);
    final svc = ref.read(liveKitCallServiceProvider);

    _participantSub = svc.participants.listen((list) {
      if (state != null) state = state!.copyWith(participants: list);
    });
    _connSub = svc.connectionState.listen((cs) {
      if (state != null) {
        state = state!.copyWith(isConnected: cs == ConnectionState.connected);
      }
    });

    try {
      await svc.connectWithToken(wsUrl: wsUrl, token: token);
      await svc.setMicEnabled(true);
      if (withVideo) await svc.setCameraEnabled(true);
      if (state != null) {
        state = state!.copyWith(
          participants: svc.currentParticipants,
          isConnected: true,
        );
      }
    } catch (e) {
      state = state?.copyWith(error: e.toString());
    }
  }

  Future<void> toggleMic() async {
    if (state == null) return;
    final svc = ref.read(liveKitCallServiceProvider);
    final next = !state!.isMicEnabled;
    await svc.setMicEnabled(next);
    state = state!.copyWith(isMicEnabled: next);
  }

  Future<void> toggleCamera() async {
    if (state == null) return;
    final svc = ref.read(liveKitCallServiceProvider);
    final next = !state!.isCameraEnabled;
    await svc.setCameraEnabled(next);
    state = state!.copyWith(isCameraEnabled: next);
  }

  /// Start / stop sharing the local screen. On web this calls
  /// `getDisplayMedia` via the LiveKit client (which surfaces the browser's
  /// screen-picker prompt) and publishes a screen-share video track. Optimistic
  /// flip so the toggle responds immediately; reverts on a publish failure
  /// (e.g. the user cancels the picker).
  Future<void> toggleScreenShare() async {
    if (state == null) return;
    final svc = ref.read(liveKitCallServiceProvider);
    final next = !state!.isScreenSharing;
    state = state!.copyWith(isScreenSharing: next);
    try {
      await svc.setScreenShareEnabled(next);
    } catch (e) {
      if (state != null) {
        state = state!.copyWith(isScreenSharing: !next, error: e.toString());
      }
    }
  }

  /// Start / stop a server-side recording of this room via the recordings
  /// service (POST /livekit/record/start|stop). Optimistically flips the local
  /// recording flag, reverting on a backend error.
  Future<void> toggleRecording() async {
    if (state == null) return;
    final svc = ref.read(recordingsServiceProvider);
    final next = !state!.isRecording;
    // Optimistic flip so the REC badge responds immediately.
    state = state!.copyWith(isRecording: next);
    try {
      if (next) {
        await svc.recordStart(state!.roomName);
      } else {
        await svc.recordStop(state!.roomName);
      }
    } catch (e) {
      // Revert and surface the failure.
      if (state != null) {
        state = state!.copyWith(isRecording: !next, error: e.toString());
      }
    }
  }

  Future<void> leave(BuildContext context) async {
    _cancelSubs();
    final svc = ref.read(liveKitCallServiceProvider);
    await svc.leaveRoom();
    state = null;
    if (context.mounted && context.canPop()) context.pop();
  }

  // Called by ref.onDispose path via AutoDispose — no @override needed.
  void _cancelSubs() {
    _participantSub?.cancel();
    _connSub?.cancel();
  }
}

final liveKitCallProvider =
    AutoDisposeNotifierProvider<LiveKitCallNotifier, LiveKitCallState?>(
  LiveKitCallNotifier.new,
);

// ── Route args ────────────────────────────────────────────────────────────

class LiveKitCallArgs {
  const LiveKitCallArgs({
    required this.roomName,
    required this.identity,
    this.withVideo = false,
    this.displayName,
    this.preMintedToken,
    this.livekitUrl,
  });

  final String roomName;
  final String identity;
  final bool withVideo;

  /// Optional human-readable room/peer title for the app bar.
  final String? displayName;

  /// Pre-minted, role-scoped LiveKit JWT (e.g. from a guest/sovereign conf
  /// join). When set, the screen connects via
  /// [LiveKitCallService.connectWithToken] instead of minting a fresh token.
  final String? preMintedToken;

  /// LiveKit WebSocket URL paired with [preMintedToken].
  final String? livekitUrl;

  /// True when a pre-minted token + ws url are available (deep-link join path).
  bool get hasPreMintedToken =>
      (preMintedToken ?? '').isNotEmpty && (livekitUrl ?? '').isNotEmpty;
}

// ── Screen ────────────────────────────────────────────────────────────────

/// Full-screen LiveKit SFU call screen.
///
/// Usage — navigate via GoRouter with extra args:
/// ```dart
/// context.push(
///   AppRoutes.livekitCall,
///   extra: LiveKitCallArgs(
///     roomName: 'sk-room-lumina-chef',
///     identity: 'chef',
///   ),
/// );
/// ```
///
/// The screen joins the room on first build, renders a live participant grid,
/// and tears the service down when the user leaves.
class LiveKitCallScreen extends ConsumerStatefulWidget {
  const LiveKitCallScreen({
    super.key,
    required this.args,
  });

  final LiveKitCallArgs args;

  @override
  ConsumerState<LiveKitCallScreen> createState() => _LiveKitCallScreenState();
}

class _LiveKitCallScreenState extends ConsumerState<LiveKitCallScreen> {
  bool _joined = false;

  @override
  void initState() {
    super.initState();
    // Kick off join after first frame so the notifier is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) => _join());
  }

  Future<void> _join() async {
    if (_joined) return;
    _joined = true;
    final args = widget.args;
    if (args.hasPreMintedToken) {
      // Deep-link conf join: connect with the role-scoped token directly.
      await ref.read(liveKitCallProvider.notifier).joinWithToken(
            roomName: args.roomName,
            identity: args.identity,
            wsUrl: args.livekitUrl!,
            token: args.preMintedToken!,
            withVideo: args.withVideo,
          );
      return;
    }
    await ref.read(liveKitCallProvider.notifier).join(
          roomName: args.roomName,
          identity: args.identity,
          withVideo: args.withVideo,
        );
  }

  @override
  Widget build(BuildContext context) {
    final callState = ref.watch(liveKitCallProvider);

    return Scaffold(
      backgroundColor: SovereignColors.surfaceCard,
      body: callState == null
          ? _buildConnecting()
          : callState.error != null
              ? _buildError(callState.error!, context)
              : _buildCallBody(callState, context),
    );
  }

  // ── Connecting splash ───────────────────────────────────────────────────

  Widget _buildConnecting() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: _soulColorFor(widget.args.identity),
              strokeWidth: 2.5,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Joining room…',
            style: const TextStyle(
              color: SovereignColors.textSecondary,
              fontSize: 15,
              fontFamily: 'Inter',
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.args.roomName,
            style: TextStyle(
              color: _soulColorFor(widget.args.identity).withValues(alpha: 0.7),
              fontSize: 12,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ],
      ),
    );
  }

  // ── Error view ──────────────────────────────────────────────────────────

  Widget _buildError(String error, BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: SovereignColors.accentDanger,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'Room join failed',
              style: TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: const TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 13,
                fontFamily: 'JetBrainsMono',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _LeaveButton(
              label: 'Close',
              onTap: () {
                if (context.canPop()) context.pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Main call body ──────────────────────────────────────────────────────

  Widget _buildCallBody(LiveKitCallState callState, BuildContext context) {
    return Stack(
      children: [
        // Participant grid fills the screen.
        Positioned.fill(
          child: _ParticipantGrid(
            participants: callState.participants,
            localIdentity: callState.identity,
            room: ref.read(liveKitCallServiceProvider).room,
          ),
        ),

        // Top bar — room name + connection badge.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _TopBar(
            callState: callState,
            displayName: widget.args.displayName,
          ),
        ),

        // Bottom control bar — mic / cam / leave.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _LiveKitControlBar(callState: callState),
        ),
      ],
    );
  }
}

// ── Top bar ────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({required this.callState, this.displayName});

  final LiveKitCallState callState;
  final String? displayName;

  @override
  Widget build(BuildContext context) {
    final safePad = MediaQuery.of(context).padding.top;

    return Container(
      padding: EdgeInsets.fromLTRB(16, safePad + 8, 16, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.75),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        children: [
          // Back / collapse.
          GestureDetector(
            onTap: () {
              if (context.canPop()) context.pop();
            },
            child: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: SovereignColors.textPrimary,
              size: 28,
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName ?? callState.roomName,
                  style: const TextStyle(
                    color: SovereignColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Inter',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: callState.isConnected
                            ? SovereignColors.accentEncrypt
                            : SovereignColors.accentWarning,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      callState.isConnected
                          ? '${callState.participants.length} participant${callState.participants.length == 1 ? '' : 's'}'
                          : 'connecting…',
                      style: const TextStyle(
                        color: SovereignColors.textSecondary,
                        fontSize: 12,
                        fontFamily: 'Inter',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // REC badge — shown while a server-side recording is active.
          if (callState.isRecording) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: SovereignColors.accentDanger.withValues(alpha: 0.2),
                border: Border.all(
                  color: SovereignColors.accentDanger.withValues(alpha: 0.6),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(
                    Icons.fiber_manual_record_rounded,
                    color: SovereignColors.accentDanger,
                    size: 10,
                  ),
                  SizedBox(width: 4),
                  Text(
                    'REC',
                    style: TextStyle(
                      color: SovereignColors.accentDanger,
                      fontSize: 10,
                      fontFamily: 'JetBrainsMono',
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ],

          // Room-name mono badge.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: SovereignColors.surfaceGlass,
              border: Border.all(
                color: SovereignColors.surfaceGlassBorder,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'SFU',
              style: const TextStyle(
                color: SovereignColors.textTertiary,
                fontSize: 10,
                fontFamily: 'JetBrainsMono',
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Participant grid ───────────────────────────────────────────────────────

/// Lays out participant tiles in a responsive grid.
/// 1 participant → full-screen tile.
/// 2 → split vertically.
/// 3-4 → 2×2 grid.
/// 5+ → scrollable 2-column grid.
class _ParticipantGrid extends StatelessWidget {
  const _ParticipantGrid({
    required this.participants,
    required this.localIdentity,
    required this.room,
  });

  final List<LiveKitParticipantSnapshot> participants;
  final String localIdentity;
  final Room? room;

  @override
  Widget build(BuildContext context) {
    if (participants.isEmpty) {
      return const _EmptyRoomPlaceholder();
    }

    if (participants.length == 1) {
      return _ParticipantTile(
        snapshot: participants.first,
        room: room,
        fullScreen: true,
      );
    }

    if (participants.length == 2) {
      return Column(
        children: participants
            .map((p) => Expanded(
                  child: _ParticipantTile(snapshot: p, room: room),
                ))
            .toList(),
      );
    }

    // 3-4: fixed 2×2.
    if (participants.length <= 4) {
      return GridView.count(
        crossAxisCount: 2,
        childAspectRatio: 1,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        physics: const NeverScrollableScrollPhysics(),
        children: participants
            .map((p) => _ParticipantTile(snapshot: p, room: room))
            .toList(),
      );
    }

    // 5+: scrollable grid.
    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 120),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: participants.length,
      itemBuilder: (_, i) => _ParticipantTile(
        snapshot: participants[i],
        room: room,
      ),
    );
  }
}

/// Empty-room placeholder shown before anyone else joins.
class _EmptyRoomPlaceholder extends StatelessWidget {
  const _EmptyRoomPlaceholder();

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
          const Text(
            'Waiting for participants…',
            style: TextStyle(
              color: SovereignColors.textSecondary,
              fontSize: 15,
              fontFamily: 'Inter',
            ),
          ),
        ],
      ),
    );
  }
}

// ── Participant tile ───────────────────────────────────────────────────────

/// One tile in the grid — video or avatar fallback.
class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.snapshot,
    required this.room,
    this.fullScreen = false,
  });

  final LiveKitParticipantSnapshot snapshot;
  final Room? room;
  final bool fullScreen;

  @override
  Widget build(BuildContext context) {
    final soul = _soulColorFor(snapshot.identity);
    final videoTrack = _resolveVideoTrack();
    // Active-speaker highlight: a brighter, thicker soul-color ring while the
    // participant is speaking (LiveKit audio-level detection).
    final speaking = snapshot.isSpeaking;

    return Container(
      margin: fullScreen ? EdgeInsets.zero : const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: SovereignColors.surfaceCard,
        border: Border.all(
          color: speaking
              ? soul
              : (fullScreen
                  ? Colors.transparent
                  : soul.withValues(alpha: 0.25)),
          width: speaking ? 3 : (fullScreen ? 0 : 1.5),
        ),
        boxShadow: speaking
            ? [BoxShadow(color: soul.withValues(alpha: 0.5), blurRadius: 12)]
            : null,
      ),
      child: Stack(
        fit: fullScreen ? StackFit.expand : StackFit.passthrough,
        children: [
          // Video layer or avatar fallback.
          if (videoTrack != null)
            Positioned.fill(
              child: VideoTrackRenderer(videoTrack),
            )
          else
            _AvatarTile(
              identity: snapshot.identity,
              soulColor: soul,
              isLocal: snapshot.isLocal,
            ),

          // Bottom info strip — name + mic state.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.65),
                  ],
                ),
              ),
              child: Row(
                children: [
                  // Soul-color ring indicator.
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: soul,
                      boxShadow: [
                        BoxShadow(
                          color: soul.withValues(alpha: 0.6),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Text(
                      snapshot.isLocal
                          ? '${snapshot.identity} (you)'
                          : snapshot.identity,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Inter',
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 4)
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Mic icon.
                  if (snapshot.isMuted)
                    const Icon(
                      Icons.mic_off_rounded,
                      color: SovereignColors.accentWarning,
                      size: 14,
                    ),
                ],
              ),
            ),
          ),

          // Soul-color corner ring — 3px arc on top-left when not full-screen.
          if (!fullScreen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [soul, soul.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Find the best [VideoTrack] for this snapshot in the live [Room].
  ///
  /// Prefers a published screen-share track (so a shared screen takes over the
  /// tile), falling back to the camera track. Returns null when neither is
  /// published (the avatar fallback then renders).
  VideoTrack? _resolveVideoTrack() {
    if (room == null) return null;
    final participant = snapshot.isLocal
        ? room!.localParticipant as Participant?
        : room!.remoteParticipants[snapshot.identity];
    if (participant == null) return null;

    // Screen share first.
    final screen =
        participant.getTrackPublicationBySource(TrackSource.screenShareVideo);
    if (screen?.track is VideoTrack && (screen!.subscribed || snapshot.isLocal)) {
      return screen.track as VideoTrack;
    }
    // Then camera (only if the snapshot says the camera is on).
    if (!snapshot.isCameraEnabled) return null;
    final cam = participant.getTrackPublicationBySource(TrackSource.camera);
    return cam?.track is VideoTrack ? cam!.track as VideoTrack : null;
  }
}

/// Avatar tile shown when camera is off or unavailable.
class _AvatarTile extends StatelessWidget {
  const _AvatarTile({
    required this.identity,
    required this.soulColor,
    required this.isLocal,
  });

  final String identity;
  final Color soulColor;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final initials = identity.isNotEmpty ? identity[0].toUpperCase() : '?';

    return Container(
      color: SovereignColors.surfaceCard,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: soulColor.withValues(alpha: 0.15),
                border: Border.all(
                  color: soulColor.withValues(alpha: 0.7),
                  width: 2.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: soulColor.withValues(alpha: 0.25),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  initials,
                  style: TextStyle(
                    color: soulColor,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Control bar ────────────────────────────────────────────────────────────

class _LiveKitControlBar extends ConsumerWidget {
  const _LiveKitControlBar({required this.callState});

  final LiveKitCallState callState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final safePad = MediaQuery.of(context).padding.bottom;
    final notifier = ref.read(liveKitCallProvider.notifier);

    return Container(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 20 + safePad),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.8),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mic toggle.
          _LKControlButton(
            icon: callState.isMicEnabled
                ? Icons.mic_rounded
                : Icons.mic_off_rounded,
            label: callState.isMicEnabled ? 'Mute' : 'Unmute',
            active: !callState.isMicEnabled,
            activeColor: SovereignColors.accentWarning,
            onTap: notifier.toggleMic,
          ),

          // Camera toggle.
          _LKControlButton(
            icon: callState.isCameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            label: callState.isCameraEnabled ? 'Cam off' : 'Cam on',
            active: !callState.isCameraEnabled,
            activeColor: SovereignColors.accentWarning,
            onTap: notifier.toggleCamera,
          ),

          // Screen-share toggle — publishes a getDisplayMedia track (web).
          _LKControlButton(
            icon: callState.isScreenSharing
                ? Icons.stop_screen_share_rounded
                : Icons.screen_share_rounded,
            label: callState.isScreenSharing ? 'Stop share' : 'Share',
            active: callState.isScreenSharing,
            activeColor: SovereignColors.soulLumina,
            onTap: notifier.toggleScreenShare,
          ),

          // Record toggle — drives POST /livekit/record/start|stop.
          _LKControlButton(
            icon: callState.isRecording
                ? Icons.stop_circle_rounded
                : Icons.fiber_manual_record_rounded,
            label: callState.isRecording ? 'Stop rec' : 'Record',
            active: callState.isRecording,
            activeColor: SovereignColors.accentDanger,
            onTap: notifier.toggleRecording,
          ),

          // Leave / end call.
          _LeaveButton(
            label: 'Leave',
            onTap: () => notifier.leave(context),
          ),
        ],
      ),
    );
  }
}

/// Flat-with-depth control button (no glass, per 2027 spec).
class _LKControlButton extends StatelessWidget {
  const _LKControlButton({
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
    final bgColor = active
        ? accent.withValues(alpha: 0.18)
        : const Color(0xFF1A1D22);
    final borderColor = active
        ? accent.withValues(alpha: 0.55)
        : const Color(0xFF2A2D34);

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bgColor,
              border: Border.all(color: borderColor, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
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
              fontFamily: 'Inter',
            ),
          ),
        ],
      ),
    );
  }
}

/// Red end/leave call button.
class _LeaveButton extends StatelessWidget {
  const _LeaveButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: SovereignColors.accentDanger,
              boxShadow: [
                BoxShadow(
                  color: SovereignColors.accentDanger.withValues(alpha: 0.45),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.call_end_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: SovereignColors.accentDanger,
              fontSize: 11,
              fontFamily: 'Inter',
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
