import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';

import 'backend_config.dart';
import 'screen_awake.dart';
import 'system_audio_sources.dart';

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
  /// if present, allows the server to route to a geo-local SFU).
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
    this.canPublishVideo = true,
    this.handRaised = false,
    this.invitedToStage = false,
    this.isSpeaking = false,
    this.audioLevel = 0,
    this.connectionQuality = ConnectionQuality.unknown,
    this.metadata,
    this.soulFingerprint,
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

  /// SHARECTL-app: whether this participant's LiveKit grant currently
  /// allows publishing VIDEO sources (camera or screen-share), independent
  /// of [canPublish] (the overall publish grant, which stays true so a
  /// speaker can still talk). Derived from
  /// `Participant.permissions.canPublishSources` via
  /// [canPublishVideoFromSourceNames]; see that method's doc comment for
  /// the installed livekit_client 2.5.0+hotfix.3 API this reads.
  ///
  /// Defaults to true: an EMPTY canPublishSources list means the server has
  /// not applied a source-level restriction (the default policy is
  /// unchanged, "any speaker can share everything" per
  /// docs/superpowers/specs/2026-07-18-spaces-host-share-control-design.md
  /// in the skchat server repo), so an empty list must NOT read as "no
  /// video allowed." Once the host disables sharing (server narrows
  /// canPublishSources to mic-only), this flips false; re-allow (full
  /// sources restored) flips it back. Gates the local speaker's own "Go
  /// live" affordance in space_room_screen.dart's control bar, and lets the
  /// host sheet reflect a remote speaker's current sharing state.
  final bool canPublishVideo;

  /// Whether this participant has raised their hand (✋) to be invited to
  /// the stage. Parsed from the `hand_raised` key of the participant
  /// metadata JSON written by the Space moderation layer. Defaults to false
  /// on missing / malformed metadata.
  final bool handRaised;

  /// Whether the host has invited this participant to the stage (X1: the
  /// "Join stage" prompt). Parsed from the `invited_to_stage` key of the
  /// same participant metadata JSON as [handRaised]. The Space moderation
  /// layer's AND-gate flips [canPublish] only once BOTH [handRaised] and
  /// [invitedToStage] are true; a host invite alone (this flag true, hand
  /// not yet raised) leaves the participant a listener until they accept by
  /// raising their hand (see [SpaceRoomNotifier.raiseHand] in
  /// space_room_screen.dart, which re-uses the same raise-hand call to
  /// complete the gate). Defaults to false on missing / malformed metadata.
  final bool invitedToStage;

  /// True when LiveKit detects active audio from this participant. This is
  /// a THRESHOLD LiveKit itself applies to [audioLevel], not an independent
  /// measurement, so it can only ever answer "is this person speaking right
  /// now", never "who among several speakers is loudest". Kept alongside
  /// [audioLevel] rather than replaced by it: a simple mute/speaking dot on
  /// a tile wants the cheap bool, a dominant-speaker layout wants the
  /// continuous number.
  final bool isSpeaking;

  /// Continuous LiveKit audio level for this participant, in [0, 1]. This is
  /// the signal [isSpeaking] is only a threshold OF: sourced from
  /// `Participant.audioLevel` (installed livekit_client 2.5.0+hotfix.3,
  /// src/participant/participant.dart:52, `double audioLevel = 0`), which
  /// the SDK updates from the SFU's `ActiveSpeakersChangedEvent`. The SDK
  /// already keeps `Room.activeSpeakers` sorted by this value descending
  /// (src/core/room.dart:760), so this is also what any future
  /// dominant-speaker layout or speaking-hysteresis logic needs to read;
  /// a bool cannot express "who is loudest" no matter how it is wired.
  /// Defaults to 0 (silent) until the first ActiveSpeakersChangedEvent
  /// arrives for this participant.
  final double audioLevel;

  /// LiveKit's connection-quality estimate for this participant (the link
  /// between them and the SFU). Sourced from `Participant.connectionQuality`
  /// and refreshed on every [ParticipantConnectionQualityUpdatedEvent]. The UI
  /// renders this as a subtle signal-bars icon. Defaults to
  /// [ConnectionQuality.unknown] until the first server estimate arrives.
  final ConnectionQuality connectionQuality;

  /// Raw participant metadata JSON (as written by the Space moderation API).
  final String? metadata;

  /// This participant's capauth fingerprint, set by the server at token mint and
  /// carried in the participant metadata (M1b trust badges). Null/empty for an
  /// unknown/guest participant (keyless -> no badge). Because a guest lacks the
  /// `can_update_own_metadata` grant, this is unspoofable client-side.
  final String? soulFingerprint;

  /// Parse the server-set `soul_fingerprint` out of a participant metadata JSON
  /// blob. Defensive (same contract as [parseHandRaised]): any missing key,
  /// non-object payload, or malformed JSON yields null (keyless).
  static String? parseSoulFingerprint(String? metadata) {
    if (metadata == null || metadata.isEmpty) return null;
    try {
      final decoded = jsonDecode(metadata);
      if (decoded is Map<String, dynamic>) {
        final fp = decoded['soul_fingerprint'];
        if (fp is String && fp.isNotEmpty) return fp;
      }
    } on FormatException {
      // Malformed metadata, treat as keyless.
    }
    return null;
  }

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
      // Malformed metadata, treat as no hand raised.
    }
    return false;
  }

  /// Parse the `invited_to_stage` boolean out of a participant metadata JSON
  /// blob. See [parseHandRaised] for the shared shape / defensiveness notes;
  /// this reads the sibling key the Space moderation layer writes into the
  /// same object.
  static bool parseInvitedToStage(String? metadata) {
    if (metadata == null || metadata.isEmpty) return false;
    try {
      final decoded = jsonDecode(metadata);
      if (decoded is Map<String, dynamic>) {
        return decoded['invited_to_stage'] == true;
      }
    } on FormatException {
      // Malformed metadata, treat as no invite.
    }
    return false;
  }

  /// SHARECTL-app: derives [canPublishVideo] from the raw source NAMES
  /// reported by `ParticipantPermissions.canPublishSources`.
  ///
  /// API confirmed against the INSTALLED livekit_client 2.5.0+hotfix.3
  /// source: `ParticipantPermissions.canPublishSources` (lib/src/types/
  /// participant_permissions.dart) is a `List<lk_models.TrackSource>`,
  /// where `lk_models.TrackSource` is the PROTOBUF enum (lib/src/proto/
  /// livekit_models.pbenum.dart: UNKNOWN=0, CAMERA=1, MICROPHONE=2,
  /// SCREEN_SHARE=3, SCREEN_SHARE_AUDIO=4), NOT the client-facing
  /// `TrackSource` enum the rest of this file uses for
  /// `getTrackPublicationBySource`/`setSourceEnabled` (lib/src/types/
  /// other.dart: unknown, camera, microphone, screenShareVideo,
  /// screenShareAudio). The livekit_client barrel (lib/livekit_client.dart)
  /// exports `other.dart`'s `TrackSource` under the bare name and does NOT
  /// export the proto enum or the `toLKType()` bridge between the two
  /// (`export 'src/extensions.dart' show WidgetsBindingCompatible;` hides
  /// it), so this method takes each entry's `.name` (a `ProtobufEnum`
  /// member, always public, e.g. protobuf-4.2.0/lib/src/protobuf/
  /// protobuf_enum.dart) rather than importing the internal proto library
  /// by path. Call sites map the real SDK values with `.name` before
  /// calling this (see [_snapshotLocal]/[_snapshotRemote] in
  /// LiveKitCallService), which keeps this derivation on plain
  /// `List<String>` and independently unit-testable.
  ///
  /// An EMPTY list means the server has not applied a source-level
  /// restriction (default policy unchanged: any speaker can share
  /// everything), so this defaults to true rather than false. The server
  /// contract (2026-07-18-spaces-host-share-control-design.md) narrows the
  /// list to `[MICROPHONE]` to disable sharing and restores all four names
  /// to re-allow it.
  static bool canPublishVideoFromSourceNames(List<String> sourceNames) {
    if (sourceNames.isEmpty) return true;
    return sourceNames.contains('CAMERA') ||
        sourceNames.contains('SCREEN_SHARE');
  }
}

/// Screen-share quality tier used to build the capture + publish options in
/// [LiveKitCallService.screenShareCaptureOptionsFor] /
/// [LiveKitCallService.screenSharePublishOptionsFor]. See the doc comment on
/// [LiveKitCallService.screenSharePublishOptionsFor] for the SDK-source
/// rationale behind each tier's numbers.
enum ScreenShareFrameRate {
  /// LAN-tuned default: 1080p30, 4 Mbps ceiling, tuned for smooth motion
  /// content (e.g. streaming Kodi/video through Spaces on a gigabit LAN).
  standard,

