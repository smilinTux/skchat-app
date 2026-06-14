import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';

/// Default base URL for the skchat web-UI LiveKit token mint endpoint.
/// Override at build time via --dart-define=LIVEKIT_WEBUI_URL=http://host:port
const _kDefaultWebuiUrl = String.fromEnvironment(
  'LIVEKIT_WEBUI_URL',
  defaultValue: 'http://localhost:7779',
);

/// Default LiveKit server WebSocket URL.
/// Override at build time via --dart-define=LIVEKIT_URL=wss://host:8443
const _kDefaultLiveKitUrl = String.fromEnvironment(
  'LIVEKIT_URL',
  defaultValue: 'wss://localhost:8443',
);

// ── Token response ─────────────────────────────────────────────────────────

/// Token + metadata returned by POST /livekit/token.
class LiveKitTokenResult {
  const LiveKitTokenResult({
    required this.token,
    required this.roomName,
    required this.identity,
    this.livekitUrl,
  });

  /// JWT for the LiveKit room connection.
  final String token;

  /// Fully-qualified room name (server-assigned or caller-supplied).
  final String roomName;

  /// Identity used in this room (typically the agent/user fingerprint).
  final String identity;

  /// LiveKit WebSocket URL returned by the server (overrides the default
  /// if present — allows the server to route to a geo-local SFU).
  final String? livekitUrl;

  factory LiveKitTokenResult.fromJson(Map<String, dynamic> json) {
    return LiveKitTokenResult(
      token: json['token'] as String? ?? '',
      roomName: json['room'] as String? ?? json['room_name'] as String? ?? '',
      identity: json['identity'] as String? ?? '',
      livekitUrl: json['livekit_url'] as String?,
    );
  }
}

// ── Participant snapshot ──────────────────────────────────────────────────

/// Lightweight view of a LiveKit participant surfaced to the UI layer.
class LiveKitParticipantSnapshot {
  const LiveKitParticipantSnapshot({
    required this.identity,
    required this.isLocal,
    required this.isMuted,
    required this.isCameraEnabled,
    this.canPublish = false,
    this.handRaised = false,
    this.isSpeaking = false,
    this.metadata,
  });

  final String identity;
  final bool isLocal;
  final bool isMuted;
  final bool isCameraEnabled;

  /// Whether the LiveKit grant lets this participant publish tracks.
  ///
  /// This is the authoritative speaker/listener signal: a speaker who
  /// self-mutes still has [canPublish] == true (a muted speaker, not a
  /// listener). Sourced from `Participant.permissions.canPublish`.
  final bool canPublish;

  /// Whether this participant has raised their hand (✋) to be invited to
  /// the stage. Parsed from the `hand_raised` key of the participant
  /// metadata JSON written by the Space moderation layer. Defaults to false
  /// on missing / malformed metadata.
  final bool handRaised;

  /// True when LiveKit detects active audio from this participant.
  final bool isSpeaking;

  /// Raw participant metadata JSON (as written by the Space moderation API).
  final String? metadata;

  /// Parse the `hand_raised` boolean out of a participant metadata JSON blob.
  ///
  /// The Space moderation layer writes
  /// `{"hand_raised": bool, "invited_to_stage": bool}` into participant
  /// metadata. This is defensive: any missing key, non-object payload, or
  /// invalid JSON yields false.
  static bool parseHandRaised(String? metadata) {
    if (metadata == null || metadata.isEmpty) return false;
    try {
      final decoded = jsonDecode(metadata);
      if (decoded is Map<String, dynamic>) {
        return decoded['hand_raised'] == true;
      }
    } on FormatException {
      // Malformed metadata — treat as no hand raised.
    }
    return false;
  }
}

// ── Service ────────────────────────────────────────────────────────────────

