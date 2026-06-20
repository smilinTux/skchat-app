import "dart:async";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_webrtc/flutter_webrtc.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/facetime_service.dart";

// ── Controller / state ────────────────────────────────────────────────────────

/// Phase of a FaceTime call.
enum FaceTimePhase { idle, connecting, connected, ended, error }

/// Immutable view state for the FaceTime screen.
class FaceTimeState {
  const FaceTimeState({
    this.agents = const [],
    this.loadingAgents = true,
    this.selected,
    this.phase = FaceTimePhase.idle,
    this.statusText = "Pick an agent to call",
    this.caption = "",
    this.emotion = "",
  });

  final List<FaceTimeAgent> agents;
  final bool loadingAgents;
  final String? selected;
  final FaceTimePhase phase;
  final String statusText;
  final String caption;
  final String emotion;

  bool get inCall =>
      phase == FaceTimePhase.connecting || phase == FaceTimePhase.connected;

  FaceTimeState copyWith({
    List<FaceTimeAgent>? agents,
    bool? loadingAgents,
    Object? selected = _noChange,
    FaceTimePhase? phase,
    String? statusText,
    String? caption,
    String? emotion,
  }) {
    return FaceTimeState(
      agents: agents ?? this.agents,
      loadingAgents: loadingAgents ?? this.loadingAgents,
      selected:
          identical(selected, _noChange) ? this.selected : selected as String?,
      phase: phase ?? this.phase,
      statusText: statusText ?? this.statusText,
      caption: caption ?? this.caption,
      emotion: emotion ?? this.emotion,
    );
  }

  static const _noChange = Object();
}

/// Drives a FaceTime call: loads the agent roster, connects the avatar stream,
/// and exposes the remote [RTCVideoRenderer] for the view.
class FaceTimeController extends Notifier<FaceTimeState> {
  late final FaceTimeService _svc;
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  StreamSubscription<MediaStream?>? _streamSub;
  StreamSubscription<RTCPeerConnectionState>? _connSub;
  StreamSubscription<Map<String, dynamic>>? _ctlSub;
  bool _rendererReady = false;

  @override
  FaceTimeState build() {
    _svc = ref.watch(faceTimeServiceProvider);
    ref.onDispose(_disposeAll);
    unawaited(_init());
    return const FaceTimeState();
  }

  Future<void> _init() async {
    if (!_rendererReady) {
      await remoteRenderer.initialize();
      _rendererReady = true;
    }
    await loadAgents();
  }

  Future<void> loadAgents() async {
    state = state.copyWith(loadingAgents: true);
    try {
      final list = await _svc.agents();
      state = state.copyWith(
        agents: list,
        loadingAgents: false,
        selected: state.selected ??
            (list.isNotEmpty ? list.first.name : null),
      );
    } catch (e) {
      state = state.copyWith(
        loadingAgents: false,
        phase: FaceTimePhase.error,
        statusText: "Could not load agents: $e",
      );
    }
  }

  void select(String agentName) {
    if (state.inCall) return;
    state = state.copyWith(selected: agentName);
  }

  /// Absolute portrait URL for an agent (for the picker + idle avatar).
  String? portraitFor(FaceTimeAgent agent) =>
      agent.hasPortrait ? _svc.portraitUrl(agent.name, portraitPath: agent.portraitPath) : null;

  Future<void> start() async {
    final agent = state.selected;
    if (agent == null || state.inCall) return;
    state = state.copyWith(
      phase: FaceTimePhase.connecting,
      statusText: "Connecting to $agent…",
      caption: "",
      emotion: "",
    );

    _streamSub = _svc.remoteStream.listen((stream) {
      remoteRenderer.srcObject = stream;
    });
    _connSub = _svc.connectionState.listen(_onConnState);
    _ctlSub = _svc.controlMessages.listen(_onControl);

    try {
      await _svc.connect(agentName: agent);
    } catch (e) {
      state = state.copyWith(
        phase: FaceTimePhase.error,
        statusText: "Connection failed: $e",
      );
      await _cleanupCall();
    }
  }

