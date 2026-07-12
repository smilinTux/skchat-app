import "dart:async";
import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_webrtc/flutter_webrtc.dart";
import "package:web_socket_channel/web_socket_channel.dart";

import "backend_config.dart";

// ── Models ──────────────────────────────────────────────────────────────────

/// A FaceTime-capable agent, as returned by GET /api/facetime/agents.
///
/// The server lists every `~/.skcapstone/agents/<name>/` dir and flags whether
/// `avatar/portrait.png` exists. [portraitUrl] is the *relative* path the
/// server gives back (`/api/facetime/portrait/<name>`); callers turn it into an
/// absolute URL with [FaceTimeService.portraitUrl].
class FaceTimeAgent {
  const FaceTimeAgent({
    required this.name,
    this.hasPortrait = false,
    this.portraitPath,
  });

  /// Agent directory name (e.g. `lumina`, `opus`, `jarvis`).
  final String name;

  /// Whether the agent has a `portrait.png` avatar.
  final bool hasPortrait;

  /// Server-relative portrait URL, or null when [hasPortrait] is false.
  final String? portraitPath;

  factory FaceTimeAgent.fromJson(Map<String, dynamic> j) => FaceTimeAgent(
        name: j["name"] as String? ?? "",
        hasPortrait: j["has_portrait"] as bool? ?? false,
        portraitPath: j["portrait_url"] as String?,
      );
}

// ── Service ─────────────────────────────────────────────────────────────────

/// Talks to the SKChat FaceTime (avatar-call) surface on the web-UI.
///
/// Two halves:
///
///  1. **REST** (via [_dio]), the agent roster + portrait image URL:
///       - GET /api/facetime/agents            → list of [FaceTimeAgent]
///       - GET /api/facetime/portrait/{agent}  → PNG (URL only, not fetched)
///
///  2. **Signaling** ([connect]), the WebRTC *answer* side of the avatar
///     stream. This mirrors `static/facetime.html` exactly:
///       - Browser opens `/webrtc/ws?room=facetime-{agent}&peer=browser-XXXX`.
///       - The GPU server (aiortc + MuseTalk) is the **offerer**; it sends an
///         SDP `offer` wrapped in a `{type:"signal", from, data:{type,sdp}}`
///         envelope over the broker. We `setRemoteDescription`, create an
///         `answer`, and signal it back `{type:"signal", to:from, data:{...}}`.
///       - ICE trickles both ways inside the same `signal` envelope
///         (`data.candidate / sdpMid / sdpMLineIndex`); we broadcast ours to
///         `to:"*"` (the server is the only other peer in the room).
///       - The server's data channel carries JSON control frames
///         (`transcript` / `emotion` / `status`) surfaced on [controlMessages].
///
/// The web-UI base URL is repointed live by [backendConfigProvider]
/// (see [faceTimeServiceProvider]); nothing is hardcoded.
class FaceTimeService {
  FaceTimeService({Dio? dio, String? webuiBaseUrl})
      : _dio = dio ?? Dio(),
        _base = _stripSlash(webuiBaseUrl ?? kDefaultSkchatWebuiUrl);

  final Dio _dio;
  final String _base;

  // ── Signaling / call state ───────────────────────────────────────────────
  RTCPeerConnection? _pc;
  WebSocketChannel? _signaling;
  StreamSubscription<dynamic>? _signalingSub;

  final _remoteStreamCtl = StreamController<MediaStream?>.broadcast();
  final _connStateCtl = StreamController<RTCPeerConnectionState>.broadcast();
  final _controlCtl = StreamController<Map<String, dynamic>>.broadcast();

  /// The agent's avatar media stream (video + audio) once negotiated.
  Stream<MediaStream?> get remoteStream => _remoteStreamCtl.stream;

  /// Peer-connection lifecycle (connecting → connected → closed).
  Stream<RTCPeerConnectionState> get connectionState => _connStateCtl.stream;

  /// JSON control frames from the server data channel:
  /// `{type:"transcript", role, text}`, `{type:"emotion", emotion, intensity}`,
  /// `{type:"status", message}`.
  Stream<Map<String, dynamic>> get controlMessages => _controlCtl.stream;

