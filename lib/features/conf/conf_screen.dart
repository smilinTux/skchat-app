import "dart:async";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";
import "package:livekit_client/livekit_client.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/conf_service.dart";
import "../../services/livekit_call_service.dart";
import "../call_shared/call_elapsed_timer.dart";
import "../call_shared/connection_quality_bars.dart";
import "../call_shared/in_call_panels.dart";
import "../call_shared/reactions.dart";
import "../calls/call_device_picker.dart";
import "../calls/cast_sheet.dart";
import "../profile/profile_screen.dart" show localIdentityProvider;

// ── Route args ────────────────────────────────────────────────────────────────

/// Arguments for the conference screen.
///
/// Either [room] is already known (join an existing conf) or [createTitle]
/// is set (create a fresh conf first). [identity] is the caller's fqid/name.
class ConfArgs {
  const ConfArgs({
    required this.identity,
    this.room,
    this.name,
    this.role = "guest",
    this.createTitle,
    this.hostFqid,
    this.preMintedToken,
    this.wsUrl,
  });

  /// Caller identity (fqid / fingerprint).
  final String identity;

  /// Existing conference room id (null when creating a new one).
  final String? room;

  /// Display name in the room (defaults to [identity]).
  final String? name;

  /// Requested role, "host" or "guest".
  final String role;

  /// When set, create a new conference with this title before joining.
  final String? createTitle;

  /// Host fqid to register on create (defaults to [identity]).
  final String? hostFqid;

  /// Pre-minted, role-scoped LiveKit JWT (from a guest/sovereign conf join
  /// deep link). When present the server already authorized this join, so the
  /// notifier skips create + lobby + token mint and connects straight to media.
  final String? preMintedToken;

  /// LiveKit WebSocket URL paired with [preMintedToken].
  final String? wsUrl;

  bool get wantsHost => role == "host";

  /// True when a pre-minted token + ws url are present (deep-link join path).
  bool get hasPreMintedToken =>
      (preMintedToken ?? "").isNotEmpty && (wsUrl ?? "").isNotEmpty;

  /// Build [ConfArgs] from a deep-link's query parameters (GoRouter supplies
  /// these via `state.uri.queryParameters`). Backs the native hand-off routes:
  ///   /conf?room=R&token=T&url=U&identity=I&display=N   (guest / sovereign)
  ///   /conf?room=R                                       (bare conf landing)
  /// Returns null when no room is present (nothing to join).
  static ConfArgs? fromParams(Map<String, String> q) {
    final room = (q["room"] ?? q["space"] ?? q["space_id"] ?? "").trim();
    if (room.isEmpty) return null;
    final token = (q["token"] ?? q["lk_token"] ?? "").trim();
    final url = (q["url"] ?? q["lk_url"] ?? q["livekit_url"] ?? "").trim();
    final identity = (q["identity"] ?? "").trim();
    final name = (q["name"] ?? q["display"] ?? q["display_name"] ?? "").trim();
    final role = (q["role"] ?? "").trim();
    return ConfArgs(
      identity: identity,
      room: room,
      name: name.isEmpty ? null : name,
      role: role.isEmpty ? "guest" : role,
      preMintedToken: token.isEmpty ? null : token,
      wsUrl: url.isEmpty ? null : url,
    );
  }
}

// ── State ─────────────────────────────────────────────────────────────────────

class ConfState {
  const ConfState({
    required this.room,
    required this.participants,
    required this.waiting,
    required this.isConnected,
    required this.isMicEnabled,
    required this.isCameraEnabled,
    required this.isScreenSharing,
    required this.isHost,
    this.isPending = false,
    this.pendingMessage = "",
    this.title = "",
    this.error,
  });

  final String room;
  final List<LiveKitParticipantSnapshot> participants;
  final List<WaitingGuest> waiting;
  final bool isConnected;
  final bool isMicEnabled;
  final bool isCameraEnabled;
  final bool isScreenSharing;
  final bool isHost;

  /// True while a guest is sitting in the lobby awaiting host admission.
  final bool isPending;

