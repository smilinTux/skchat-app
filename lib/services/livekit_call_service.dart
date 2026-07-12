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
    this.isScreenSharing = false,
    this.canPublish = false,
    this.handRaised = false,
    this.isSpeaking = false,
    this.metadata,
  });

  final String identity;
  final bool isLocal;
  final bool isMuted;
  final bool isCameraEnabled;

  /// True when this participant is publishing a screen-share video track. The
  /// call UI promotes a sharing participant to a prominent "stage" tile so
  /// viewers see the shared content large (with the shared audio playing).
  final bool isScreenSharing;

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

  /// Set when a local capture device could not be published on join (missing,
  /// busy, or virtual-only). Non-fatal: the call still connects. The UI may
  /// surface this so the user knows to pick a device from the picker.
  String? mediaWarning;

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

  // ── Guest invite (shareable link, multi-party) ─────────────────────────────

  /// Mint a shareable guest-invite link for [room] via POST /guest/invite on
  /// the skchat web-UI (operator-gated server-side: loopback / tailnet, or a
  /// shared bearer token). ONE link admits MULTIPLE guests: each person who
  /// opens `/join/<room>?invite=<token>` becomes a distinct guest in the SAME
  /// LiveKit room as the host, so this is the "add people" / multi-party path.
  ///
  /// [display] is a display-name hint shown on the join page. [ttlSeconds] is
  /// the invite lifetime (default 8h). Returns the absolute invite_url. On web,
  /// a server-relative invite_url (when no funnel base is configured) is
  /// prefixed with the live page origin so the link is shareable as-is.
  ///
  /// Throws (DioException) on a non-2xx response so the caller can surface a
  /// friendly message (e.g. guest links disabled, or not operator-authorized).
  Future<String> mintGuestInvite({
    required String room,
    String display = 'Guest',
    int ttlSeconds = 28800,
  }) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '$_webuiBaseUrl/guest/invite',
      // The server reads `ttl`; `ttl_seconds` is sent too for callers/mirrors
      // that expect that key. Unknown keys are ignored server-side.
      data: <String, dynamic>{
        'room': room,
        'display': display,
        'ttl': ttlSeconds,
        'ttl_seconds': ttlSeconds,
      },
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final data = resp.data ?? const <String, dynamic>{};
    final raw = (data['invite_url'] as String?) ?? '';
    if (raw.isEmpty) return raw;
    if (raw.startsWith('http')) return raw;
    // Server-relative (no funnel base configured): prefix a usable origin.
    final base = _webuiBaseUrl.endsWith('/')
        ? _webuiBaseUrl.substring(0, _webuiBaseUrl.length - 1)
        : _webuiBaseUrl;
    final path = raw.startsWith('/') ? raw : '/$raw';
    return '$base$path';
  }

  // ── Agent invite ────────────────────────────────────────────────────────────

  /// Pull an AI agent (default Lumina) into [room] so she joins the live call.
  ///
  /// Calls POST /conf/{room}/invite-agent on the skchat web-UI, which spawns the
  /// agent's media stack into that exact room. This works both for a registered
  /// conference (host-gated server-side) and for a plain 1:1 / group call room
  /// the app is already connected to (served for a tailnet caller; the backend
  /// returns a clean error otherwise).
  ///
  /// [requester] is the caller's own identity (used for the conf host-gate);
  /// [greet] is an optional opening line for the agent to speak on join.
  ///
  /// Throws an [Exception] carrying a human-readable message on a backend
  /// rejection (e.g. not permitted, agent host unavailable) so the caller can
  /// surface it in a snackbar.
  Future<void> inviteAgent({
    required String room,
    String agent = 'lumina',
    String? requester,
    String? greet,
  }) async {
    final body = <String, dynamic>{
      'agent': agent,
      'requester': ?requester,
      'greet': ?greet,
    };
    try {
      await _dio.post<Map<String, dynamic>>(
        '$_webuiBaseUrl/conf/$room/invite-agent',
        data: body,
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
    } on DioException catch (e) {
      final data = e.response?.data;
      final detail =
          (data is Map && data['detail'] is String) ? data['detail'] as String : null;
      final code = e.response?.statusCode;
      throw Exception(
        detail ?? 'agent invite failed${code == null ? '' : ' (HTTP $code)'}',
      );
    }
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

    // 3-4. Construct the room, bind listeners, connect. Pass our own identity so
    // the sovereign-ICE fetch can key the ephemeral TURN cred off this peer.
    await _connectRoom(
      wsUrl: wsUrl,
      token: tokenResult.token,
      identity: identity,
    );

    // 5. Publish tracks. The room is already connected at this point, so a
    // missing, busy, or virtual-only capture device (NotFoundError /
    // NotReadableError) must NOT tear the whole call down. Publish best-effort:
    // stay in the room without the failed track. The user can pick a working
    // device from the in-call device picker, or just listen.
    try {
      await _localParticipant?.setMicrophoneEnabled(true);
    } catch (e) {
      mediaWarning = 'Microphone unavailable: $e';
    }
    if (withVideo) {
      try {
        await _localParticipant?.setCameraEnabled(true);
      } catch (e) {
        mediaWarning = 'Camera unavailable: $e';
      }
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
  ///
  /// [identity] - our own identity/fingerprint, forwarded to the sovereign-ICE
  /// fetch as the `peer` hint so the ephemeral TURN credential is keyed to us.
  /// Optional: a null / empty identity still fetches (the endpoint falls back to
  /// the local FQID), and the whole ICE step is best-effort anyway.
  Future<void> _connectRoom({
    required String wsUrl,
    required String token,
    String? identity,
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
          // Content-friendly screen-share publish encoding: 1080p30 at a high
          // ceiling (4 Mbps) so streamed content (e.g. Kodi) stays crisp, and a
          // resolution-first degradation policy so text/detail is preserved when
          // bandwidth dips (drop framerate before sharpness).
          screenShareEncoding: VideoEncoding(
            maxFramerate: 30,
            maxBitrate: 4 * 1000 * 1000,
          ),
          degradationPreference: DegradationPreference.maintainResolution,
        ),
        // Capture the screen at up to 1080p30 by default (the toggle path below
        // may override with captureScreenAudio for the browser tab-audio case).
        defaultScreenShareCaptureOptions: const ScreenShareCaptureOptions(
          params: VideoParametersPresets.screenShareH1080FPS30,
        ),
      ),
    );
    _bindRoomListeners();
    // Sovereign ICE: pull STUN/TURN from the web-UI so off-tailnet / cellular
    // peerconnections relay through the sovereign coturn instead of timing out
    // ("timed out waiting for peerconnection to connect"). Best-effort: a null
    // result connects with the SFU's default ICE rather than blocking the call.
    // Mirrors the web guest page (static/livekit.html).
    final iceConfig = await fetchIceConfig(identity);
    await _room!.connect(
      wsUrl,
      token,
      connectOptions: ConnectOptions(
        rtcConfiguration: iceConfig ?? const RTCConfiguration(),
      ),
    );
    _localParticipant = _room!.localParticipant;
  }

  // ── Sovereign ICE (STUN / TURN) ─────────────────────────────────────────────

  /// Fetch the sovereign ICE (STUN / TURN) config from the skchat web-UI and map
  /// it to a livekit_client [RTCConfiguration].
  ///
  /// Calls `GET ${_webuiBaseUrl}/connectivity/ice?peer=<identity>`, which returns
  /// `{ice_servers: [{urls, username?, credential?}], policy}`. The result is
  /// passed to [Room.connect] via [ConnectOptions.rtcConfiguration] so the
  /// peerconnection can relay through the sovereign coturn.
  ///
  /// Best-effort by design: any failure (network error, non-200, malformed body,
  /// no servers) returns null so the caller connects with the SFU's default ICE
  /// rather than blocking or failing the call. Never throws. Mirrors
  /// static/livekit.html.
  Future<RTCConfiguration?> fetchIceConfig(String? identity) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '$_webuiBaseUrl/connectivity/ice',
        queryParameters: <String, dynamic>{
          if (identity != null && identity.isNotEmpty) 'peer': identity,
        },
      );
      final data = resp.data;
      if (data == null) return null;
      final servers = parseIceServers(data['ice_servers']);
      if (servers.isEmpty) return null;
      return RTCConfiguration(
        iceServers: servers,
        iceTransportPolicy: parseIcePolicy(data['policy']),
      );
    } catch (_) {
      // Best-effort: never let an ICE fetch failure block or fail the call.
      return null;
    }
  }

  /// Map the server's `ice_servers` JSON array into livekit_client
  /// [RTCIceServer]s.
  ///
  /// Each entry is `{urls: string | [string], username?, credential?}`. `urls`
  /// may be a single string or a list of strings (both are valid WebRTC shapes);
  /// both are normalized to a `List<String>`. Entries with no usable urls, and
  /// any non-object / non-list payload, are skipped. Never throws: a malformed
  /// payload yields an empty list.
  static List<RTCIceServer> parseIceServers(dynamic raw) {
    if (raw is! List) return const <RTCIceServer>[];
    final out = <RTCIceServer>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final urlsRaw = entry['urls'];
      final urls = <String>[];
      if (urlsRaw is String) {
        if (urlsRaw.isNotEmpty) urls.add(urlsRaw);
      } else if (urlsRaw is List) {
        for (final u in urlsRaw) {
          if (u is String && u.isNotEmpty) urls.add(u);
        }
      }
      if (urls.isEmpty) continue;
      final username = entry['username'];
      final credential = entry['credential'];
      out.add(RTCIceServer(
        urls: urls,
        username: username is String ? username : null,
        credential: credential is String ? credential : null,
      ));
    }
    return out;
  }

  /// Parse the transport-policy string into the livekit_client enum. The server
  /// sends 'all' (STUN + TURN, direct preferred) or 'relay' (TURN only).
  /// Defaults to [RTCIceTransportPolicy.all] for anything else / missing.
  static RTCIceTransportPolicy parseIcePolicy(dynamic raw) =>
      raw == 'relay' ? RTCIceTransportPolicy.relay : RTCIceTransportPolicy.all;

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

  /// Start / stop sharing the local screen, WITH audio.
  ///
  /// Publishes (or unpublishes) a screen-share video track on the local
  /// participant. On platforms that require a capture prompt (desktop/web),
  /// the LiveKit client surfaces it; on mobile a foreground-service /
  /// broadcast-extension flow applies. Guarded for a null local participant
  /// (no-op until [joinRoom] / [connectWithToken] completes).
  ///
  /// Audio: when [withAudio] is true (the default) we ask the browser to also
  /// capture the shared surface's audio (`captureScreenAudio`). Chromium
  /// reliably delivers this for a shared browser TAB, so a tab-shared video
  /// plays with sound on every viewer. For a DESKTOP app (e.g. Kodi on Linux)
  /// full system-audio capture through getDisplayMedia is unreliable, so the
  /// robust path there is to select a PulseAudio `Monitor of ...` source as
  /// the microphone in the device picker: that publishes desktop audio as a
  /// normal mic track alongside this screen video. See docs for the exact
  /// `pactl` / monitor-source steps.
  ///
  /// The screen video is captured/published at up to 1080p30 with a
  /// resolution-first degradation policy (set on the room's
  /// [VideoPublishOptions]) so content looks decent.
  Future<void> setScreenShareEnabled(bool enabled,
      {bool withAudio = true}) async {
    if (enabled) {
      await _localParticipant?.setScreenShareEnabled(
        true,
        captureScreenAudio: withAudio,
        screenShareCaptureOptions: const ScreenShareCaptureOptions(
          captureScreenAudio: true,
          params: VideoParametersPresets.screenShareH1080FPS30,
        ),
      );
    } else {
      await _localParticipant?.setScreenShareEnabled(false);
    }
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
    //
    // Live roster wire: [Room.addListener] (a ChangeNotifier) does NOT reliably
    // fire for REMOTE ParticipantConnected / Disconnected in livekit_client
    // 2.2.6. The notifier largely reflects LOCAL state. A roster driven only by
    // [_onRoomChanged] therefore shows each device the participant list AS OF
    // WHEN IT JOINED and never updates when others join or leave later (device 1
    // stuck at 1, device 2 at 2, device 3 saw all 3). Subscribe to the explicit
    // RoomEvents below and re-emit the snapshot on every membership or track
    // change so the participant count, tiles, and the screen-share stage stay
    // live for everyone. The (un)publish / (un)subscribe events also make a LATE
    // screen-share appear on the stage for people already in the room, with no
    // rejoin: when the host starts sharing, viewers get TrackPublished /
    // TrackSubscribed and re-snapshot with the sharer's isScreenSharing flag set.
    _roomEvents = _room!.createListener()
      ..on<DataReceivedEvent>((event) {
        if (_dataCtl.isClosed) return;
        _dataCtl.add((
          topic: event.topic ?? '',
          payload: event.data,
          senderIdentity: event.participant?.identity ?? '',
        ));
      })
      // Membership: someone joined or left the room.
      ..on<ParticipantConnectedEvent>((_) => _emitParticipants())
      ..on<ParticipantDisconnectedEvent>((_) => _emitParticipants())
      // Remote tracks: (un)published and (un)subscribed. TrackSubscribed is what
      // surfaces a remote screen-share on the stage; TrackPublished covers the
      // pre-subscribe beat so the roster reflects the new publication promptly.
      ..on<TrackPublishedEvent>((_) => _emitParticipants())
      ..on<TrackUnpublishedEvent>((_) => _emitParticipants())
      ..on<TrackSubscribedEvent>((_) => _emitParticipants())
      ..on<TrackUnsubscribedEvent>((_) => _emitParticipants())
      // Local tracks: our own screen-share start / stop must re-snapshot so the
      // local stage tile appears / clears without waiting on a remote round-trip.
      ..on<LocalTrackPublishedEvent>((_) => _emitParticipants())
      ..on<LocalTrackUnpublishedEvent>((_) => _emitParticipants())
      // Mute state: keep the muted / speaking dot on every tile current.
      ..on<TrackMutedEvent>((_) => _emitParticipants())
      ..on<TrackUnmutedEvent>((_) => _emitParticipants())
      // Metadata: hand-raise / stage-invite changes written by the Space
      // moderation layer drive the handRaised flag on the snapshot.
      ..on<ParticipantMetadataUpdatedEvent>((_) => _emitParticipants());
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
      isScreenSharing:
          p.getTrackPublicationBySource(TrackSource.screenShareVideo) != null,
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
      isScreenSharing:
          p.getTrackPublicationBySource(TrackSource.screenShareVideo) != null,
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
  ///
  /// EXCEPTION: a PulseAudio / PipeWire `Monitor of ...` source is NOT
  /// treated as virtual even though its name may contain a filtered word
  /// (e.g. "Monitor of Virtual Sink"). A monitor source is exactly how a Linux
  /// user streams DESKTOP audio (e.g. Kodi) into a call: it captures whatever
  /// is playing on that output sink. Filtering it out would hide the one input
  /// a screen-sharer needs, so monitor sources are always allowed.
  static bool isVirtualDeviceLabel(String label) {
    final l = label.toLowerCase();
    if (l.contains('monitor')) return false;
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