  static String _stripSlash(String s) {
    var out = s.trim();
    while (out.endsWith("/")) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  // ── REST ───────────────────────────────────────────────────────────────────

  /// Fetch the list of FaceTime-capable agents.
  Future<List<FaceTimeAgent>> agents() async {
    final r =
        await _dio.get<Map<String, dynamic>>("$_base/api/facetime/agents");
    final list = (r.data?["agents"] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return list.map(FaceTimeAgent.fromJson).toList();
  }

  /// Absolute portrait URL for [agentName] (suitable for `Image.network`).
  ///
  /// Prefers the server-provided [agent.portraitPath] when present, otherwise
  /// constructs the canonical `/api/facetime/portrait/{agent}` path.
  String portraitUrl(String agentName, {String? portraitPath}) {
    final path = (portraitPath != null && portraitPath.isNotEmpty)
        ? portraitPath
        : "/api/facetime/portrait/$agentName";
    return path.startsWith("http") ? path : "$_base$path";
  }

  // ── WebRTC answer-side signaling ────────────────────────────────────────────

  /// Connect a FaceTime call to [agentName] and negotiate the avatar stream.
  ///
  /// Opens the signaling WebSocket and waits for the server's SDP offer; the
  /// peer connection is created lazily on first offer (matching the HTML).
  /// Listen to [remoteStream] / [connectionState] / [controlMessages] for
  /// results. Throws if the signaling socket cannot be opened.
  Future<void> connect({
    required String agentName,
    List<Map<String, dynamic>> iceServers = const [
      {"urls": "stun:stun.l.google.com:19302"},
    ],
  }) async {
    final room = "facetime-$agentName";
    final peer = "browser-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}";

    final wsBase = _wsBase(_base);
    final uri = Uri.parse("$wsBase/webrtc/ws?room=$room&peer=$peer");
    final ws = WebSocketChannel.connect(uri);
    _signaling = ws;
    // Surface a connect failure (handshake errors arrive on the stream).
    await ws.ready;

    _iceServers = iceServers;
    _signalingSub = ws.stream.listen(
      (data) => _handleSignaling(data as String),
      onError: (_) {},
      onDone: () {},
      cancelOnError: false,
    );
  }

  List<Map<String, dynamic>> _iceServers = const [];

  static String _wsBase(String httpBase) {
    if (httpBase.startsWith("https://")) {
      return "wss://${httpBase.substring("https://".length)}";
    }
    if (httpBase.startsWith("http://")) {
      return "ws://${httpBase.substring("http://".length)}";
    }
    return "wss://$httpBase";
  }

  Future<void> _handleSignaling(String raw) async {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg["type"] as String?) {
      case "signal":
        final from = msg["from"] as String?;
        final data = msg["data"];
        if (data is Map<String, dynamic>) {
          await _handleSignal(from, data);
        }
      case "welcome":
      case "peer_joined":
      case "peer_left":
        // Roster events, no action; the server drives the offer.
        break;
    }
  }

  Future<void> _handleSignal(String? from, Map<String, dynamic> data) async {
    final type = data["type"] as String?;
    if (type == "offer" && data["sdp"] is String) {
      _pc ??= await _createPeerConnection();
      await _pc!.setRemoteDescription(
        RTCSessionDescription(data["sdp"] as String, "offer"),
      );
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _emit({
        "type": "signal",
        "to": from ?? "*",
        "data": {"type": answer.type, "sdp": answer.sdp},
      });
    } else if (data["candidate"] != null) {
      try {
        await _pc?.addCandidate(RTCIceCandidate(
          data["candidate"] as String?,
          data["sdpMid"] as String?,
          data["sdpMLineIndex"] as int?,
        ));
      } catch (_) {}
    }
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    final pc = await createPeerConnection({
      "iceServers": _iceServers,
      "sdpSemantics": "unified-plan",
    });

    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteStreamCtl.add(event.streams[0]);
      }
    };

    pc.onConnectionState =
        (RTCPeerConnectionState s) => _connStateCtl.add(s);

    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      // Broadcast to the room, the server is the only other peer.
      _emit({
        "type": "signal",
        "to": "*",
        "data": {
          "candidate": c.candidate,
          "sdpMid": c.sdpMid,
          "sdpMLineIndex": c.sdpMLineIndex,
        },
      });
    };

    // Server-initiated data channel carries transcripts / emotion / status.
    pc.onDataChannel = (RTCDataChannel channel) {
      channel.onMessage = (RTCDataChannelMessage m) {
        try {
          final parsed = jsonDecode(m.text) as Map<String, dynamic>;
          _controlCtl.add(parsed);
        } catch (_) {}
      };
    };

    return pc;
  }

  void _emit(Map<String, dynamic> msg) {
    _signaling?.sink.add(jsonEncode(msg));
  }

  /// End the call and release the peer connection + signaling socket.
  Future<void> hangUp() async {
    await _signalingSub?.cancel();
    _signalingSub = null;
    await _signaling?.sink.close();
    _signaling = null;
    await _pc?.close();
    await _pc?.dispose();
    _pc = null;
  }

  /// Tear down all streams. Call when the owning provider/screen disposes.
  Future<void> dispose() async {
    await hangUp();
    if (!_remoteStreamCtl.isClosed) await _remoteStreamCtl.close();
    if (!_connStateCtl.isClosed) await _connStateCtl.close();
    if (!_controlCtl.isClosed) await _controlCtl.close();
  }
}

// ── Provider ────────────────────────────────────────────────────────────────

/// FaceTime service repointed live by the runtime backend config. Watching
/// [backendConfigProvider] rebuilds the service (and so the base URL) whenever
/// the user switches federation instances.
final faceTimeServiceProvider = Provider<FaceTimeService>((ref) {
  final base = ref.watch(
    backendConfigProvider.select((c) => c.skchatWebuiUrl),
  );
  return FaceTimeService(webuiBaseUrl: base);
});