  /// Human-readable lobby status shown to a pending guest.
  final String pendingMessage;
  final String title;
  final String? error;

  static const empty = ConfState(
    room: "",
    participants: [],
    waiting: [],
    isConnected: false,
    isMicEnabled: false,
    isCameraEnabled: false,
    isScreenSharing: false,
    isHost: false,
  );

  ConfState copyWith({
    String? room,
    List<LiveKitParticipantSnapshot>? participants,
    List<WaitingGuest>? waiting,
    bool? isConnected,
    bool? isMicEnabled,
    bool? isCameraEnabled,
    bool? isScreenSharing,
    bool? isHost,
    bool? isPending,
    String? pendingMessage,
    String? title,
    Object? error = _sentinel,
  }) {
    return ConfState(
      room: room ?? this.room,
      participants: participants ?? this.participants,
      waiting: waiting ?? this.waiting,
      isConnected: isConnected ?? this.isConnected,
      isMicEnabled: isMicEnabled ?? this.isMicEnabled,
      isCameraEnabled: isCameraEnabled ?? this.isCameraEnabled,
      isScreenSharing: isScreenSharing ?? this.isScreenSharing,
      isHost: isHost ?? this.isHost,
      isPending: isPending ?? this.isPending,
      pendingMessage: pendingMessage ?? this.pendingMessage,
      title: title ?? this.title,
      error: identical(error, _sentinel) ? this.error : error as String?,
    );
  }

