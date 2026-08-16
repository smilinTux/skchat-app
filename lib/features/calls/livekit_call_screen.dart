import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import '../../core/theme/theme.dart';
import '../../services/livekit_call_service.dart';
import 'call_session.dart';
import '../../services/recordings_service.dart';
import '../call_shared/call_elapsed_timer.dart';
import '../call_shared/in_call_panels.dart';
import '../call_shared/screen_share_source.dart';
import '../call_shared/soul_color.dart';
import '../call_shared/video/participant_grid.dart';
import 'call_device_picker.dart';
import 'cast_sheet.dart';

/// The participant grid, tile and video layer moved to
/// `call_shared/video/`, and `callVideoRendererBuilderProvider` moved with
/// them (it is the DI seam that lets any of them be mounted headless). This
/// re-export keeps that provider reachable from the screen that used to
/// declare it, so no existing call site or test had to be edited to prove a
/// pure move is pure.
export '../call_shared/video/participant_video.dart'
    show CallVideoRendererBuilder, callVideoRendererBuilderProvider;

// ── Guest invite (shareable link, multi-party) ─────────────────────────────

/// Mint a shareable guest-invite link for [room] and present it in a dialog
/// with a Copy button. ONE link admits MULTIPLE guests, so this is the in-app
/// "add people" path: each person who opens the link joins the SAME LiveKit
/// room as the host. Shows a spinner while minting, then the link (or a
/// friendly error when guest links are disabled / not operator-authorized).
Future<void> _shareGuestInvite(
  BuildContext context,
  WidgetRef ref,
  String room,
) async {
  if (room.isEmpty) return;
  final svc = ref.read(liveKitCallServiceProvider);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: CircularProgressIndicator(color: SovereignColors.soulLumina),
    ),
  );

  String? link;
  String? error;
  try {
    final url = await svc.mintGuestInvite(room: room);
    if (url.isEmpty) {
      error = 'The server did not return an invite link.';
    } else {
      link = url;
    }
  } catch (_) {
    error = 'Could not create an invite link. Guest links may be disabled '
        'on this server, or you are not authorized to invite.';
  }

  if (!context.mounted) return;
  Navigator.of(context).pop(); // dismiss the spinner

  showDialog<void>(
    context: context,
    builder: (dctx) => AlertDialog(
      backgroundColor: SovereignColors.surfaceRaised,
      title: const Text('Add people'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Text(
              error,
              style: Theme.of(dctx).textTheme.bodyMedium?.copyWith(
                    color: SovereignColors.textSecondary,
                  ),
            )
          else ...[
            Text(
              'Anyone with this link can join THIS call as a guest. Share it '
              'with as many people as you like: each one joins the same room.',
              style: Theme.of(dctx).textTheme.bodyMedium?.copyWith(
                    color: SovereignColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              link ?? '',
              style: SovereignTypography.mono(
                color: SovereignColors.soulLumina,
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (link != null)
          TextButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy link'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link!));
              if (dctx.mounted) Navigator.of(dctx).pop();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invite link copied')),
                );
              }
            },
          ),
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
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
    this.token = "",
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

  /// The LiveKit room token, kept so "Cast to TV" can authorize the HLS egress
  /// from a phone over the public Funnel (room-token auth path).
  final String token;
  final String? error;

  LiveKitCallState copyWith({
    List<LiveKitParticipantSnapshot>? participants,
    bool? isMicEnabled,
    bool? isCameraEnabled,
    bool? isConnected,
    bool? isRecording,
    bool? isScreenSharing,
    String? token,
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
      token: token ?? this.token,
      error: error,
    );
  }
}

// ── Notifier ──────────────────────────────────────────────────────────────

class LiveKitCallNotifier extends AutoDisposeNotifier<LiveKitCallState?> {
  StreamSubscription<List<LiveKitParticipantSnapshot>>? _participantSub;
  StreamSubscription<ConnectionState>? _connSub;

  /// True once the user has deliberately BACKGROUNDED this call, which is the
  /// ONE exit that keeps the room alive on purpose. See [background].
  bool _backgrounded = false;

  @override
  LiveKitCallState? build() => null;

  /// Hand this call off to CallSession instead of ending it: the PiP pill and
  /// the in-thread CallBanner keep a backgrounded call reachable, so the
  /// teardown armed by [_armTeardown] must stand down. Only the collapse
  /// chevron calls this, and only when a CallSession actually exists to come
  /// back through.
  void background() => _backgrounded = true;

  /// Make leaving the call surface, by ANY route, end the call.
  ///
  /// Hang-up is only one way out: the route also pops on the system back
  /// button, a browser back, a swipe-back, a `pushReplacement` from a
  /// deep-link join, and a host screen simply rebuilding without this widget.
  /// None of those touched a teardown, so the LiveKit room stayed connected
  /// and subscribed with nothing in the UI pointing at it: the far end kept
  /// playing through the speakers on whatever screen the user moved to, and it
  /// kept burning bandwidth. Several entry points (a group call, the agent
  /// room, a guest room, a join link) never create a CallSession at all, so
  /// there was not even a pill or banner left to end it with.
  ///
  /// This notifier's own disposal is the seam: it is autoDispose and the call
  /// screen is its only listener, so it dies with the screen for every one of
  /// those exits, including the ones no button handler can observe. [svc] and
  /// [session] are captured here, at join time, so teardown runs against the
  /// objects that actually own the live room. Teardown is idempotent and
  /// non-throwing (see [LiveKitCallService.leaveRoom]), so running after the
  /// hang-up button already tore the same room down is a clean no-op.
  void _armTeardown(LiveKitCallService svc) {
    // A new join is a new call: never inherit a previous one's hand-off. The
    // notifier can outlive one screen if the next mounts in the same frame
    // (collapse, then return through the banner), and a stale true here would
    // silently disarm the teardown for the whole next call.
    _backgrounded = false;
    final session = ref.read(callSessionProvider.notifier);
    ref.onDispose(() {
      if (_backgrounded) return;
      // hangUp clears the CallSession so no pill or banner points at a dead
      // call, and tears the room down; leaveRoom covers the sessionless entry
      // points, where hangUp has nothing to act on.
      unawaited(() async {
        try {
          await session.hangUp();
        } catch (_) {
          // Best-effort: one failing leg must not skip the other.
        }
        try {
          await svc.leaveRoom();
        } catch (_) {}
      }());
    });
  }

  /// Join the room, mints a token, connects, publishes mic (+ optional cam).
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
    _armTeardown(svc);

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
          token: svc.lastToken ?? "",
        );
      }
    } catch (e) {
      state = state?.copyWith(error: e.toString());
    }
  }

  /// Join using a **pre-minted, role-scoped** token (guest/sovereign conf
  /// join), connects via [LiveKitCallService.connectWithToken] rather than
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
      token: token,
    );

    ref.onDispose(_cancelSubs);
    final svc = ref.read(liveKitCallServiceProvider);
    _armTeardown(svc);

    _participantSub = svc.participants.listen((list) {
      if (state != null) state = state!.copyWith(participants: list);
    });
    _connSub = svc.connectionState.listen((cs) {
      if (state != null) {
        state = state!.copyWith(isConnected: cs == ConnectionState.connected);
      }
    });

    try {
      // ADOPT instead of re-join: when this exact token is already connected
      // (e.g. CallBanner._returnToCall expanding a CallSession the user
      // started/accepted, which already published mic/camera on connect, see
      // CallSession._connectAndPublish), a fresh connectWithToken would
      // dispose + reconnect the ALREADY-live room, dropping every remote
      // participant's view of us for a beat. Skip straight to rendering the
      // live room instead. A mismatched/absent token (guest link, group call,
      // deep-link join, or a first-time entry that never went through
      // CallSession) always falls through to the normal connect + publish
      // path below, so those flows are unaffected.
      final alreadyLive = svc.room != null && svc.lastToken == token;
      if (!alreadyLive) {
        await svc.connectWithToken(wsUrl: wsUrl, token: token);
        await svc.setMicEnabled(true);
        if (withVideo) await svc.setCameraEnabled(true);
      }
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
  ///
  /// [sourceId] is the native-desktop capture source the caller already
  /// resolved (via `resolveScreenShareSource`) before calling this; null on
  /// web/mobile, where the platform supplies its own picker.
  Future<void> toggleScreenShare({String? sourceId}) async {
    if (state == null) return;
    final svc = ref.read(liveKitCallServiceProvider);
    final next = !state!.isScreenSharing;
    state = state!.copyWith(isScreenSharing: next);
    try {
      await svc.setScreenShareEnabled(next, sourceId: sourceId);
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

  /// Pull an AI agent (default Lumina) into the CURRENT room so she joins the
  /// live call. Spawns her media stack server-side via
  /// [LiveKitCallService.inviteAgent]. Rethrows a human-readable [Exception] on
  /// a backend rejection so the UI can show it in a snackbar.
  Future<void> inviteAgent({String agent = 'lumina'}) async {
    final s = state;
    if (s == null || s.roomName.isEmpty) return;
    final svc = ref.read(liveKitCallServiceProvider);
    await svc.inviteAgent(
      room: s.roomName,
      agent: agent,
      requester: s.identity,
    );
  }

  Future<void> leave(BuildContext context) async {
    _cancelSubs();
    await stopActiveCast(ref);
    // CallSession is the authority for call lifecycle (drives the PiP pill
    // and the in-thread CallBanner); hangUp() tears the room down (best-
    // effort, safe even if this notifier's own svc.leaveRoom() below already
    // did) AND clears the session to null so nothing keeps pointing at a
    // dead call.
    await ref.read(callSessionProvider.notifier).hangUp();
    final svc = ref.read(liveKitCallServiceProvider);
    await svc.leaveRoom();
    state = null;
    if (context.mounted && context.canPop()) context.pop();
  }

  // Called by ref.onDispose path via AutoDispose, no @override needed.
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
/// Usage, navigate via GoRouter with extra args:
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
/// Height of the bottom control bar, excluding the device safe-area inset.
///
/// 20 top padding + a 56 control + 6 gap + ~14 label + 20 bottom padding. The
/// panels FAB is lifted by this so it stops covering Leave; keep the two in
/// step if the bar's padding or control size changes.
const double _kCallControlBarHeight = 116;

/// Pop the call screen through whichever navigator actually pushed it.
///
/// Most entries are GoRouter pushes, but the guest room and the guest ring
/// push a plain MaterialPageRoute, and `GoRouter.of` asserts when there is no
/// router above. Falling back to `Navigator.maybePop` keeps the collapse
/// chevron working on those screens instead of throwing.
void _popCallScreen(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  if (router != null && router.canPop()) {
    router.pop();
    return;
  }
  Navigator.of(context).maybePop();
}

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

  /// Collapse: hand the live call to CallSession and pop, the one exit that
  /// deliberately KEEPS the room. Only legitimate when there is a session to
  /// hand it to, since the PiP pill and the CallBanner both render off
  /// [callSessionProvider]. Without one (a group call, an agent room, a guest
  /// room, a join link) there is nothing to restore the call from, so this
  /// falls through to the normal teardown (see
  /// [LiveKitCallNotifier.background]) instead of orphaning a room nobody can
  /// reach.
  void _collapse() {
    if (ref.read(callSessionProvider) != null) {
      ref.read(callSessionProvider.notifier).minimize();
      ref.read(liveKitCallProvider.notifier).background();
    }
    _popCallScreen(context);
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
      // Collab lanes (chat / whiteboard / watch / terminal / screenshare) over
      // this room's LiveKit data channel, keyed by the room name. Same substrate
      // a Space room uses; mounted once media is connected.
      // Lifted clear of the control bar. A Scaffold FAB parks bottom-right by
      // default, which put this panels button directly ON TOP of Leave: the
      // one control you need to be able to hit without thinking, covered by
      // the one that opens a menu. Reported from real calls on a phone.
      floatingActionButton:
          (callState?.isConnected ?? false) && callState!.roomName.isNotEmpty
              ? Padding(
                  padding: EdgeInsets.only(
                    bottom: _kCallControlBarHeight +
                        MediaQuery.of(context).padding.bottom,
                  ),
                  child: InCallPanelsFab(
                    roomId: callState.roomName,
                    identity: callState.identity,
                  ),
                )
              : null,
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
              color: soulColorFor(widget.args.identity),
              strokeWidth: 2.5,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Joining room…',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: SovereignColors.textSecondary,
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w400,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.args.roomName,
            style: SovereignTypography.mono(
              color: soulColorFor(widget.args.identity).withValues(alpha: 0.7),
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
            Text(
              'Room join failed',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: SovereignColors.textPrimary,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style:
                  SovereignTypography.mono(color: SovereignColors.textSecondary),
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
          // localIdentity is gone: the private grid took it and never read it
          // (a tile learns it is yours from `snapshot.isLocal`), and a shared
          // widget should not carry a required argument that means nothing.
          child: ParticipantGrid(
            participants: callState.participants,
            room: ref.read(liveKitCallServiceProvider).room,
          ),
        ),

        // Top bar, room name + connection badge.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _TopBar(
            callState: callState,
            displayName: widget.args.displayName,
            onCollapse: _collapse,
          ),
        ),

        // Bottom control bar, mic / cam / leave.
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

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.callState,
    required this.onCollapse,
    this.displayName,
  });

  final LiveKitCallState callState;
  final String? displayName;

  /// Collapse (background) the call. Owned by the screen state, which is what
  /// decides whether backgrounding is even possible here and tells the
  /// notifier to stand its teardown down, see
  /// `_LiveKitCallScreenState._collapse`.
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          // Back / collapse: MINIMIZE (via CallSession), not hang up. Leaving
          // this screen this way keeps the room live (PiP pill + in-thread
          // CallBanner pick it back up) instead of orphaning it: previously
          // this was a bare context.pop() that never told CallSession the
          // room was still connected, so the call stayed live server-side
          // with no UI referencing it (the orphaned-call bug). It now runs
          // through the screen's own handler, which also tells the notifier
          // this exit was deliberate so its teardown stands down, and which
          // refuses to background a call that has no CallSession to come back
          // through.
          GestureDetector(
            key: const Key('call-collapse'),
            onTap: onCollapse,
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: SovereignColors.textPrimary,
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: SovereignColors.textSecondary,
                            fontFamily: 'Inter',
                          ),
                    ),
                    if (callState.isConnected) ...[
                      Text(
                        '  ·  ',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: SovereignColors.textTertiary,
                            ),
                      ),
                      CallElapsedTimer(isConnected: callState.isConnected),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // REC badge, shown while a server-side recording is active.
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
                children: [
                  const Icon(
                    Icons.fiber_manual_record_rounded,
                    color: SovereignColors.accentDanger,
                    size: 10,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'REC',
                    style: SovereignTypography.badge().copyWith(
                          color: SovereignColors.accentDanger,
                          fontFamily: 'JetBrainsMono',
                          letterSpacing: 0.6,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ],

          // Add people: mint + share a guest invite link for THIS room. One
          // link admits multiple guests into the same LiveKit room.
          GestureDetector(
            onTap: () => _shareGuestInvite(context, ref, callState.roomName),
            child: Container(
              padding: const EdgeInsets.all(6),
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: SovereignColors.surfaceGlass,
                border: Border.all(color: SovereignColors.surfaceGlassBorder),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.person_add_alt_1_rounded,
                color: SovereignColors.textPrimary,
                size: 20,
              ),
            ),
          ),

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
              style: SovereignTypography.badge().copyWith(
                    color: SovereignColors.textTertiary,
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
      // Leave is PINNED outside the scroller, and the other controls scroll.
      // Eight 56px controls plus labels need ~450px, so on a phone (~340px of
      // usable width here) the row overflowed and pushed the rightmost items
      // off: the device picker's label truncated and Leave ended up jammed
      // against the edge. Hanging up is the one action that must never be the
      // thing that scrolls away.
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
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

          // Screen-share toggle, publishes a getDisplayMedia track (web) or
          // a desktopCapturer-sourced track (native desktop, after the user
          // picks a source below).
          _LKControlButton(
            icon: callState.isScreenSharing
                ? Icons.stop_screen_share_rounded
                : Icons.screen_share_rounded,
            label: callState.isScreenSharing ? 'Stop share' : 'Share',
            active: callState.isScreenSharing,
            activeColor: SovereignColors.soulLumina,
            onTap: () => _toggleScreenShare(context, ref, notifier, callState),
          ),

          // Record toggle, drives POST /livekit/record/start|stop.
          _LKControlButton(
            icon: callState.isRecording
                ? Icons.stop_circle_rounded
                : Icons.fiber_manual_record_rounded,
            label: callState.isRecording ? 'Stop rec' : 'Record',
            active: callState.isRecording,
            activeColor: SovereignColors.accentDanger,
            onTap: notifier.toggleRecording,
          ),

          // Cast the shared video to a TV (Chromecast / AirPlay) via HLS. Keeps
          // the LiveKit mic + chat live; only the separate HLS stream goes to
          // the TV. Watches the active-cast session so the button reads "live".
          _LKControlButton(
            icon: Icons.cast_rounded,
            label: ref.watch(activeCastSessionProvider) != null
                ? 'Casting'
                : 'Cast to TV',
            active: ref.watch(activeCastSessionProvider) != null,
            activeColor: SovereignColors.soulLumina,
            onTap: () => showCastToTvSheet(
              context,
              ref,
              room: callState.roomName,
              token: callState.token,
            ),
          ),

          // Invite Lumina (AI agent) into this room so she joins the call.
          _LKControlButton(
            icon: Icons.smart_toy_rounded,
            label: 'Lumina',
            active: false,
            activeColor: SovereignColors.soulLumina,
            onTap: () => _inviteLumina(context, ref),
          ),

          // Camera / mic device picker (self-contained control widget).
          const CallDevicePickerButton(size: 56),
                ],
              ),
            ),
          ),

          const SizedBox(width: 12),

          // Leave / end call. Outside the scroller so it is always on screen.
          _LeaveButton(
            label: 'Leave',
            onTap: () => notifier.leave(context),
          ),
        ],
      ),
    );
  }

  /// Start / stop the screen share, resolving a native-desktop capture
  /// source first when starting. Native desktop needs an explicit
  /// `sourceId` before `getDisplayMedia` can resolve one;
  /// `resolveScreenShareSource` no-ops (returns `sourceId: null`) on
  /// web/mobile, where the platform supplies its own picker. A cancelled
  /// desktop pick aborts silently: no share, no error, [notifier] is never
  /// called. A genuine resolver failure (desktopCapturer.getSources
  /// throwing on the platform channel) surfaces as the same
  /// "Screen share failed" toast the Spaces flow shows, never as an
  /// unhandled async error, and the share is never started.
  /// [LiveKitCallNotifier.toggleScreenShare] separately surfaces
  /// capture/publish failures via [LiveKitCallState.error].
  Future<void> _toggleScreenShare(
    BuildContext context,
    WidgetRef ref,
    LiveKitCallNotifier notifier,
    LiveKitCallState callState,
  ) async {
    String? sourceId;
    if (!callState.isScreenSharing) {
      // Z1: mobile browsers (iOS Safari, Android Chrome) have no
      // getDisplayMedia, so a share can never actually start here.
      // Short-circuit BEFORE the resolver / notifier so the raw
      // livekit_client lkPlatformIsWebMobile() exception never surfaces;
      // show a friendly message instead. Mirrors the Spaces control bar's
      // Go live guard (space_room_screen.dart) and conf_screen.dart's Share
      // guard.
      if (ref.read(isMobileWebProvider)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Screen sharing needs the desktop app. Native mobile '
                'screen share is coming soon. You can still watch shares '
                'here.',
              ),
            ),
          );
        }
        return;
      }
      try {
        final resolve = ref.read(screenShareSourceResolverProvider);
        final picked = await resolve(context);
        if (!picked.proceed) return;
        sourceId = picked.sourceId;
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Screen share failed: $e')),
          );
        }
        return;
      }
    }
    await notifier.toggleScreenShare(sourceId: sourceId);
  }

  /// Invite Lumina into the current room. Spawns her server-side so she joins
  /// the live call, then confirms with a snackbar (or surfaces the backend
  /// error). The room may be a conference or a plain 1:1 / group call room.
  Future<void> _inviteLumina(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(liveKitCallProvider.notifier).inviteAgent();
      messenger.showSnackBar(
        const SnackBar(content: Text('Lumina is joining...')),
      );
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      messenger.showSnackBar(
        SnackBar(content: Text('Could not invite Lumina: $msg')),
      );
    }
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
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: SovereignColors.textSecondary,
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
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: SovereignColors.accentDanger,
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