  /// Previous 15 fps / 2.5 Mbps preset, kept as an explicit fallback for a
  /// constrained network (matches the SDK's own screenShareH1080FPS15).
  lowBandwidth,
}

// ── Service ────────────────────────────────────────────────────────────────

/// LiveKit SFU call service, the single funnel for calling: 1:1 calls (via
/// [CallSession]), group rooms, and agent broadcast/recording all drive this.
/// The legacy direct-P2P WebRTC tier (`WebRTCCallService`) was retired; every
/// call now rings and connects through a server-derived room + minted token.
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
    ScreenAwake? screenAwake,
  })  : _screenAwake = screenAwake ?? ScreenAwake(),
        _webuiBaseUrl = webuiBaseUrl ?? _kDefaultWebuiUrl,
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

  /// Keeps the device screen from blanking while a room is connected. See
  /// [ScreenAwake]; injectable so a test can observe it without a platform
  /// channel.
  final ScreenAwake _screenAwake;

  /// Set when a local capture device could not be published on join (missing,
  /// busy, or virtual-only). Non-fatal: the call still connects. The UI may
  /// surface this so the user knows to pick a device from the picker.
  String? mediaWarning;

  Room? _room;
  LocalParticipant? _localParticipant;

  /// The dedicated system-audio (screen-share audio) track, when publishing
  /// system audio. Kept separate from the voice mic so mic processing is
  /// untouched. Null when not sharing system audio.
  LocalTrack? _systemAudioTrack;

  /// The LiveKit token used for the current room connection (minted by
  /// [joinRoom] or supplied to [connectWithToken]). Exposed so the UI can
  /// forward it to the cast control plane, which authorizes an HLS egress by a
  /// valid room token when the caller is off-tailnet (over the Funnel).
  String? _lastToken;
  String? get lastToken => _lastToken;

  /// Room event subscription, carries the data-channel receive-wire that
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
  final _micEnabledCtl = StreamController<bool>.broadcast();
  final _externalMuteCtl = StreamController<void>.broadcast();

  /// True while [setMicEnabled] has an in-flight caller-initiated disable
  /// (an explicit toggle; content audio, TrackSource.screenShareAudio, is an
  /// independent coexisting source and does NOT flip this, see the DECOUPLE
  /// doc comment on [setMicEnabled]). Guards [_reconcileExternalMicMute] so
  /// a mute WE requested is never mistaken for a server-initiated one (see
  /// that method).
  ///
  /// RACE ANALYSIS: the SDK dispatches the local TrackMutedEvent for a
  /// self-mute through its own room-event bus, an async chain roughly two
  /// microtask hops deep relative to setMicrophoneEnabled()'s future
  /// completing. Clearing this flag synchronously right after our own emit
  /// sits at a similar microtask depth, so the ordering between the clear
  /// and the SDK's dispatch was implementation-defined and an SDK bump
  /// could flip it (a self-mute event landing AFTER the clear would fire a
  /// spurious "muted by host" notice; cosmetic, state stays correct, but
  /// avoidable). The clear is therefore DEFERRED one extra microtask (see
  /// setMicEnabled) so the guard outlives the SDK's dispatch chain with
  /// margin. [_selfMuteGeneration] keeps a deferred clear from an EARLIER
  /// disable prematurely ending the guard window of a newer overlapping
  /// one.
  bool _selfMuteInFlight = false;
  int _selfMuteGeneration = 0;

  /// Stream of participant snapshots, updated whenever participants join,
  /// leave, or change their track state.
  Stream<List<LiveKitParticipantSnapshot>> get participants =>
      _participantsCtl.stream;

  /// Data-channel messages published by any participant in the room.
  Stream<({String topic, List<int> payload, String senderIdentity})>
      get dataChannel => _dataCtl.stream;

  /// LiveKit room connection state changes.
  Stream<ConnectionState> get connectionState => _connStateCtl.stream;

  /// Emits the local microphone's enabled state whenever [setMicEnabled]
  /// changes it, for ANY reason: today that is an explicit caller toggle.
  /// DECOUPLE: the mic (TrackSource.microphone) and content audio
  /// (TrackSource.screenShareAudio, see [startScreenShareSystemAudio]) are
  /// independent coexisting sources, so starting/stopping content audio
  /// never flips the mic and is NOT one of the reasons this stream emits.
  /// Every mic-enabled change funnels through [setMicEnabled], so this is
  /// the single seam UI state should follow instead of tracking its own
  /// copy that only updates on a manual toggle call, see `SpaceRoomNotifier`
  /// for the consumer.
  Stream<bool> get micEnabledChanges => _micEnabledCtl.stream;

  /// Fires whenever the local mic goes muted from OUTSIDE this service, i.e.
  /// a server-initiated mute the local side never requested (the moderation
  /// layer's host force-mute, `MuteRoomTrackRequest`, muting the target's
  /// live mic publication). Every caller-initiated disable (an explicit
  /// toggle; content audio starting/stopping does NOT count, see the
  /// DECOUPLE doc comment on [setMicEnabled]) already funnels through
  /// [setMicEnabled] and is excluded here (see [_reconcileExternalMicMute]),
  /// so this is purely the "someone else did this to me" signal the UI can
  /// use to show a "muted by host" notice. [micEnabledChanges] still carries
  /// the boolean state change either way; this stream is additive
  /// observability only, no payload beyond "it happened".
  Stream<void> get externalMuteEvents => _externalMuteCtl.stream;

  /// The underlying [Room], null until [joinRoom] completes.
  Room? get room => _room;

  /// The local [LocalParticipant], null until [joinRoom] completes.
  LocalParticipant? get localParticipant => _localParticipant;

  // ── Token mint ────────────────────────────────────────────────────────────

  /// Mint a room token by calling POST /livekit/token on the skchat web-UI.
  ///
  /// [roomName], deterministic per-pair room, e.g. `sk-room-<fp1>-<fp2>`.
  ///              The server derives the canonical room from the sorted pair
  ///              so both parties always land in the same room.
  /// [identity], caller's agent name or fingerprint.
  /// [metadata], optional JSON blob attached to the participant.
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
  /// [withVideo], set true to also publish the camera.
  /// [metadata] , optional JSON blob for this participant.
  ///
  /// Returns when the room is connected and tracks are published.
  Future<void> joinRoom({
    required String roomName,
    required String identity,
    bool withVideo = false,
    String? metadata,
  }) async {
    // Tear the previous room down, but keep this service alive: a re-join must
    // not close the streams the new room is about to publish on.
    if (_room != null) await leaveRoom();

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
    // See [joinRoom]: leaveRoom, not dispose, so the service survives the swap.
    if (_room != null) await leaveRoom();
    await _connectRoom(wsUrl: wsUrl, token: token);
    _emitParticipants();
  }

  /// [RoomOptions] used for every room this service connects.
  ///
  /// `defaultVideoPublishOptions` is deliberately LEFT AT THE SDK DEFAULT
  /// (`const VideoPublishOptions()`: simulcast on, no forced encoding, no
  /// degradation override, no name). The SDK falls back to that room default
  /// for any video publish that does not pass explicit options
  /// (publishVideoTrack, src/participant/local.dart:207-208), which includes
  /// every bare `setCameraEnabled(true)` camera publish in this app. Screen
  /// share must therefore NOT be tuned here: its options travel explicitly
  /// with the publish call in [setScreenShareEnabled] (via
  /// [screenSharePublishOptionsFor]), so a room-level override would only
  /// leak screen-share tuning (simulcast off, maintainFramerate, the
  /// "screenshare" track name) onto CAMERA tracks.
  ///
  /// `defaultScreenShareCaptureOptions` is screen-share-only by definition
  /// (used by `LocalVideoTrack.createScreenShareTrack`, never by camera
  /// capture), so pinning it to the standard tier is safe and keeps any
  /// SDK-helper share path (e.g. `setScreenShareEnabled` on the participant)
  /// on an explicit non-null maxFrameRate double (the ee933f5 SIGABRT guard).
  @visibleForTesting
  static RoomOptions buildRoomOptions() => RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioPublishOptions: const AudioPublishOptions(
          name: "mic",
          stream: "mic_audio",
        ),
        // A mute must flip the track's flag, NOT release the microphone.
        //
        // The SDK default for stopAudioCaptureOnMute is true, and
        // setSourceEnabled consults it on EVERY toggle, so muting used to tear
        // the native capture down and unmuting used to build it back up. On a
        // phone that rebuilds the platform audio unit and moves the OS audio
        // session between a playback-only and a record-capable mode, which is
        // both the 2-3 second silence Chef heard on every toggle and the
        // reason the room was louder while muted (no echo cancellation or
        // automatic gain control in the path) than while live.
        //
        // Set as the ROOM default, not at the call site: setMicrophoneEnabled
        // falls back to `room.roomOptions.defaultAudioCaptureOptions` when no
        // options are passed, so this one value covers every mic toggle in the
        // app (Spaces, 1:1 calls, conf) rather than only the path that
        // remembered to pass it.
        //
        // The trade is that the OS "microphone in use" indicator now stays lit
        // while muted, and the output level stays at the quieter, echo-
        // cancelled one instead of jumping between the two. Nothing is
        // transmitted while muted: the publication is muted at the SDK level,
        // which is the same guarantee every other conferencing client makes
        // for the same reason.
        defaultAudioCaptureOptions: const AudioCaptureOptions(
          stopAudioCaptureOnMute: false,
        ),
        defaultScreenShareCaptureOptions:
            screenShareCaptureOptionsFor(ScreenShareFrameRate.standard),
      );

  /// Shared connect body used by [joinRoom] and [connectWithToken]: builds the
  /// [Room] with the standard publish options, wires listeners, connects, and
  /// captures the local participant. (DRY - single source of room wiring.)
  ///
  /// [identity] - our own identity/fingerprint, forwarded to the sovereign-ICE
  /// fetch as the `peer` hint so the ephemeral TURN credential is keyed to us.
  /// Optional: a null / empty identity still fetches (the endpoint falls back to
  /// the local FQID), and the whole ICE step is best-effort anyway.
  ///
  /// Room options are built by [buildRoomOptions] (factored out so the
  /// camera-path regression test can assert them without a live room).
  Future<void> _connectRoom({
    required String wsUrl,
    required String token,
    String? identity,
  }) async {
    _lastToken = token;
    _room = Room(roomOptions: buildRoomOptions());
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
        // The confirmed screen-share failure is a publish-ACK timeout
        // (TrackPublishException 'Failed to publish track'): the client sent
        // AddTrack but the SFU did not return the publish response within the
        // SDK's default 10s. A cold first-publish (publisher peerconnection
        // negotiating + ICE, possibly relayed) can exceed 10s, so give the
        // publish and the publisher peerconnection more headroom. Every other
        // field keeps its SDK default (see Timeouts.defaultTimeouts).
        timeouts: const Timeouts(
          connection: Duration(seconds: 15),
          debounce: Duration(milliseconds: 100),
          publish: Duration(seconds: 25),
          peerConnection: Duration(seconds: 15),
          iceRestart: Duration(seconds: 10),
        ),
      ),
    );
    _localParticipant = _room!.localParticipant;
    // Hold the screen awake for as long as this room is connected. Wired HERE
    // rather than in a screen, because this is the one place every room type
    // funnels through (Spaces, 1:1 calls, conf), so one hook covers all of
    // them and none of them can forget. Refcounted for the overlapping case
    // (a call answered from inside a Space); see ScreenAwake.
    await _screenAwake.acquire();
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

  /// Disconnect from the room and release every room-scoped resource, leaving
  /// this service usable for the next call.
  ///
  /// WHY this is separate from [dispose]: the service outlives a single call
  /// (see [liveKitCallServiceProvider]), so leaving a room must not close the
  /// streams the next call will publish on. `leaveRoom` used to be an alias
  /// for [dispose], which closed all five broadcast controllers, so a service
  /// that was reused after one call went permanently silent (every
  /// `_emitParticipants` / connection-state add is dropped by an isClosed
  /// guard, with nothing failing loudly).
  ///
  /// Idempotent and non-throwing by contract. Teardown runs from several
  /// independent paths (the hang-up button, the call screen being disposed,
  /// the provider being torn down, a re-join over a live room), and a second
  /// run, or a run against a room the SFU already dropped, has to be a clean
  /// no-op. An exception here would skip the rest of the teardown and strand
  /// exactly what this method exists to release: a live subscription that
  /// keeps decoding and PLAYING remote audio after the user has left.
  ///
  /// Room state is cleared BEFORE the awaits so a concurrent second call sees
  /// an already-empty service rather than racing on the same [Room].
  Future<void> leaveRoom() async {
    // Paired with the acquire in _connectRoom. Released FIRST, before any of
    // the teardown below, because every one of those steps is individually
    // wrapped in a swallowing catch: letting the screen keep itself awake past
    // the end of the room would be silent and effectively permanent.
    //
    // Only released when there was actually a room to leave: leaveRoom is
    // reachable on a path that never connected (a failed join still tears
    // down), and an unpaired release there would drop the lock out from under
    // a DIFFERENT room that is still running.
    if (_room != null) await _screenAwake.release();
    final room = _room;
    final events = _roomEvents;
    final systemAudio = _systemAudioTrack;
    _room = null;
    _localParticipant = null;
    _roomEvents = null;
    _systemAudioTrack = null;
    _lastToken = null;
    mediaWarning = null;
    _selfMuteInFlight = false;

    if (systemAudio != null) {
      try {
        await systemAudio.stop();
      } catch (_) {}
    }
    if (events != null) {
      try {
        await events.dispose();
      } catch (_) {}
    }
    if (room != null) {
      try {
        room.removeListener(_onRoomChanged);
      } catch (_) {}
      try {
        await room.disconnect();
      } catch (_) {}
      try {
        await room.dispose();
      } catch (_) {}
    }
  }

  // ── Track controls ────────────────────────────────────────────────────────

  /// Mute / unmute the local microphone.
  ///
  /// DECOUPLE: the voice mic (`TrackSource.microphone`) and content/system
  /// audio (`TrackSource.screenShareAudio`, see [startScreenShareSystemAudio])
  /// are DISTINCT wire sources now, so they are fully independent: enabling
  /// or disabling the mic never touches an active content-audio share, and
  /// starting/stopping content audio never touches the mic. There used to be
  /// a mutual exclusion here (both published as `TrackSource.microphone` and
  /// collided on `getTrackPublicationBySource`); that collision is gone now
  /// that content audio has its own source, so the exclusion was removed.
  Future<void> setMicEnabled(bool enabled) async {
    // Mark a caller-initiated disable in flight so the TrackMutedEvent
    // reconciliation in _bindRoomListeners can tell this apart from a
    // server-initiated mute (host force-mute) arriving with no local call
    // ever made, see _reconcileExternalMicMute. Cleared one microtask AFTER
    // the explicit emit below (not synchronously) so the guard outlives the
    // SDK's own ~2-hop microtask dispatch of this exact call's
    // TrackMutedEvent; see the race analysis on _selfMuteInFlight. The
    // generation token makes a stale deferred clear a no-op when a newer
    // disable has re-armed the guard in the meantime.
    final gen = ++_selfMuteGeneration;
    if (!enabled) _selfMuteInFlight = true;
    await _localParticipant?.setMicrophoneEnabled(enabled);
    if (!_micEnabledCtl.isClosed) _micEnabledCtl.add(enabled);
    scheduleMicrotask(() {
      if (gen == _selfMuteGeneration) _selfMuteInFlight = false;
    });
    _emitParticipants();
  }

  /// Enable / disable the local camera, optionally choosing the facing
  /// ([CameraPosition.front], the default selfie facing, or
  /// [CameraPosition.back]) and/or an explicit capture [deviceId] (see
  /// [resolveCameraDeviceId]). Additive: every existing bare
  /// `setCameraEnabled(true)` caller (conf_screen.dart, livekit_call_screen.dart)
  /// keeps its old behavior unchanged, since front / a null deviceId is
  /// exactly what the SDK's own `CameraCaptureOptions()` default already
  /// resolved to before these parameters existed.
  ///
  /// Camera and screen share are mutually exclusive live video sources
  /// (Spaces "Go live": camera XOR screen). Going live on camera stops an
  /// active screen share first. This XOR is purely about video sources and
  /// is independent of audio: it is unrelated to the mic / content-audio
  /// relationship, which (per DECOUPLE, see [setMicEnabled]) is NOT
  /// exclusive at all.
  Future<void> setCameraEnabled(bool enabled,
      {CameraPosition cameraPosition = CameraPosition.front,
      String? deviceId}) async {
    final lp = _localParticipant;
    if (lp == null) return;
    if (enabled) {
      await stopScreenShareForCamera();
      await lp.setCameraEnabled(
        true,
        cameraCaptureOptions: CameraCaptureOptions(
            cameraPosition: cameraPosition, deviceId: deviceId),
      );
    } else {
      // Spaces "go live" stop means the video ENDS, not "mute the camera".
      // The SDK's setCameraEnabled(false) (LocalParticipant.setSourceEnabled,
      // TrackSource.camera branch) only MUTES the camera publication, leaving
      // a frozen track on viewers and a stale publication that collides with
      // the next share, whereas the very same method UNPUBLISHES a screen
      // share (TrackSource.screenShareVideo branch, via
      // removePublishedTrack). Mirror the screen-share path here: unpublish
      // the camera track directly so viewers get a real
      // TrackUnpublished/LocalTrackUnpublished event and the publication is
      // fully gone, not just muted.
      final pub = lp.getTrackPublicationBySource(TrackSource.camera);
      if (pub != null) {
        await lp.removePublishedTrack(pub.sid);
      }
    }
    _emitParticipants();
  }

  /// Stop an active screen share so the camera can go live. Camera XOR
  /// screen: only one live video source at a time. Safe no-op when no
  /// screen share is live. Never touches the mic or the content-audio
  /// track (see [stopScreenShareSystemAudio], called separately by
  /// [setScreenShareEnabled] when a share is stopped outright).
  Future<void> stopScreenShareForCamera() async {
    if (_localParticipant?.isScreenShareEnabled() ?? false) {
      await setScreenShareEnabled(false);
    }
  }

  /// Stop an active camera so a screen share can go live. Camera XOR
  /// screen: only one live video source at a time (the mirror image of
  /// [stopScreenShareForCamera]). Safe no-op when no camera is live.
  Future<void> stopCameraForScreenShare() async {
    if (_localParticipant?.isCameraEnabled() ?? false) {
      await setCameraEnabled(false);
    }
  }

  /// Screen-share encoding tier. [standard] is the LAN-tuned default (30 fps,
  /// higher bitrate ceiling) for smooth motion content (e.g. Kodi/video
  /// playback through Spaces); [lowBandwidth] is the previous 15 fps preset,
  /// kept available for a constrained-network fallback.
  ///
  /// SOURCE FINDINGS (livekit_client 2.5.0+hotfix.3, installed at
  /// ~/.pub-cache/hosted/pub.dev/livekit_client-2.5.0+hotfix.3/lib/):
  ///
  /// - When no explicit `screenShareEncoding` is supplied, the SDK derives one
  ///   from `VideoParametersPresets.allScreenShare` by picking the FIRST
  ///   preset whose width >= the capture width (src/utils.dart
  ///   `_findAppropriateEncoding`, called from `computeVideoEncodings` around
  ///   utils.dart:396-426). For a 1920x1080 capture that preset list
  ///   (src/types/video_parameters.dart:112-118) is
  ///   `[h360FPS3, h720FPS5, h720FPS15, h1080FPS15, h1080FPS30]` - the loop
  ///   breaks at the FIRST width-1920 entry, `screenShareH1080FPS15`
  ///   (2.5 Mbps @ 15 fps, video_parameters.dart:290-296), never reaching
  ///   `screenShareH1080FPS30` (4 Mbps @ 30 fps, video_parameters.dart:298-
  ///   304) right after it. So the SDK's own un-tuned default for a 1080p
  ///   screen share silently caps at 15 fps - an explicit encoding is
  ///   required to get 30 fps, which is what [standard] supplies.
  /// - `4 * 1000 * 1000` is not an arbitrary number: it is exactly the SDK's
  ///   own `screenShareH1080FPS30` preset bitrate (video_parameters.dart:298-
  ///   304), the highest 1080p/30fps ceiling the SDK authors ship. It sits
  ///   inside the 3-6 Mbps LAN range and needs no further justification than
  ///   "use the SDK's own top preset for this resolution/framerate".
  /// - `degradationPreference` for screen-share is NOT `maintainFramerate` by
  ///   SDK default: `LocalParticipant.getDefaultDegradationPreference`
  ///   (src/participant/local.dart:547-557) returns `maintainResolution` for
  ///   ANY `TrackSource.screenShareVideo` track (or any track >=1080p) when
  ///   the caller does not set one explicitly - "drop framerate to keep
  ///   sharpness". That is backwards for motion content: Chef streams
  ///   video/Kodi through this share, so smoothness (stable framerate) matters
  ///   more than the WebRTC encoder shaving resolution under mild bandwidth
  ///   pressure. Both tiers below therefore explicitly set
  ///   `DegradationPreference.maintainFramerate`, overriding the SDK's
  ///   screen-share default.
  /// - simulcast stays OFF for both tiers. Two independent reasons from
  ///   source: (1) on web, screen-share simulcast has been unreliable enough
  ///   that the SFU can end up with no usable layer (the original "nothing
  ///   appears in the room" failure this file already worked around).
  ///   (2) Even where it negotiates, the SDK's own default LOW simulcast
  ///   layer for screen-share (src/utils.dart
  ///   `_computeDefaultScreenShareSimulcastParams`, utils.dart:228-253) is
  ///   `scaleResolutionDownBy: 2, maxFramerate: 3` - a half-resolution,
  ///   3 fps layer. That layer is useless for motion content and buys nothing
  ///   on a gigabit LAN with one viewer tier, so there is no upside to
  ///   simulcast here, only extra encoder/negotiation overhead.
  /// DECOUPLE: this used to carry a shared `PublishOptions.stream` name
  /// (`'screenshare'`) on BOTH the screen-share VIDEO publish
  /// ([screenSharePublishOptionsFor]) and the screen-share system-AUDIO
  /// publish ([screenShareAudioPublishOptions]) as a lip-sync workaround
  /// (AVSYNC-fix). That workaround only worked because BOTH tracks published
  /// as `TrackSource.microphone`/`screenShareVideo`-adjacent wire sources at
  /// the time, so `buildStreamId` (src/utils.dart:647) happened to combine
  /// them into the same literal stream id. Now that system audio publishes as
  /// its own distinct `TrackSource.screenShareAudio` (see
  /// [startScreenShareSystemAudio]), `buildStreamId` gives `screenShareVideo`
  /// and `screenShareAudio` DIFFERENT fixed suffixes, so a shared custom
  /// `stream:` name would make the two literal ids diverge instead of match.
  /// `PublishOptions.stream`'s own doc comment (`options.dart`) states the
  /// server pairs `screen_share` + `screen_share_audio` by DEFAULT when no
  /// custom stream name is given, which is exactly the pairing the SDK's own
  /// `LocalVideoTrack.createScreenShareTracksWithAudio` relies on (it passes
  /// no custom `stream:` at all). So the custom name is dropped here in favor
  /// of that server-side default pairing; verify with a real two-client
  /// lip-sync check after this change (source alone cannot confirm the SFU's
  /// grouping behavior).
  @visibleForTesting
  static VideoPublishOptions screenSharePublishOptionsFor(
    ScreenShareFrameRate tier,
  ) {
    final encoding = switch (tier) {
      // Matches the SDK's own screenShareH1080FPS30 preset (see doc above).
      ScreenShareFrameRate.standard =>
        const VideoEncoding(maxFramerate: 30, maxBitrate: 4 * 1000 * 1000),
      // Matches the SDK's own screenShareH1080FPS15 preset
      // (video_parameters.dart:290-296): 2.5 Mbps @ 15 fps.
      ScreenShareFrameRate.lowBandwidth =>
        const VideoEncoding(maxFramerate: 15, maxBitrate: 2500 * 1000),
    };
    return VideoPublishOptions(
      name: VideoPublishOptions.defaultScreenShareName,
      simulcast: false,
      screenShareEncoding: encoding,
      degradationPreference: DegradationPreference.maintainFramerate,
    );
  }

  /// The screen-share system-audio `AudioPublishOptions`, factored out so it
  /// is directly assertable in tests (see [startScreenShareSystemAudio],
  /// which publishes with exactly these options). No custom `stream:` name
  /// (see the DECOUPLE doc comment above [screenSharePublishOptionsFor]):
  /// pairing with the screen-share video now relies on the SDK/server's own
  /// default `screenShareVideo` + `screenShareAudio` grouping.
  @visibleForTesting
  static AudioPublishOptions screenShareAudioPublishOptions() {
    return const AudioPublishOptions(
      name: 'screenshare-audio',
    );
  }

  /// Capture-side options for [tier] (see [screenSharePublishOptionsFor] for
  /// the encoding side and the SDK-source rationale).
  ///
  /// The capture [VideoParameters] preset and its `maxFrameRate` are kept in
  /// step with the publish encoding for the same tier: a 30 fps publish
  /// ceiling is pointless if `getDisplayMedia` itself only ever hands the
  /// encoder 15 fps of frames, and vice versa.
  ///
  /// `maxFrameRate` MUST be an explicit non-null double: on native desktop,
  /// livekit_client's `ScreenShareCaptureOptions.toMediaConstraintsMap`
  /// (src/track/options.dart:185-200) emits `mandatory: {'frameRate':
  /// maxFrameRate}` whenever `maxFrameRate != 0.0` - and `null != 0.0` is
  /// true in Dart, so an unset (null) `maxFrameRate` still satisfies that
  /// guard and emits `{'frameRate': null}`. flutter_webrtc's native
  /// `ParseConstraints` has no branch for a null (`std::monostate`) value and
  /// falls through to `std::get<int>(v)`, throwing `std::bad_variant_access`
  /// and aborting (SIGABRT) the instant `getDisplayMedia` parses it - this is
  /// the X11 capturer crash fixed in ee933f5. Both tiers below set an
  /// explicit double so the native capturer keeps honoring the requested fps
  /// instead of crashing.
  @visibleForTesting
  static ScreenShareCaptureOptions screenShareCaptureOptionsFor(
    ScreenShareFrameRate tier, {
    String? sourceId,
    bool captureScreenAudio = false,
  }) {
    final (params, maxFrameRate) = switch (tier) {
      ScreenShareFrameRate.standard => (
          VideoParametersPresets.screenShareH1080FPS30,
          30.0,
        ),
      ScreenShareFrameRate.lowBandwidth => (
          VideoParametersPresets.screenShareH1080FPS15,
          15.0,
        ),
    };
    return ScreenShareCaptureOptions(
      sourceId: sourceId,
      captureScreenAudio: captureScreenAudio,
      params: params,
      maxFrameRate: maxFrameRate,
    );
  }

  /// Start / stop sharing the local screen, WITH audio (best-effort).
  ///
  /// Publishes (or unpublishes) a screen-share video track on the local
  /// participant. On platforms that require a capture prompt (desktop/web),
  /// the browser surfaces it; on mobile a foreground-service / broadcast-
  /// extension flow applies. Guarded for a null local participant (no-op until
  /// [joinRoom] / [connectWithToken] completes).
  ///
  /// GESTURE SAFETY (web): Chrome only allows `getDisplayMedia` inside the
  /// transient user activation of the tap. To keep that activation alive we do
  /// the capture as the FIRST `await` in this method (no `ref.read` chains, no
  /// pre-capture network calls), so the display-capture prompt fires while the
  /// gesture is still valid. Callers must likewise `await` this directly out of
  /// the tap handler with no preceding awaits.
  ///
  /// CONSTRAINT SAFETY: we do NOT force 1080p (or any exact resolution) onto
  /// the capture. Forcing capture constraints can make `getDisplayMedia` reject
  /// on some surfaces. Quality/encoding is set on the PUBLISH side via
  /// [screenSharePublishOptionsFor] instead.
  ///
  /// QUALITY: [frameRate] selects the tier built by
  /// [screenShareCaptureOptionsFor] / [screenSharePublishOptionsFor] and
  /// defaults to [ScreenShareFrameRate.standard] (1080p30, 4 Mbps, tuned for
  /// LAN streaming of motion content - see the doc comment on
  /// [screenSharePublishOptionsFor] for the SDK-source rationale).
  /// [ScreenShareFrameRate.lowBandwidth] keeps the previous 15 fps / 2.5 Mbps
  /// preset available for a constrained network.
  ///
  /// AUDIO (best-effort): when [withAudio] is true (the default) we ask the
  /// browser to also capture the shared surface's audio in the SAME
  /// `getDisplayMedia` call. Chromium reliably delivers this for a shared
  /// browser TAB. For a whole screen / desktop app (e.g. Kodi on Linux) the
  /// browser simply returns no audio track, and a failure to publish the audio
  /// never kills the video share (the audio publish is wrapped). On Linux the
  /// robust way to stream desktop audio is to pick a PulseAudio `Monitor of ...`
  /// source as the mic in the device picker.
  ///
  /// Throws on capture denial / failure (e.g. NotAllowedError when the user
  /// cancels the picker or the gesture was lost) so the caller can surface a
  /// SnackBar and revert the sharing UI state instead of failing silently.
  ///
  /// NATIVE DESKTOP: on Linux/macOS/Windows, flutter_webrtc needs an explicit
  /// capture [sourceId] from `desktopCapturer.getSources()`, or it defaults to
  /// source "0" and fails with "source not found". The browser supplies its
  /// own picker on web, so [sourceId] must stay null there. Callers on desktop
  /// resolve a source (e.g. via the SDK's `ScreenSelectDialog`) before calling
  /// this and pass its id here; web callers pass nothing.
  Future<void> setScreenShareEnabled(bool enabled,
      {bool withAudio = true,
      String? systemAudioDeviceId,
      String? sourceId,
      ScreenShareFrameRate frameRate = ScreenShareFrameRate.standard}) async {
    final lp = _localParticipant;
    if (lp == null) return;

    if (!enabled) {
      // Stop the system-audio track (if any) before tearing down the
      // screen-share publications below.
      await stopScreenShareSystemAudio();
      // The SDK helper removes BOTH the screen-share video and its paired
      // screen-share audio publication by source.
      await lp.setScreenShareEnabled(false);
      _emitParticipants();
      return;
    }

    // Camera XOR screen: only one live video source at a time (a video-only
    // exclusion, unrelated to audio: the mic / content-audio relationship is
    // NOT exclusive, see DECOUPLE on setMicEnabled). Stop an active camera
    // before starting the screen share so no participant ever publishes
    // both.
    await stopCameraForScreenShare();

    // Capture options: request screen audio in the single getDisplayMedia call.
    // The preset only supplies "ideal" web hints (never an exact/mandatory
    // constraint), so it does not cause the capture to reject. [sourceId] is
    // null on web (unchanged, browser-native picker) and set on native
    // desktop, where flutter_webrtc needs it to resolve the capture source.
    // See [screenShareCaptureOptionsFor] for why maxFrameRate must be an
    // explicit double (native-desktop SIGABRT fixed in ee933f5) and for how
    // [frameRate] maps to the capture preset / fps.
    final captureOptions = screenShareCaptureOptionsFor(
      frameRate,
      sourceId: sourceId,
      captureScreenAudio: true,
    );

    // Capture the display. This is the FIRST await, so the getDisplayMedia
    // prompt fires inside the tap's transient activation. One call returns the
    // video track (+ the surface audio track when the browser provides one).
    late final List<LocalTrack> tracks;
    if (withAudio) {
      try {
        tracks = await LocalVideoTrack.createScreenShareTracksWithAudio(
          captureOptions,
        );
      } catch (e) {
        // A genuine denial / gesture loss must bubble up so the caller can
        // show it. Only a NON-permission failure (e.g. an audio-capable
        // capture that a surface refused) falls back to a video-only capture
        // so the share still goes live without sound.
        if (_isCaptureDenied(e)) rethrow;
        final videoTrack = await LocalVideoTrack.createScreenShareTrack(
          captureOptions.copyWith(captureScreenAudio: false),
        );
        tracks = [videoTrack];
      }
    } else {
      final videoTrack = await LocalVideoTrack.createScreenShareTrack(
        captureOptions.copyWith(captureScreenAudio: false),
      );
      tracks = [videoTrack];
    }

    // Publish. Video first (this is the track viewers need); screen audio is
    // strictly best-effort and never allowed to abort the video share.
    for (final track in tracks) {
      if (track is LocalVideoTrack) {
        try {
          final publishOptions = screenSharePublishOptionsFor(frameRate);
          // Inspectable encoding choice: logged HERE, at the real share
          // publish, so it fires once per share start (not on room joins or
          // in the pure options builder).
          debugPrint(
            'screen-share publish encoding: tier=$frameRate maxFramerate='
            '${publishOptions.screenShareEncoding?.maxFramerate} maxBitrate='
            '${publishOptions.screenShareEncoding?.maxBitrate} '
            'simulcast=${publishOptions.simulcast} degradationPreference='
            '${publishOptions.degradationPreference}',
          );
          await lp.publishVideoTrack(
            track,
            publishOptions: publishOptions,
          );
        } catch (e) {
          // Boundary diagnostic: the video publish IS the user-visible share, so
          // a failure here is what surfaces as "screen share failed". The
          // confirmed failure mode is a publish-ACK timeout
          // (TrackPublishException 'Failed to publish track'). Rethrow WITH the
          // room connection state + the failing boundary so the caller's
          // SnackBar tells us whether the room was actually connected and which
          // exception type fired (a browser build has no easy console access).
          try {
            await track.stop();
          } catch (_) {}
          throw Exception(
            'screen-share publishVideoTrack failed '
            '[room=${_room?.connectionState}, err=${e.runtimeType}]: $e',
          );
        }
      } else if (track is LocalAudioTrack) {
        try {
          await lp.publishAudioTrack(track);
        } catch (_) {
          try {
            await track.stop();
          } catch (_) {}
        }
      }
    }

    // System audio (best-effort): started AFTER the video is live so a
    // failure here never aborts the video share.
    if (systemAudioDeviceId != null) {
      try {
        await startScreenShareSystemAudio(systemAudioDeviceId);
      } catch (e) {
        // Swallow: the video share stays live even if system audio fails.
      }
    }
    _emitParticipants();
  }

  /// True when [error] looks like a display-capture denial / cancellation
  /// (the user dismissed the picker, or the browser refused the capture, e.g.
  /// because the gesture was lost). Used to decide whether to bubble the error
  /// up (denial) or fall back to a video-only capture (a non-permission
  /// failure). Matches the WebRTC DOMException names case-insensitively.
  static bool _isCaptureDenied(Object error) {
    final s = error.toString().toLowerCase();
    return s.contains('notallowed') ||
        s.contains('permission') ||
        s.contains('denied') ||
        s.contains('dismiss');
  }

  // ── Data channel ──────────────────────────────────────────────────────────

  /// Publish a data message to the room (all participants unless restricted).
  ///
  /// [topic], semantic channel, e.g. 'chat', 'agent-cmd', 'reaction'.
  /// [payload], raw bytes (caller serializes; UTF-8 for JSON).
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
      ..on<TrackPublishedEvent>((event) {
        _emitParticipants();
      })
      ..on<TrackUnpublishedEvent>((event) {
        _emitParticipants();
      })
      ..on<TrackSubscribedEvent>((event) {
        _emitParticipants();
      })
      ..on<TrackUnsubscribedEvent>((event) {
        _emitParticipants();
      })
      // Local tracks: our own screen-share start / stop must re-snapshot so the
      // local stage tile appears / clears without waiting on a remote round-trip.
      ..on<LocalTrackPublishedEvent>((event) {
        _emitParticipants();
      })
      // Route through handleLocalTrackUnpublished so a screen-share video that
      // ends OUTSIDE setScreenShareEnabled(false) (OS "Stop sharing" indicator
      // on native desktop, or the captured source window closing) also tears
      // down the paired system-audio monitor track, which the SDK does not own.
      ..on<LocalTrackUnpublishedEvent>((event) {
        handleLocalTrackUnpublished(event.publication.source);
      })
      // Mute state: keep the muted / speaking dot on every tile current, and
      // reconcile a server-initiated mute of our OWN mic (host force-mute)
      // into micEnabledChanges / externalMuteEvents so the target sees it.
      ..on<TrackMutedEvent>((event) {
        _emitParticipants();
        _reconcileExternalMicMute(event);
      })
      ..on<TrackUnmutedEvent>((event) {
        _emitParticipants();
      })
      // DELIBERATELY NOT BOUND: ActiveSpeakersChangedEvent.
      //
      // The obvious change here is an explicit
      // `..on<ActiveSpeakersChangedEvent>((_) => _emitParticipants())`, and it
      // was written and then removed on measurement. Room's own constructor
      // does `events.listen((event) => notifyListeners())` for EVERY RoomEvent
      // unconditionally (installed livekit_client 2.5.0+hotfix.3,
      // src/core/room.dart:165-168), and _bindRoomListeners already registers
      // `_room!.addListener(_onRoomChanged)` above, with _onRoomChanged
      // calling _emitParticipants. So the roster ALREADY refreshes on every
      // active-speaker change; an explicit binding does not add the refresh,
      // it adds a SECOND one.
      //
      // That matters here more than anywhere else in this cascade. Active
      // speakers change continuously while people are talking, which makes it
      // the highest-frequency event in a call, and every extra emit rebuilds
      // the whole participant list plus every widget watching it. The other
      // explicit bindings below have the same redundancy but fire rarely
      // enough that it does not show; this one would.
      //
      // A test asserting "an emit happens after ActiveSpeakersChangedEvent"
      // therefore passes with NO binding at all. If you are here to add one,
      // measure the emit COUNT first.
      // Metadata: hand-raise / stage-invite changes written by the Space
      // moderation layer drive the handRaised/invitedToStage flags on the
      // snapshot, AND accepting an invite (X1) flips the participant's
      // canPublish permission in the SAME server-side update_participant
      // call that clears those metadata flags.
      //
      // X1 host-side freshness: verified against the INSTALLED
      // livekit_client 2.5.0+hotfix.3 source (not the 2.2.6 docs the recon
      // read). Participant.updateFromInfo (lib/src/participant/
      // participant.dart) calls `_setMetadata(info.metadata)` and then
      // `setPermissions(info.permission.toLKType())` synchronously, with no
      // `await` between them, so by the time this handler runs, canPublish
      // is normally already fresh: EventsEmitter's backing StreamController
      // is built with `sync: false` (lib/src/managers/event.dart), which
      // defers listener dispatch to a microtask, and setPermissions() has
      // already executed inside that same synchronous call before that
      // microtask is ever processed.
      //
      // The real gap: ParticipantPermissionsUpdatedEvent is emitted ONLY by
      // LocalParticipant.setPermissions (lib/src/participant/local.dart);
      // the base Participant.setPermissions used for a REMOTE participant
      // emits nothing. So if a permission-only change ever lands on its own
      // (the metadata value happens to be unchanged, so _setMetadata's
      // diff-check swallows the event, or the server ever splits the write
      // into two signal messages), NO event fires for that update at all,
      // and the host's roster silently holds the old canPublish until some
      // unrelated event (e.g. TrackPublishedEvent once the guest actually
      // publishes) forces a re-snapshot, matching the reported "does not
      // re-render until they publish" staleness. Re-emitting once more a
      // microtask after this handler is cheap, idempotent defense-in-depth
      // against that gap without inventing a new event or a poll loop.
      ..on<ParticipantMetadataUpdatedEvent>(
          (_) => _onParticipantMetadataChanged())
      // PERMFIX: the gap the comment above documents is not hypothetical.
      // ParticipantPermissionsUpdatedEvent is emitted ONLY by
      // LocalParticipant.setPermissions, which means it fires for the LOCAL
      // participant, exactly the promoted speaker on their own client. A
      // permission-only signal frame (no metadata change alongside it) left
      // this event completely unbound, so a promoted speaker's own snapshot
      // never refreshed canPublish and their control bar kept showing
      // "Raise hand" instead of mute/unmute until an unrelated event forced
      // a re-snapshot. Bind it to the SAME re-emit path as the metadata
      // event above (also covers the demotion direction, canPublish
      // true->false, if that too arrives as a permission-only frame).
      ..on<ParticipantPermissionsUpdatedEvent>(
          (_) => _onParticipantMetadataChanged())
      // Connection-quality changes are NOT surfaced by the plain
      // Room.addListener change signal, so re-emit the participant snapshots
      // here whenever the SFU updates a participant's link quality. This keeps
      // the per-tile signal-bars indicator live without extra polling.
      ..on<ParticipantConnectionQualityUpdatedEvent>((_) => _emitParticipants());
  }

  void _onRoomChanged() {
    _emitParticipants();
    if (!_connStateCtl.isClosed) {
      _connStateCtl.add(_room!.connectionState);
    }
  }

  void _emitParticipants() {
    final snapshot = currentParticipants;
    if (!_participantsCtl.isClosed) {
      _participantsCtl.add(snapshot);
    }
  }

  /// X1 freshness fix: re-emit the participant snapshot now AND once more
  /// after a microtask. See the doc comment on the `ParticipantMetadataUpdatedEvent`
  /// binding in [_bindRoomListeners] for the SDK-source evidence behind
  /// this. Exposed via [debugSimulateMetadataChange] so the double-emit
  /// timing itself is unit-testable without a live [Room].
  void _onParticipantMetadataChanged() {
    _emitParticipants();
    scheduleMicrotask(_emitParticipants);
  }

  /// Test-only hook: fires the exact same re-emit path a real
  /// `ParticipantMetadataUpdatedEvent` from `_bindRoomListeners` would
  /// trigger, without needing a live [Room] / LiveKit connection. See
  /// test/services/livekit_call_service_snapshot_test.dart.
  @visibleForTesting
  void debugSimulateMetadataChange() => _onParticipantMetadataChanged();

  /// PERMFIX test-only hook: fires the exact same re-emit path a real
  /// `ParticipantPermissionsUpdatedEvent` from `_bindRoomListeners` would
  /// trigger (the promoted-speaker publish grant arriving as a
  /// permission-only signal frame), without needing a live [Room] / LiveKit
  /// connection. Mirrors [debugSimulateMetadataChange]. See
  /// test/services/livekit_call_service_snapshot_test.dart.
  @visibleForTesting
  void debugSimulatePermissionsChange() => _onParticipantMetadataChanged();

  /// Reconcile a mute event against the LOCAL mic publication, surfacing a
  /// server-initiated mute (the moderation layer's host force-mute,
  /// `MuteRoomTrackRequest`) that this side never requested.
  ///
  /// Today [micEnabledChanges] only fires from inside [setMicEnabled], so a
  /// host muting a speaker's mic FROM THE SERVER never touched that path:
  /// the target's [micEnabledChanges] stayed silent, [SpaceRoomState.
  /// isMicEnabled] stayed true, and the control bar kept showing "Mute"
  /// while the track was actually muted underneath. This listens on the raw
  /// LiveKit [TrackMutedEvent] instead (fired for ANY mute of ANY
  /// participant's track, local or remote) and reacts only when it is OUR
  /// OWN microphone-source publication, so the reconciliation is scoped to
  /// exactly the target-visibility gap described above.
  ///
  /// [_selfMuteInFlight] excludes a mute WE requested (an explicit toggle),
  /// which already emits through [setMicEnabled] itself, so this only fires
  /// for the remaining "someone else did this to me" case. DECOUPLE: content
  /// audio starting or stopping never touches the mic, so it is not a
  /// caller-initiated-disable case this needs to exclude. X model: strictly
  /// one-directional, no auto-unmute is ever inferred from a
  /// TrackUnmutedEvent here, the speaker only goes live again via their own
  /// [setMicEnabled] call.
  void _reconcileExternalMicMute(TrackMutedEvent event) {
    if (_selfMuteInFlight) return;
    if (event.participant is! LocalParticipant) return;
    if (event.publication.source != TrackSource.microphone) return;
    if (!_micEnabledCtl.isClosed) _micEnabledCtl.add(false);
    if (!_externalMuteCtl.isClosed) _externalMuteCtl.add(null);
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
      canPublishVideo: LiveKitParticipantSnapshot.canPublishVideoFromSourceNames(
          p.permissions.canPublishSources.map((s) => s.name).toList()),
      handRaised: LiveKitParticipantSnapshot.parseHandRaised(p.metadata),
      invitedToStage:
          LiveKitParticipantSnapshot.parseInvitedToStage(p.metadata),
      isSpeaking: p.isSpeaking,
      audioLevel: p.audioLevel,
      connectionQuality: p.connectionQuality,
      metadata: p.metadata,
      soulFingerprint: LiveKitParticipantSnapshot.parseSoulFingerprint(p.metadata),
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
      canPublishVideo: LiveKitParticipantSnapshot.canPublishVideoFromSourceNames(
          p.permissions.canPublishSources.map((s) => s.name).toList()),
      handRaised: LiveKitParticipantSnapshot.parseHandRaised(p.metadata),
      invitedToStage:
          LiveKitParticipantSnapshot.parseInvitedToStage(p.metadata),
      isSpeaking: p.isSpeaking,
      audioLevel: p.audioLevel,
      connectionQuality: p.connectionQuality,
      metadata: p.metadata,
      soulFingerprint: LiveKitParticipantSnapshot.parseSoulFingerprint(p.metadata),
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

  /// The camera device id to publish on: the persisted [saved] choice when it
  /// is still present in [devices], otherwise the smart default (first
  /// non-virtual device, skipping droidcam/obs/v4l2loopback). Null for an empty
  /// enumeration (the caller then falls back to the SDK default device).
  static String? resolveCameraDeviceId(
      List<MediaDevice> devices, String? saved) {
    if (devices.isEmpty) return null;
    if (saved != null &&
        saved.isNotEmpty &&
        devices.any((d) => d.deviceId == saved)) {
      return saved;
    }
    return pickDefaultDeviceId(devices);
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

  /// True when at least one device can carry system audio: a PulseAudio
  /// monitor on native desktop, or a real loopback / virtual capture input on
  /// web, where the browser never exposes a monitor at all (see
  /// [SystemAudioSources.candidates]). False when the platform has neither.
  Future<bool> hasSystemAudioSource() async =>
      (await defaultSystemAudioSource()) != null;

  /// The auto-selected default system-audio source, or null when none exists.
  Future<MediaDevice?> defaultSystemAudioSource() async {
    final inputs = await Hardware.instance.enumerateDevices(type: 'audioinput');
    return SystemAudioSources.autoSelect(inputs);
  }

  bool get isSharingSystemAudio => _systemAudioTrack != null;

  /// Capture [deviceId] (a monitor source) with all voice processing off and
  /// publish it as a DISTINCT `TrackSource.screenShareAudio` track, fully
  /// independent of the voice mic (`TrackSource.microphone`, [setMicEnabled]).
  /// Best-effort: a failure here must never abort the video share, so callers
  /// wrap it. Guards when there is no room, or when a system-audio track is
  /// already being shared.
  ///
  /// DECOUPLE (re-verified against `livekit_client` 2.5.0+hotfix.3): the
  /// public `LocalAudioTrack.create()` factory (`track/local/audio.dart`)
  /// hardcodes `TrackSource.microphone` on every track it returns, and
  /// `AudioPublishOptions` has no field to override the published source;
  /// `LocalParticipant.publishAudioTrack` derives the wire-level source from
  /// `track.source` itself (`participant/local.dart`), which is `final` and
  /// set only at construction (`track.dart`). So the source can only be
  /// chosen by constructing the `LocalAudioTrack` directly. The SDK's own
  /// `LocalVideoTrack.createScreenShareTracksWithAudio`
  /// (`track/local/video.dart:259-265`) does exactly this: it builds a
  /// `LocalAudioTrack` tagged `TrackSource.screenShareAudio` via the
  /// package's `@internal` constructor (`track/local/audio.dart:117-127`),
  /// wrapping a captured `MediaStream`/`MediaStreamTrack` pair. That
  /// constructor does not care where the stream came from (`getDisplayMedia`
  /// there, our PulseAudio monitor `getUserMedia` capture here), so we reuse
  /// it: capture via the public `LocalAudioTrack.create()` factory as before
  /// (unchanged capture options / voice-processing-off), then re-wrap that
  /// track's already-public `mediaStream`/`mediaStreamTrack`/`currentOptions`
  /// in a NEW `LocalAudioTrack` built via the internal constructor tagged
  /// `TrackSource.screenShareAudio`, and publish THAT. `@internal` is an
  /// analyzer lint only (no runtime or language-level restriction), so this
  /// compiles and runs; see the `ignore:` comment at the call site. RISK:
  /// this is an internal SDK surface and can change or vanish on a
  /// livekit_client version bump with no semver signal, re-verify this
  /// constructor's signature on every SDK upgrade. Fallback if it breaks: the
  /// old mutual-exclusion behavior (publish under `TrackSource.microphone`,
  /// force-mute the real mic first), see git history / the design spec.
  Future<void> startScreenShareSystemAudio(String deviceId) async {
    final lp = _localParticipant;
    if (lp == null || _systemAudioTrack != null) return;
    final capturedMicTrack = await LocalAudioTrack.create(
      SystemAudioSources.captureOptions(deviceId),
    );
    // Re-tag the captured monitor track as TrackSource.screenShareAudio
    // instead of publishing capturedMicTrack (which is stuck at
    // TrackSource.microphone by the public factory, see the doc comment
    // above); never call capturedMicTrack.stop() or publish it, it is
    // discarded as a plain Dart wrapper object once `track` owns the same
    // underlying MediaStreamTrack.
    final track = retagAsScreenShareAudio(capturedMicTrack);
    try {
      await lp.publishAudioTrack(
        track,
        publishOptions: screenShareAudioPublishOptions(),
      );
    } catch (_) {
      await track.stop();
      rethrow;
    }
    _systemAudioTrack = track;
    _emitParticipants();
  }

  /// Re-tags [capturedTrack] (captured via the public
  /// `LocalAudioTrack.create()` factory, which hardcodes
  /// `TrackSource.microphone`) as `TrackSource.screenShareAudio`, wrapping
  /// the SAME underlying `mediaStream`/`mediaStreamTrack`/`currentOptions`,
  /// via the package's `@internal` `LocalAudioTrack` constructor. This is
  /// the exact pattern the SDK itself uses in
  /// `LocalVideoTrack.createScreenShareTracksWithAudio`
  /// (`track/local/video.dart:259-265`) to mint a `screenShareAudio` track
  /// from a captured `MediaStream`/`MediaStreamTrack` pair; that constructor
  /// does not care where the stream came from (`getDisplayMedia` there, our
  /// PulseAudio monitor `getUserMedia` capture here). `@internal` is an
  /// analyzer lint only (no runtime or language-level restriction), so this
  /// compiles and runs. Factored out of [startScreenShareSystemAudio] so the
  /// re-tagging step itself is directly unit-testable without a real
  /// capture device: a test can pass a fake `LocalAudioTrack` with stubbed
  /// `mediaStream`/`mediaStreamTrack`/`currentOptions` and assert the
  /// returned track's `source` and identity-preserved fields.
  ///
  /// RISK: this relies on an internal SDK surface that can change or vanish
  /// on a livekit_client version bump with no semver signal; re-verify this
  /// constructor's signature on every SDK upgrade. Fallback if it breaks:
  /// the old mutual-exclusion behavior (publish under
  /// `TrackSource.microphone`, force-mute the real mic first), see git
  /// history / the design spec.
  ///
  /// NOTE: this copies `mediaStream`/`mediaStreamTrack`/`currentOptions`
  /// only, NOT `processor` (a `LocalTrack` can carry a post-capture
  /// `TrackProcessor` set via `setProcessor`). Today
  /// [SystemAudioSources.captureOptions] never sets one, so
  /// `capturedTrack.processor` is always null here and this is a no-op in
  /// practice. Flagged as a latent gap: if a processor is ever attached to
  /// the system-audio capture in the future, it would need to be re-applied
  /// to the retagged track explicitly (e.g. via `setProcessor`), since this
  /// helper does not carry it across.
  @visibleForTesting
  static LocalAudioTrack retagAsScreenShareAudio(
    LocalAudioTrack capturedTrack,
  ) {
    // ignore: invalid_use_of_internal_member
    return LocalAudioTrack(
      TrackSource.screenShareAudio,
      capturedTrack.mediaStream,
      capturedTrack.mediaStreamTrack,
      capturedTrack.currentOptions,
    );
  }

  /// Test seam: inject the current system-audio monitor track so the
  /// source-closed teardown path ([handleLocalTrackUnpublished]) can be
  /// exercised without a live LiveKit room (a unit test cannot spin one up).
  @visibleForTesting
  set debugSystemAudioTrack(LocalTrack? track) => _systemAudioTrack = track;

  /// Test seam: inject a (mock) local participant so the explicit-stop
  /// ([setScreenShareEnabled] false) and mic-restore ([setMicEnabled] true)
  /// paths, which early-return / no-op without one, can be driven end to end
  /// in a unit test. No behavior change: only assignment to the same private
  /// field a room join sets.
  @visibleForTesting
  set debugLocalParticipant(LocalParticipant? lp) => _localParticipant = lp;

  /// Test seam: attach [room] as the service's live room WITHOUT wiring
  /// listeners, so a test can drive [currentParticipants] straight off a
  /// mocked Room + Participant pair (e.g. asserting a mapped field like
  /// audioLevel) without also having to satisfy every stub
  /// [_bindRoomListeners] would otherwise touch on the mock.
  @visibleForTesting
  set debugRoom(Room? room) => _room = room;

  /// Test seam: run the real [_bindRoomListeners] wiring against whatever
  /// [Room] was attached via [debugRoom]. Kept separate from [debugRoom]
  /// itself (rather than folded into one setter) so a mocked Room can be
  /// used for field-mapping assertions without also having to stub
  /// `createListener()` / `addListener()`, while a real (unconnected) `Room`
  /// can still be bound here to drive genuine livekit_client RoomEvents
  /// through the SDK's own broadcast stream and prove a SPECIFIC binding
  /// exists, rather than asserting on the always-present generic
  /// ChangeNotifier relay (Room's own constructor calls notifyListeners()
  /// on every RoomEvent with no filtering) that would pass even if the
  /// binding under test were deleted.
  @visibleForTesting
  void debugBindRoomListeners() => _bindRoomListeners();

  /// React to the local participant losing a published track.
  ///
  /// Usually this just re-snapshots. But the screen-share VIDEO track can go
  /// away WITHOUT passing through [setScreenShareEnabled] (which does its own
  /// system-audio teardown first): the OS-level "Stop sharing" indicator on
  /// native desktop, or the captured source window closing, ends the
  /// display-capture track and the SDK auto-unpublishes it (LocalParticipant's
  /// internal TrackEndedEvent listener calls removePublishedTrack, which emits
  /// [LocalTrackUnpublishedEvent]). The device-captured system-audio monitor
  /// is a SEPARATE PulseAudio capture the SDK does not own, so nothing would
  /// stop it: the Space would keep streaming monitor audio after the share
  /// visibly ended. Tie its lifecycle to the screen-share video here so EVERY
  /// stop path (explicit app button, OS indicator, source closed) tears it
  /// down. Idempotent: the explicit-stop path already cleared the monitor, so
  /// [isSharingSystemAudio] is false by the time its own video-unpublish
  /// event arrives.
  @visibleForTesting
  Future<void> handleLocalTrackUnpublished(TrackSource? source) async {
    if (source == TrackSource.screenShareVideo && isSharingSystemAudio) {
      // stopScreenShareSystemAudio() re-emits its own participant snapshot.
      await stopScreenShareSystemAudio();
      return;
    }
    _emitParticipants();
  }

  /// Unpublish and stop the system-audio track only. Safe no-op when not sharing.
  Future<void> stopScreenShareSystemAudio() async {
    final track = _systemAudioTrack;
    _systemAudioTrack = null;
    if (track == null) return;
    try {
      await _localParticipant?.removePublishedTrack(track.sid ?? '');
    } catch (_) {}
    try {
      await track.stop();
    } catch (_) {}
    _emitParticipants();
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

  /// Flip the live camera between front and back ([CameraPosition]) WITHOUT
  /// dropping the call. Mirrors [switchCameraDevice] exactly, one level up:
  /// if a camera track is already published, its capture is restarted in
  /// place on the new [position] via livekit_client's
  /// `LocalVideoTrack.setCameraPosition` extension (`restartTrack` under the
  /// hood - same track, new facing, no unpublish/republish flicker). If no
  /// camera track is live yet, the camera is published directly on the
  /// requested facing via [setCameraEnabled] (which also applies the camera
  /// / screen mutual exclusion).
  Future<void> switchCameraPosition(CameraPosition position) async {
    final lp = _localParticipant;
    if (lp == null) return;
    final track = lp.getTrackPublicationBySource(TrackSource.camera)?.track;
    if (track is LocalVideoTrack) {
      await track.setCameraPosition(position);
      _emitParticipants();
    } else {
      await setCameraEnabled(true, cameraPosition: position);
    }
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  /// Disconnect from the room and release all resources, INCLUDING the
  /// streams. Terminal: the service cannot be reused afterwards, so this is
  /// for the provider's own teardown. Everything that merely ends a call
  /// wants [leaveRoom].
  Future<void> dispose() async {
    await leaveRoom();
    if (!_participantsCtl.isClosed) await _participantsCtl.close();
    if (!_dataCtl.isClosed) await _dataCtl.close();
    if (!_connStateCtl.isClosed) await _connStateCtl.close();
    if (!_micEnabledCtl.isClosed) await _micEnabledCtl.close();
    if (!_externalMuteCtl.isClosed) await _externalMuteCtl.close();
  }
}

// ── Riverpod provider ──────────────────────────────────────────────────────

/// The single owner of this client's LiveKit room.
///
/// Override in tests or for a specific call session using
/// `ProviderScope(overrides: [liveKitCallServiceProvider.overrideWithValue(...)])`.
///
/// DELIBERATELY NOT autoDispose. Every consumer here reaches this service with
/// `ref.read` (a call screen, the call session, the Spaces/conf screens, the
/// in-call panels), and `ref.read` does not keep an autoDispose provider
/// alive: Riverpod tore the element down again at the end of the same frame,
/// so each read handed back a BRAND NEW LiveKitCallService. The instance that
/// connected the Room was therefore not the instance any later caller got, and
/// the consequences were not cosmetic:
///
///   * `hangUp()` / `leaveRoom()` on leaving a call ran against a fresh
///     service whose `_room` was null, so it was a silent no-op while the
///     orphaned instance kept its Room connected, kept its audio subscription,
///     and kept playing the far end through the speakers on whatever screen
///     the user had moved on to. That is the live defect this fixes: a call
///     the user had left was still audible on the DM screen 42 minutes later.
///   * the orphaned Room was unreachable from the UI, so nothing could ever
///     stop it short of reloading the app, and it kept burning bandwidth.
///
/// The service is still rebuilt when the backend config changes (the
/// `ref.watch` below), and the old instance is still fully disposed by the
/// `ref.onDispose` hook, which is all the autoDispose modifier was there for.
final liveKitCallServiceProvider = Provider<LiveKitCallService>((ref) {
  // Read the live backend config so the token-mint + SFU URLs follow the
  // selected federation instance. The watch rebuilds the service when the
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