  static const _sentinel = Object();
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class ConfNotifier extends AutoDisposeFamilyNotifier<ConfState, ConfArgs> {
  StreamSubscription<List<LiveKitParticipantSnapshot>>? _partSub;
  StreamSubscription<ConnectionState>? _connSub;
  Timer? _waitingPoll;
  Timer? _admissionPoll;

  String? _identityCache;

  @override
  ConfState build(ConfArgs arg) {
    ref.onDispose(_cancel);
    return ConfState.empty.copyWith(room: arg.room ?? "", isHost: arg.wantsHost);
  }

  /// Effective caller identity. Uses [ConfArgs.identity] when supplied; a bare
  /// deep-link (/conf?room=...) carries none, so fall back to the signed-in
  /// local identity (fingerprint, else display name).
  String get _identity {
    final cached = _identityCache;
    if (cached != null) return cached;
    final fromArg = arg.identity.trim();
    final resolved = fromArg.isNotEmpty
        ? fromArg
        : () {
            final me = ref.read(localIdentityProvider);
            return me.fingerprint.isNotEmpty ? me.fingerprint : me.displayName;
          }();
    _identityCache = resolved;
    return resolved;
  }

  /// Create (if needed), mint a token, and join the LiveKit media room.
  ///
  /// A guest first knocks on the lobby (POST /conf/{room}/waiting). Tailnet
  /// callers are auto-admitted and flow straight through; an off-net guest sits
  /// in [ConfState.isPending] until the host admits them (polled here) or
  /// denies them (surfaced as an error). The host never waits.
  Future<void> connect() async {
    final conf = ref.read(confServiceProvider);

    try {
      // Deep-link fast path: a pre-minted token means the server already
      // authorized this join (guest admitted / sovereign proven), so skip
      // create + lobby + mint and connect straight to media.
      if (arg.hasPreMintedToken) {
        await _joinWithToken(
          room: arg.room ?? "",
          wsUrl: arg.wsUrl!,
          token: arg.preMintedToken!,
          isHost: arg.wantsHost,
          title: state.title,
        );
        return;
      }

      var room = arg.room;
      // 1. Create the conference if no room id was supplied (host path).
      if (room == null || room.isEmpty) {
        final created = await conf.create(
          hostFqid: arg.hostFqid ?? _identity,
          title: arg.createTitle,
        );
        room = created.room;
        state = state.copyWith(room: room, title: created.title);
      }

      // 2. Guests knock on the lobby first.
      if (!arg.wantsHost) {
        final status = await conf.enterWaiting(
          room,
          identity: _identity,
          display: arg.name,
        );
        if (status.denied) {
          state = state.copyWith(
            isPending: false,
            error: status.message.isNotEmpty
                ? status.message
                : WaitingStatus.denyMessage,
          );
          return;
        }
        if (!status.admitted) {
          // Sit in the lobby and poll for admission.
          state = state.copyWith(
            isPending: true,
            pendingMessage: status.message.isNotEmpty
                ? status.message
                : "Your request is pending the host's approval",
          );
          _startAdmissionPoll(room);
          return;
        }
      }

      // 3. Admitted (or host): join media.
      await _joinMedia(room);
    } on Object catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Mint a role-scoped token and join the LiveKit media room for [room].
  Future<void> _joinMedia(String room) async {
    final conf = ref.read(confServiceProvider);
    final tok = await conf.token(
      room,
      identity: _identity,
      name: arg.name,
      role: arg.role,
    );
    await _joinWithToken(
      room: tok.room.isNotEmpty ? tok.room : room,
      wsUrl: tok.url,
      token: tok.token,
      isHost: tok.isHost,
      title: tok.title,
    );
  }

  /// Join the LiveKit media room with an already-minted [token] + [wsUrl].
  /// Shared by the minted path ([_joinMedia]) and the deep-link pre-minted path
  /// ([connect]); both connect via [LiveKitCallService.connectWithToken].
  Future<void> _joinWithToken({
    required String room,
    required String wsUrl,
    required String token,
    required bool isHost,
    String title = "",
  }) async {
    final lk = ref.read(liveKitCallServiceProvider);

    state = state.copyWith(
      room: room.isNotEmpty ? room : state.room,
      isHost: isHost,
      isPending: false,
      title: title.isNotEmpty ? title : state.title,
    );

    // Wire media streams.
    _partSub = lk.participants.listen((list) {
      state = state.copyWith(participants: list);
    });
    _connSub = lk.connectionState.listen((cs) {
      state = state.copyWith(isConnected: cs == ConnectionState.connected);
    });

    // Join the LiveKit room with the role-scoped token.
    await lk.connectWithToken(wsUrl: wsUrl, token: token);
    // Host goes live on mic immediately.
    if (isHost) {
      await lk.setMicEnabled(true);
    }
    state = state.copyWith(
      participants: lk.currentParticipants,
      isConnected: true,
      isMicEnabled: isHost,
    );

    // Host polls the waiting room for guests to admit.
    if (isHost) {
      _startWaitingPoll();
    }
  }

  void _startAdmissionPoll(String room) {
    _admissionPoll?.cancel();
    _admissionPoll = Timer.periodic(
        const Duration(seconds: 3), (_) => _pollAdmission(room));
  }

  Future<void> _pollAdmission(String room) async {
    if (!state.isPending) return;
    try {
      final status = await ref.read(confServiceProvider).enterWaiting(
            room,
            identity: _identity,
            display: arg.name,
          );
      if (status.denied) {
        _admissionPoll?.cancel();
        state = state.copyWith(
          isPending: false,
          error: status.message.isNotEmpty
              ? status.message
              : WaitingStatus.denyMessage,
        );
        return;
      }
      if (status.admitted) {
        _admissionPoll?.cancel();
        await _joinMedia(room);
      }
    } on Object {
      // Best-effort, keep waiting and retry on the next tick.
    }
  }

  void _startWaitingPoll() {
    _refreshWaiting();
    _waitingPoll =
        Timer.periodic(const Duration(seconds: 4), (_) => _refreshWaiting());
  }

  Future<void> _refreshWaiting() async {
    if (!state.isHost || state.room.isEmpty) return;
    try {
      final list = await ref.read(confServiceProvider).waitingList(state.room);
      state = state.copyWith(waiting: list);
    } on Object {
      // Best-effort, keep last known waiting list.
    }
  }

  Future<void> toggleMic() async {
    final lk = ref.read(liveKitCallServiceProvider);
    final next = !state.isMicEnabled;
    await lk.setMicEnabled(next);
    state = state.copyWith(isMicEnabled: next);
  }

  Future<void> toggleCamera() async {
    final lk = ref.read(liveKitCallServiceProvider);
    final next = !state.isCameraEnabled;
    await lk.setCameraEnabled(next);
    state = state.copyWith(isCameraEnabled: next);
  }

  Future<void> toggleScreenShare() async {
    final lk = ref.read(liveKitCallServiceProvider);
    final next = !state.isScreenSharing;
    await lk.setScreenShareEnabled(next);
    state = state.copyWith(isScreenSharing: next);
  }

  // ── Host controls ───────────────────────────────────────────────────────────

  Future<void> admit(String identity) async {
    await ref
        .read(confServiceProvider)
        .admit(state.room, identity: identity, requester: _identity);
    await _refreshWaiting();
  }

  Future<void> deny(String identity) async {
    await ref
        .read(confServiceProvider)
        .deny(state.room, identity: identity, requester: _identity);
    await _refreshWaiting();
  }

  Future<void> inviteAgent(String agent) => ref
      .read(confServiceProvider)
      .inviteAgent(state.room, agent: agent, requester: _identity);

  Future<void> removeAgent(String agent) => ref
      .read(confServiceProvider)
      .removeAgent(state.room, agent: agent, requester: _identity);

  Future<void> end() => ref
      .read(confServiceProvider)
      .end(state.room, requester: _identity);

  Future<void> leave() async {
    _cancel();
    await stopActiveCast(ref);
    await ref.read(liveKitCallServiceProvider).leaveRoom();
  }

  void _cancel() {
    _partSub?.cancel();
    _connSub?.cancel();
    _waitingPoll?.cancel();
    _admissionPoll?.cancel();
  }
}

final confProvider =
    AutoDisposeNotifierProviderFamily<ConfNotifier, ConfState, ConfArgs>(
        ConfNotifier.new);

// ── Screen ────────────────────────────────────────────────────────────────────

/// Conference screen, video/audio conf over the sovereign /conf REST surface.
///
/// Creates or joins a conference, joins media via [LiveKitCallService] using a
/// role-scoped token from POST /conf/{room}/token, shows participants, and
/// gives the host admit/deny/end + invite/remove-agent controls and
/// screenshare.
class ConfScreen extends ConsumerStatefulWidget {
  const ConfScreen({super.key, required this.args});

  final ConfArgs args;

  @override
  ConsumerState<ConfScreen> createState() => _ConfScreenState();
}

class _ConfScreenState extends ConsumerState<ConfScreen> {
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  Future<void> _connect() async {
    if (_connected) return;
    _connected = true;
    await ref.read(confProvider(widget.args).notifier).connect();
  }

  Future<void> _leave() async {
    await ref.read(confProvider(widget.args).notifier).leave();
    if (mounted && context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(confProvider(widget.args));

    return Scaffold(
      backgroundColor: SovereignColors.surfaceCard,
      // Collab lanes (chat / whiteboard / watch / terminal / screenshare) over
      // the current room's LiveKit data channel, keyed by the conf room id.
      floatingActionButton: st.isConnected && st.room.isNotEmpty
          ? InCallPanelsFab(roomId: st.room, identity: widget.args.identity)
          : null,
      body: st.error != null
          ? _buildError(st.error!)
          : SafeArea(
              child: Column(
                children: [
                  _Header(state: st, onClose: _leave),
                  Expanded(
                    child: st.isConnected
                        ? Stack(
                            children: [
                              _Body(args: widget.args, state: st),
                              // Floating emoji reactions over the participants.
                              const Positioned.fill(child: ReactionsOverlay()),
                            ],
                          )
                        : st.isPending
                            ? _WaitingLobby(state: st, onCancel: _leave)
                            : _buildConnecting(),
                  ),
                  if (!st.isPending)
                    _ControlBar(args: widget.args, state: st, onLeave: _leave),
                ],
              ),
            ),
    );
  }

  Widget _buildConnecting() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              color: SovereignColors.soulLumina,
              strokeWidth: 2.5,
            ),
          ),
          SizedBox(height: 18),
          Text(
            "Joining conference...",
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
            const Icon(Icons.error_outline_rounded,
                color: SovereignColors.accentDanger, size: 44),
            const SizedBox(height: 16),
            const Text(
              "Couldn't join conference",
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

// ── Waiting lobby (guest) ─────────────────────────────────────────────────────

/// Shown to a guest who has knocked on the conference lobby and is waiting for
/// the host to admit them. The notifier polls admission in the background; this
/// is purely the "please hold" surface with a way to back out.
class _WaitingLobby extends StatelessWidget {
  const _WaitingLobby({required this.state, required this.onCancel});

  final ConfState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final message = state.pendingMessage.isNotEmpty
        ? state.pendingMessage
        : "Your request is pending the host's approval";
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                color: SovereignColors.soulLumina,
                strokeWidth: 2.5,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              "Waiting to be admitted",
              style: TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 28),
            OutlinedButton(
              onPressed: onCancel,
              child: const Text("Cancel"),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Header ────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.onClose});

  final ConfState state;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: SovereignColors.textPrimary, size: 28),
            tooltip: "Minimise",
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  state.title.isNotEmpty ? state.title : "Conference",
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
                          ? "${state.participants.length} in call"
                          : state.isPending
                              ? "waiting for host..."
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
          if (state.isHost)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: SovereignColors.soulLumina.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                "HOST",
                style: TextStyle(
                  color: SovereignColors.soulLumina,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  fontFamily: "JetBrainsMono",
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Body ──────────────────────────────────────────────────────────────────────

class _Body extends ConsumerWidget {
  const _Body({required this.args, required this.state});

  final ConfArgs args;
  final ConfState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // Host-only: waiting room.
        if (state.isHost && state.waiting.isNotEmpty) ...[
          _sectionLabel("Waiting room", state.waiting.length),
          const SizedBox(height: 12),
          for (final g in state.waiting)
            _WaitingTile(
              guest: g,
              onAdmit: () =>
                  ref.read(confProvider(args).notifier).admit(g.identity),
              onDeny: () =>
                  ref.read(confProvider(args).notifier).deny(g.identity),
            ),
          const SizedBox(height: 24),
        ],
        _sectionLabel("Participants", state.participants.length),
        const SizedBox(height: 12),
        Wrap(
          spacing: 20,
          runSpacing: 20,
          children: [
            for (final p in state.participants)
              _ParticipantTile(
                snapshot: p,
                isHost: state.isHost,
                onAgentRemove: state.isHost && !p.isLocal
                    ? () => ref
                        .read(confProvider(args).notifier)
                        .removeAgent(p.identity)
                    : null,
              ),
          ],
        ),
      ],
    );
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
}

class _WaitingTile extends StatelessWidget {
  const _WaitingTile({
    required this.guest,
    required this.onAdmit,
    required this.onDeny,
  });