  void _onConnState(RTCPeerConnectionState s) {
    switch (s) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        state = state.copyWith(
          phase: FaceTimePhase.connected,
          statusText: "Connected to ${state.selected}",
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        state = state.copyWith(
          phase: FaceTimePhase.error,
          statusText: "Connection failed",
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        state = state.copyWith(
          phase: FaceTimePhase.error,
          statusText: "Connection lost",
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        if (state.phase != FaceTimePhase.ended) {
          state = state.copyWith(
            phase: FaceTimePhase.ended,
            statusText: "Call ended",
          );
        }
      default:
        break;
    }
  }

  void _onControl(Map<String, dynamic> msg) {
    switch (msg["type"] as String?) {
      case "transcript":
        final role = msg["role"] as String?;
        final text = msg["text"] as String? ?? "";
        if (role == "assistant") {
          state = state.copyWith(caption: text);
        }
      case "emotion":
        final e = msg["emotion"] as String? ?? "";
        final i = (msg["intensity"] as num?)?.toDouble() ?? 0;
        state = state.copyWith(
          emotion: e.isEmpty ? "" : "$e (${(i * 100).round()}%)",
        );
      case "status":
        final m = msg["message"] as String?;
        if (m != null) state = state.copyWith(statusText: m);
    }
  }

  Future<void> hangUp() async {
    await _cleanupCall();
    state = state.copyWith(
      phase: FaceTimePhase.ended,
      statusText: "Call ended",
      caption: "",
      emotion: "",
    );
  }

  Future<void> _cleanupCall() async {
    await _streamSub?.cancel();
    await _connSub?.cancel();
    await _ctlSub?.cancel();
    _streamSub = null;
    _connSub = null;
    _ctlSub = null;
    remoteRenderer.srcObject = null;
    await _svc.hangUp();
  }

  Future<void> _disposeAll() async {
    await _cleanupCall();
    if (_rendererReady) await remoteRenderer.dispose();
    await _svc.dispose();
  }
}

/// FaceTime screen state provider.
final faceTimeControllerProvider =
    NotifierProvider<FaceTimeController, FaceTimeState>(
  FaceTimeController.new,
);

// ── Screen ────────────────────────────────────────────────────────────────────

/// FaceTime (avatar call) screen: pick an agent, see the portrait, then connect
/// the live avatar stream. Backed by the runtime-configurable web-UI.
class FaceTimeScreen extends ConsumerWidget {
  const FaceTimeScreen({super.key, this.initialAgent});

  /// Optional agent to preselect (e.g. from a deep link).
  final String? initialAgent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(faceTimeControllerProvider);
    final ctrl = ref.read(faceTimeControllerProvider.notifier);

    // Preselect a deep-linked agent once the roster lands.
    if (initialAgent != null &&
        !state.loadingAgents &&
        state.selected != initialAgent &&
        state.agents.any((a) => a.name == initialAgent)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ctrl.select(initialAgent!),
      );
    }

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: const Text("FaceTime"),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _stage(context, state, ctrl)),
            _controls(context, state, ctrl),
            if (!state.inCall) _agentPicker(context, state, ctrl),
          ],
        ),
      ),
    );
  }

  // The avatar / video stage (16:9), with caption + emotion overlays.
  Widget _stage(
      BuildContext context, FaceTimeState state, FaceTimeController ctrl) {
    final selectedAgent = state.agents
        .where((a) => a.name == state.selected)
        .cast<FaceTimeAgent?>()
        .firstOrNull;
    final portrait =
        selectedAgent == null ? null : ctrl.portraitFor(selectedAgent);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: SovereignColors.surfaceCard),
              // Idle / connecting: show the portrait. Connected: the stream.
              if (state.phase == FaceTimePhase.connected)
                RTCVideoView(
                  ctrl.remoteRenderer,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              else if (portrait != null)
                Image.network(
                  portrait,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) =>
                      _portraitFallback(state),
                )
              else
                _portraitFallback(state),

              // Agent name tag.
              if (state.selected != null)
                Positioned(
                  top: 12,
                  left: 12,
                  child: _pill(state.selected!),
                ),
              // Emotion badge.
              if (state.emotion.isNotEmpty)
                Positioned(top: 12, right: 12, child: _pill(state.emotion)),
              // Caption overlay.
              if (state.caption.isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 56,
                  child: Center(child: _pill(state.caption, maxLines: 3)),
                ),
              // Status bar.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 44,
                  color: Colors.black.withValues(alpha: 0.55),
                  alignment: Alignment.center,
                  child: Text(
                    state.statusText,
                    style: const TextStyle(
                      color: SovereignColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _portraitFallback(FaceTimeState state) {
    return Center(
      child: Icon(
        state.inCall ? Icons.videocam : Icons.account_circle,
        size: 96,
        color: SovereignColors.textTertiary,
      ),
    );
  }

  Widget _pill(String text, {int maxLines = 1}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SovereignColors.surfaceGlassBorder),
      ),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: SovereignColors.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _controls(
      BuildContext context, FaceTimeState state, FaceTimeController ctrl) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!state.inCall)
            FilledButton.icon(
              onPressed: state.selected == null ? null : ctrl.start,
              icon: const Icon(Icons.videocam),
              label: const Text("Start FaceTime"),
            )
          else
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.accentDanger,
              ),
              onPressed: ctrl.hangUp,
              icon: const Icon(Icons.call_end),
              label: const Text("End Call"),
            ),
        ],
      ),
    );
  }

  Widget _agentPicker(
      BuildContext context, FaceTimeState state, FaceTimeController ctrl) {
    if (state.loadingAgents) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.agents.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          "No FaceTime agents available",
          style: TextStyle(color: SovereignColors.textSecondary),
        ),
      );
    }
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: state.agents.length,
        separatorBuilder: (context, i) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final agent = state.agents[i];
          final selected = agent.name == state.selected;
          final portrait = ctrl.portraitFor(agent);
          return GestureDetector(
            onTap: () => ctrl.select(agent.name),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected
                          ? SovereignColors.accentEncrypt
                          : SovereignColors.surfaceGlassBorder,
                      width: selected ? 2.5 : 1,
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 26,
                    backgroundColor: SovereignColors.surfaceRaised,
                    backgroundImage:
                        portrait != null ? NetworkImage(portrait) : null,
                    child: portrait == null
                        ? Text(
                            agent.name.isNotEmpty
                                ? agent.name[0].toUpperCase()
                                : "?",
                            style: const TextStyle(
                              color: SovereignColors.textPrimary,
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: 64,
                  child: Text(
                    agent.name,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected
                          ? SovereignColors.textPrimary
                          : SovereignColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