/// LiveKit SFU call service — group and agent room calls.
///
/// Use this alongside [WebRTCCallService] (direct P2P tier):
/// - **P2P** ([WebRTCCallService]): two-party calls, low-latency, no server.
/// - **SFU** ([LiveKitCallService]): group rooms, agent broadcast, recording.
///
/// Typical usage:
/// ```dart
/// final svc = LiveKitCallService();
/// await svc.joinRoom(roomName: 'sk-room-lumina-chef', identity: 'chef');
/// ```
///
/// Call [dispose] when the call ends to release all resources.
class LiveKitCallService {
  LiveKitCallService({
    String? webuiBaseUrl,
    String? livekitUrl,
  })  : _webuiBaseUrl = webuiBaseUrl ?? _kDefaultWebuiUrl,
        _defaultLivekitUrl = livekitUrl ?? _kDefaultLiveKitUrl,
        _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 10),
          ),
        );

  final String _webuiBaseUrl;
  final String _defaultLivekitUrl;
  final Dio _dio;

  Room? _room;
  LocalParticipant? _localParticipant;

  final _participantsCtl =
      StreamController<List<LiveKitParticipantSnapshot>>.broadcast();
  final _dataCtl = StreamController<
      ({
        String topic,
        List<int> payload,
        String senderIdentity,
      })>.broadcast();
  final _connStateCtl = StreamController<ConnectionState>.broadcast();

  /// Stream of participant snapshots — updated whenever participants join,
  /// leave, or change their track state.
  Stream<List<LiveKitParticipantSnapshot>> get participants =>
      _participantsCtl.stream;

  /// Data-channel messages published by any participant in the room.
  Stream<({String topic, List<int> payload, String senderIdentity})>
      get dataChannel => _dataCtl.stream;

  /// LiveKit room connection state changes.
  Stream<ConnectionState> get connectionState => _connStateCtl.stream;

  /// The underlying [Room] — null until [joinRoom] completes.
  Room? get room => _room;

  /// The local [LocalParticipant] — null until [joinRoom] completes.
  LocalParticipant? get localParticipant => _localParticipant;

  // ── Token mint ────────────────────────────────────────────────────────────

  /// Mint a room token by calling POST /livekit/token on the skchat web-UI.
  ///
  /// [roomName] — deterministic per-pair room, e.g. `sk-room-<fp1>-<fp2>`.
  ///              The server derives the canonical room from the sorted pair
  ///              so both parties always land in the same room.
  /// [identity] — caller's agent name or fingerprint.
  /// [metadata] — optional JSON blob attached to the participant.
  Future<LiveKitTokenResult> mintToken({
    required String roomName,
    required String identity,
    String? metadata,
  }) async {
    final body = <String, dynamic>{
      'room': roomName,
      'identity': identity,
      if (metadata != null) 'metadata': metadata,
    };
    final resp = await _dio.post<Map<String, dynamic>>(
      '$_webuiBaseUrl/livekit/token',
      data: body,
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    return LiveKitTokenResult.fromJson(resp.data ?? {});
  }

  // ── Room join / leave ─────────────────────────────────────────────────────

  /// Mint a token, connect to the LiveKit room, and publish mic (+ optional cam).
  ///
  /// [roomName] and [identity] are forwarded to [mintToken].
  /// [withVideo] — set true to also publish the camera.
  /// [metadata]  — optional JSON blob for this participant.
  ///
  /// Returns when the room is connected and tracks are published.
  Future<void> joinRoom({
    required String roomName,
    required String identity,
    bool withVideo = false,
    String? metadata,
  }) async {
    if (_room != null) await dispose();

    // 1. Mint a token from the web-UI.
    final tokenResult = await mintToken(
      roomName: roomName,
      identity: identity,
      metadata: metadata,
    );

    // 2. Prefer the server-supplied URL (geo-routing), fall back to default.
    final wsUrl = tokenResult.livekitUrl ?? _defaultLivekitUrl;

    // 3-4. Construct the room, bind listeners, connect.
    await _connectRoom(wsUrl: wsUrl, token: tokenResult.token);

    // 5. Publish tracks.
    await _localParticipant?.setMicrophoneEnabled(true);
    if (withVideo) {
      await _localParticipant?.setCameraEnabled(true);
    }

    _emitParticipants();
  }

  /// Connect using a **pre-minted, role-scoped** token (e.g. from
  /// [SpacesService]) instead of minting a generic [mintToken] one.
  ///
  /// [wsUrl] - the LiveKit WebSocket URL returned alongside the token.
  /// [token] - the role-scoped JWT (host / speaker / listener).
  ///
  /// Does NOT publish any tracks - the caller decides (via [setMicEnabled])
  /// based on the granted role / publish grants. Returns once connected.
  Future<void> connectWithToken({
    required String wsUrl,
    required String token,
  }) async {
    if (_room != null) await dispose();
    await _connectRoom(wsUrl: wsUrl, token: token);
    _emitParticipants();
  }

  /// Shared connect body used by [joinRoom] and [connectWithToken]: builds the
  /// [Room] with the standard publish options, wires listeners, connects, and
  /// captures the local participant. (DRY - single source of room wiring.)
  Future<void> _connectRoom({
    required String wsUrl,
    required String token,
  }) async {
    _room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioPublishOptions: const AudioPublishOptions(
          name: "mic",
          stream: "mic_audio",
        ),
        defaultVideoPublishOptions: const VideoPublishOptions(
          simulcast: true,
        ),
      ),
    );
    _bindRoomListeners();
    await _room!.connect(wsUrl, token);
    _localParticipant = _room!.localParticipant;
  }

  /// Disconnect from the room and clean up resources.
  Future<void> leaveRoom() => dispose();

  // ── Track controls ────────────────────────────────────────────────────────

  /// Mute / unmute the local microphone.
  Future<void> setMicEnabled(bool enabled) async {
    await _localParticipant?.setMicrophoneEnabled(enabled);
    _emitParticipants();
  }

  /// Enable / disable the local camera.
  Future<void> setCameraEnabled(bool enabled) async {
    await _localParticipant?.setCameraEnabled(enabled);
    _emitParticipants();
  }

  /// Start / stop sharing the local screen.
  ///
  /// Publishes (or unpublishes) a screen-share video track on the local
  /// participant. On platforms that require a capture prompt (desktop/web),
  /// the LiveKit client surfaces it; on mobile a foreground-service /
  /// broadcast-extension flow applies. Guarded for a null local participant
  /// (no-op until [joinRoom] / [connectWithToken] completes).
  Future<void> setScreenShareEnabled(bool enabled) async {
    await _localParticipant?.setScreenShareEnabled(enabled);
    _emitParticipants();
  }

  // ── Data channel ──────────────────────────────────────────────────────────

  /// Publish a data message to the room (all participants unless restricted).
  ///
  /// [topic] — semantic channel, e.g. 'chat', 'agent-cmd', 'reaction'.
  /// [payload] — raw bytes (caller serializes; UTF-8 for JSON).
  Future<void> sendData({
    required String topic,
    required List<int> payload,
    bool reliable = true,
    List<String>? destinationIdentities,
  }) async {
    if (_localParticipant == null) return;
    await _localParticipant!.publishData(
      payload,
      reliable: reliable,
      topic: topic,
      destinationIdentities: destinationIdentities,
    );
  }

  // ── Participants snapshot ─────────────────────────────────────────────────

  /// Current participant list (local + remotes).
  List<LiveKitParticipantSnapshot> get currentParticipants {
    if (_room == null) return [];
    final snapshots = <LiveKitParticipantSnapshot>[];

    // Local participant.
    final local = _room!.localParticipant;
    if (local != null) {
      snapshots.add(_snapshotLocal(local));
    }

    // Remote participants.
    for (final remote in _room!.remoteParticipants.values) {
      snapshots.add(_snapshotRemote(remote));
    }

    return snapshots;
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  void _bindRoomListeners() {
    _room!.addListener(_onRoomChanged);
  }

  void _onRoomChanged() {
    _emitParticipants();
    if (!_connStateCtl.isClosed) {
      _connStateCtl.add(_room!.connectionState);
    }
  }

  void _emitParticipants() {
    if (!_participantsCtl.isClosed) {
      _participantsCtl.add(currentParticipants);
    }
  }

  LiveKitParticipantSnapshot _snapshotLocal(LocalParticipant p) {
    return LiveKitParticipantSnapshot(
      identity: p.identity,
      isLocal: true,
      isMuted: !p.isMicrophoneEnabled(),
      isCameraEnabled: p.isCameraEnabled(),
      canPublish: p.permissions.canPublish,
      handRaised: LiveKitParticipantSnapshot.parseHandRaised(p.metadata),
      isSpeaking: p.isSpeaking,
      metadata: p.metadata,
    );
  }

  LiveKitParticipantSnapshot _snapshotRemote(RemoteParticipant p) {
    return LiveKitParticipantSnapshot(
      identity: p.identity,
      isLocal: false,
      isMuted: !p.isMicrophoneEnabled(),
      isCameraEnabled: p.isCameraEnabled(),
      canPublish: p.permissions.canPublish,
      handRaised: LiveKitParticipantSnapshot.parseHandRaised(p.metadata),
      isSpeaking: p.isSpeaking,
      metadata: p.metadata,
    );
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  /// Disconnect from the room and release all resources.
  Future<void> dispose() async {
    _room?.removeListener(_onRoomChanged);
    await _room?.disconnect();
    await _room?.dispose();
    _room = null;
    _localParticipant = null;
    if (!_participantsCtl.isClosed) await _participantsCtl.close();
    if (!_dataCtl.isClosed) await _dataCtl.close();
    if (!_connStateCtl.isClosed) await _connStateCtl.close();
  }
}

// ── Riverpod provider ──────────────────────────────────────────────────────

/// Scoped provider for [LiveKitCallService].
///
/// Override in tests or for a specific call session using
/// `ProviderScope(overrides: [liveKitCallServiceProvider.overrideWithValue(...)])`.
final liveKitCallServiceProvider =
    Provider.autoDispose<LiveKitCallService>((ref) {
  final svc = LiveKitCallService();
  ref.onDispose(svc.dispose);
  return svc;
});