  final WaitingGuest guest;
  final VoidCallback onAdmit;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final label = guest.name.isNotEmpty ? guest.name : guest.identity;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            tooltip: "Admit",
            onPressed: onAdmit,
            icon: const Icon(Icons.check_circle_rounded,
                color: SovereignColors.accentEncrypt),
          ),
          IconButton(
            tooltip: "Deny",
            onPressed: onDeny,
            icon: const Icon(Icons.cancel_rounded,
                color: SovereignColors.accentDanger),
          ),
        ],
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.snapshot,
    required this.isHost,
    this.onAgentRemove,
  });

  final LiveKitParticipantSnapshot snapshot;
  final bool isHost;
  final VoidCallback? onAgentRemove;

  @override
  Widget build(BuildContext context) {
    final soul = SovereignColors.fromFingerprint(snapshot.identity);
    final initials =
        snapshot.identity.isNotEmpty ? snapshot.identity[0].toUpperCase() : "?";
    return Semantics(
      label: "${snapshot.identity}"
          "${snapshot.isLocal ? " (you)" : ""}"
          "${snapshot.isMuted ? ", muted" : ""}",
      button: onAgentRemove != null,
      child: GestureDetector(
        onLongPress: onAgentRemove,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: soul.withValues(alpha: 0.15),
                border: Border.all(
                  color: snapshot.isSpeaking ? soul : soul.withValues(alpha: 0.5),
                  width: snapshot.isSpeaking ? 3 : 1.5,
                ),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: soul,
                        fontSize: 24,
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
                        child: const Icon(Icons.mic_off_rounded,
                            size: 12, color: SovereignColors.accentWarning),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 76,
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
            // Connection-quality signal bars (subtle; hidden until known).
            if (snapshot.connectionQuality != ConnectionQuality.unknown) ...[
              const SizedBox(height: 4),
              ConnectionQualityBars(quality: snapshot.connectionQuality),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Control bar ───────────────────────────────────────────────────────────────

class _ControlBar extends ConsumerWidget {
  const _ControlBar({
    required this.args,
    required this.state,
    required this.onLeave,
  });

  final ConfArgs args;
  final ConfState state;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(confProvider(args).notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(
            icon:
                state.isMicEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
            label: state.isMicEnabled ? "Mute" : "Unmute",
            active: !state.isMicEnabled,
            activeColor: SovereignColors.accentWarning,
            onTap: notifier.toggleMic,
          ),
          _RoundButton(
            icon: state.isCameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            label: "Camera",
            active: state.isCameraEnabled,
            activeColor: SovereignColors.accentEncrypt,
            onTap: notifier.toggleCamera,
          ),
          _RoundButton(
            icon: Icons.screen_share_rounded,
            label: "Share",
            active: state.isScreenSharing,
            activeColor: SovereignColors.soulLumina,
            onTap: notifier.toggleScreenShare,
          ),
          // Camera / mic device picker (self-contained control widget).
          const CallDevicePickerButton(),
          // Quick emoji reactions: floats to everyone in the conf.
          ReactionsButton(identity: args.identity),
          // Cast the shared video to a TV (Chromecast / AirPlay) over HLS. The
          // conf's WebRTC audio + chat stay live on the phone.
          _RoundButton(
            icon: Icons.cast_rounded,
            label: ref.watch(activeCastSessionProvider) != null
                ? "Casting"
                : "Cast",
            active: ref.watch(activeCastSessionProvider) != null,
            activeColor: SovereignColors.soulLumina,
            onTap: () => showCastToTvSheet(context, ref, room: state.room),
          ),
          if (state.isHost)
            _RoundButton(
              icon: Icons.smart_toy_rounded,
              label: "Agent",
              active: false,
              activeColor: SovereignColors.soulLumina,
              onTap: () => _inviteAgentSheet(context, notifier),
            ),
          if (state.isHost)
            _RoundButton(
              icon: Icons.stop_circle_outlined,
              label: "End",
              active: true,
              activeColor: SovereignColors.accentDanger,
              onTap: () async {
                await notifier.end();
                onLeave();
              },
            ),
          _LeaveButton(onTap: onLeave),
        ],
      ),
    );
  }

  Future<void> _inviteAgentSheet(
      BuildContext context, ConfNotifier notifier) async {
    final controller = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Invite an agent",
              style: TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: SovereignColors.textPrimary),
              decoration: const InputDecoration(
                hintText: "agent name (e.g. lumina)",
                hintStyle: TextStyle(color: SovereignColors.textTertiary),
              ),
              onSubmitted: (_) => Navigator.of(sheetCtx).pop(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(sheetCtx).pop(),
              child: const Text("Invite"),
            ),
          ],
        ),
      ),
    );
    final agent = controller.text.trim();
    controller.dispose();
    if (agent.isNotEmpty) {
      await notifier.inviteAgent(agent);
    }
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
    final bg = active ? accent.withValues(alpha: 0.18) : const Color(0xFF1A1D22);
    final border =
        active ? accent.withValues(alpha: 0.55) : const Color(0xFF2A2D34);

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: bg,
                border: Border.all(color: border, width: 1.5),
              ),
              child: Icon(
                icon,
                color: active ? accent : SovereignColors.textPrimary,
                size: 22,
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
      label: "Leave conference",
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: SovereignColors.accentDanger,
              ),
              child: const Icon(Icons.call_end_rounded,
                  color: Colors.white, size: 24),
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
