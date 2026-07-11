import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';

import 'backend_config.dart';

/// Compile-time default for the skchat web-UI LiveKit token-mint endpoint.
/// Now only the *seed* for the runtime-settable [backendConfigProvider]; the
/// live value comes from there so instances can be switched without a rebuild.
const _kDefaultWebuiUrl = kDefaultLivekitWebuiUrl;

/// Compile-time default LiveKit server WebSocket URL. Seed for
/// [backendConfigProvider]; live value comes from there.
const _kDefaultLiveKitUrl = kDefaultLivekitUrl;

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
      // The skchat webui returns the SFU wss URL under "url" (public-aware, e.g.
      // wss://<host>/livekit-ws). Accept "livekit_url" too for older servers.
      // Without this the field was null and the connect fell back to the
      // wss://localhost:8443 default, unreachable from a browser, so the join
      // died at /rtc/validate with "Room join failed".
      livekitUrl: (json['url'] ?? json['livekit_url']) as String?,
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

  /// Room event subscription — carries the data-channel receive-wire that
  /// feeds [_dataCtl] (and therefore [dataChannel] / the lane substrate).
  /// Without this, [sendData] publishes fine but inbound lane events (in-call
  /// chat, whiteboard, etc.) never arrive. Created in [_bindRoomListeners],
  /// torn down in [dispose].
  EventsListener<RoomEvent>? _roomEvents;

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
      'metadata': ?metadata,
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

    // Data-channel receive-wire: forward every DataReceivedEvent into
    // [_dataCtl] so [dataChannel] (and the lane substrate that maps over it)
    // actually receives peer-published lane events. `participant` is null when
    // the data originates from the server API, hence the empty-string fallback.
    _roomEvents = _room!.createListener()
      ..on<DataReceivedEvent>((event) {
        if (_dataCtl.isClosed) return;
        _dataCtl.add((
          topic: event.topic ?? '',
          payload: event.data,
          senderIdentity: event.participant?.identity ?? '',
        ));
      });
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

  // ── Device selection (camera / mic) ─────────────────────────────────────────

  /// Label substrings that mark a virtual / loopback capture device. These
  /// enumerate like a real device but frequently cannot actually stream (a dead
  /// DroidCam `/dev/video0`, an OBS virtual cam, etc.) which throws
  /// NotFound/NotReadable on capture. They are skipped when auto-picking a smart
  /// default so a phantom device never shadows the real webcam/mic. Match is a
  /// case-insensitive substring test on the device label. Mirrors the shipped
  /// web fix.
  static const List<String> virtualDevicePatterns = [
    'droidcam',
    'obs',
    'v4l2loopback',
    'virtual',
    'snap camera',
    'manycam',
    'null',
  ];

  /// True when [label] looks like a virtual / loopback device (case-insensitive
  /// substring match against [virtualDevicePatterns]).
  static bool isVirtualDeviceLabel(String label) {
    final l = label.toLowerCase();
    return virtualDevicePatterns.any(l.contains);
  }

  /// Pick a sensible default deviceId from [devices]: prefer the first
  /// NON-virtual device, falling back to the first device only when every
  /// candidate looks virtual. Returns null for an empty list. Do NOT blindly
  /// select the platform's first device (that is what handed a live user their
  /// dead DroidCam loopback while the real webcam sat unused).
  static String? pickDefaultDeviceId(List<MediaDevice> devices) {
    if (devices.isEmpty) return null;
    for (final d in devices) {
      if (!isVirtualDeviceLabel(d.label)) return d.deviceId;
    }
    return devices.first.deviceId;
  }

  /// Enumerate available microphone (audio input) devices.
  ///
  /// Device labels are only populated after a media-permission grant, so call
  /// this once the call is live (the published mic/cam already granted
  /// permission) to get human-readable names in the picker.
  Future<List<MediaDevice>> enumerateAudioInputs() =>
      Hardware.instance.enumerateDevices(type: 'audioinput');

  /// Enumerate available camera (video input) devices.
  Future<List<MediaDevice>> enumerateVideoInputs() =>
      Hardware.instance.enumerateDevices(type: 'videoinput');

  /// Switch the active microphone to [deviceId] WITHOUT dropping the call.
  ///
  /// If a mic track is already published, its capture device is restarted on the
  /// new id (audio keeps flowing, no reconnect). If no mic track is live yet the
  /// mic is published directly on the chosen device. Throws on capture failure
  /// (NotFound / NotReadable) so the caller can surface an inline message and
  /// keep the rest of the call working.
  Future<void> switchMicDevice(String deviceId) async {
    final lp = _localParticipant;
    if (lp == null) return;
    final track = lp.getTrackPublicationBySource(TrackSource.microphone)?.track;
    if (track is LocalAudioTrack) {
      await track.setDeviceId(deviceId);
    } else {
      await lp.setMicrophoneEnabled(
        true,
        audioCaptureOptions: AudioCaptureOptions(deviceId: deviceId),
      );
    }
  }

  /// Switch the active camera to [deviceId] WITHOUT dropping the call.
  ///
  /// If a camera track is already published, it is restarted on the new device;
  /// otherwise the camera is published directly on the chosen device. Throws on
  /// capture failure so the caller can surface an inline message (audio is
  /// unaffected).
  Future<void> switchCameraDevice(String deviceId) async {
    final lp = _localParticipant;
    if (lp == null) return;
    final track = lp.getTrackPublicationBySource(TrackSource.camera)?.track;
    if (track is LocalVideoTrack) {
      await track.switchCamera(deviceId);
    } else {
      await lp.setCameraEnabled(
        true,
        cameraCaptureOptions: CameraCaptureOptions(deviceId: deviceId),
      );
    }
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  /// Disconnect from the room and release all resources.
  Future<void> dispose() async {
    _room?.removeListener(_onRoomChanged);
    await _roomEvents?.dispose();
    _roomEvents = null;
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
  // Read the live backend config so the token-mint + SFU URLs follow the
  // selected federation instance. autoDispose recreates the service when the
  // config changes (a new call session then uses the new host).
  final cfg = ref.watch(backendConfigProvider);
  final svc = LiveKitCallService(
    // POST /livekit/token is served by the skchat web-UI (the same origin that
    // serves this app, e.g. the public Funnel), NOT the standalone livekit web
    // UI. Using livekitWebuiUrl here pointed the token mint at localhost:7779,
    // which a browser cannot reach, so every call died with "Room join failed"
    // (DioException connection error). The SFU wss URL still comes from the
    // token response (livekit_url), so only the mint base needed correcting.
    webuiBaseUrl: cfg.skchatWebuiUrl,
    livekitUrl: cfg.livekitUrl,
  );
  ref.onDispose(svc.dispose);
  return svc;
});
