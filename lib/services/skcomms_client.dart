import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daemon_config.dart';
import 'operator_session_service.dart';

/// Any request whose path falls under this prefix is the operator-auth
/// handshake itself (`GET .../challenge`, `POST .../session`, run by
/// [OperatorSessionService] on its OWN Dio instance, not this client's).
/// The interceptor below exempts these paths so it never asks
/// [OperatorSessionService.ensureSession] to authenticate the very requests
/// that constitute the handshake, which would recurse.
const _kAuthHandshakePathMarker = '/api/v1/auth/';

/// Extra-map key the retry guard uses to mark a request that has already been
/// retried once after a 401, so a daemon that keeps returning 401 (e.g. a
/// re-auth that itself gets rejected) fails once instead of looping forever.
const _kAuthRetriedExtraKey = 'skAuthRetried';

bool _isAuthHandshakePath(String path) =>
    path.startsWith(_kAuthHandshakePathMarker);

/// Low-level HTTP client wrapping the SKComms daemon REST API.
///
/// The base URL is resolved (in priority order) from:
///   1. the [baseUrl] constructor argument (used by the provider, which
///      reads the runtime-configurable [daemonUrlProvider]);
///   2. the `SKCOMMS_URL` compile-time dart-define;
///   3. the `http://localhost:9384` fallback.
///
/// On native (daemon on the same device) the default works.  On a WEB build
/// served to a remote browser, the URL must point at a network-reachable
/// daemon (e.g. a tailnet host), set it via the profile/settings screen or
/// `--dart-define=SKCOMMS_URL=...` at build time.
class SKCommsClient {
  /// [dio] may be injected (tests) to supply a canned [HttpClientAdapter];
  /// its [BaseOptions.baseUrl] is set from [baseUrl] when provided.
  ///
  /// [sessionService] is the operator-auth handshake (Task 6). It is
  /// nullable: when not supplied (e.g. an older call site, or a test that
  /// does not care about auth), the client behaves exactly as it did before
  /// this Bearer-attaching interceptor existed, no header is attached and no
  /// 401 retry is attempted.
  SKCommsClient({String? baseUrl, Dio? dio, OperatorSessionService? sessionService})
    : _dio = dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl ?? kDefaultDaemonUrl,
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 10),
              headers: {'Content-Type': 'application/json'},
            ),
          ),
      _sessionService = sessionService {
    if (dio != null && baseUrl != null) {
      _dio.options.baseUrl = baseUrl;
    }
    _dio.interceptors.add(_buildAuthInterceptor());
  }

  final Dio _dio;
  final OperatorSessionService? _sessionService;

  /// Attaches `Authorization: Bearer <session>` to every request (best
  /// effort) and retries once on a 401 after clearing the cached session and
  /// re-running the handshake.
  ///
  /// Ship-dark contract: the skchat server gate that checks this header is
  /// OFF by default, so this interceptor must NEVER block or fail a request
  /// just because a session could not be minted (e.g. a fresh, unenrolled
  /// device). Any [OperatorSessionService.ensureSession] failure is swallowed
  /// and the request proceeds without the header.
  InterceptorsWrapper _buildAuthInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) async {
        final session = _sessionService;
        if (session == null || _isAuthHandshakePath(options.path)) {
          return handler.next(options);
        }
        try {
          final token = await session.ensureSession();
          options.headers['Authorization'] = 'Bearer $token';
        } catch (_) {
          // No session available yet (not enrolled, daemon unreachable,
          // etc). Proceed unauthenticated, the server gate is off by
          // default, so this must not block the request.
        }
        return handler.next(options);
      },
      onError: (err, handler) async {
        final session = _sessionService;
        final options = err.requestOptions;
        final alreadyRetried = options.extra[_kAuthRetriedExtraKey] == true;
        final isAuthPath = _isAuthHandshakePath(options.path);
        if (session == null ||
            err.response?.statusCode != 401 ||
            alreadyRetried ||
            isAuthPath) {
          return handler.next(err);
        }

        session.clearSession();
        try {
          final freshToken = await session.ensureSession();
          final retryOptions = options.copyWith(
            headers: {
              ...options.headers,
              'Authorization': 'Bearer $freshToken',
            },
            extra: {
              ...options.extra,
              _kAuthRetriedExtraKey: true,
            },
          );
          final retryResponse = await _dio.fetch(retryOptions);
          return handler.resolve(retryResponse);
        } catch (_) {
          // Re-auth itself failed (or the retried request failed again);
          // surface the ORIGINAL error rather than a re-auth exception.
          return handler.next(err);
        }
      },
    );
  }

  // ── Health ────────────────────────────────────────────────────────────────

  /// GET /health, verify the daemon is running.
  ///
  /// Uses /health (a clean 200) not /, the webui root 307-redirects to /app/,
  /// which made the health check flaky and showed a false "SKComms offline".
  Future<bool> isAlive() async {
    try {
      final resp = await _dio.get('/health');
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 400;
    } catch (_) {
      return false;
    }
  }

  /// GET /api/v1/status, full transport health report.
  ///
  /// Returns a normalized `Map<String, dynamic>` and NEVER throws on a benign
  /// shape mismatch: Dio's JSON decode can hand back a `Map<dynamic, dynamic>`
  /// (or a non-map on some proxies), and a hard `as Map<String, dynamic>` cast
  /// on that throws, which previously bubbled up to `_checkDaemon` and flipped
  /// the UI to a FALSE "daemon offline" even though `/health` + `/api/v1/status`
  /// were both 200. We accept any 2xx body and coerce it; a non-map 200 yields
  /// an empty map (still "online"), not an exception.
  Future<Map<String, dynamic>> getStatus() async {
    final resp = await _dio.get('/api/v1/status');
    final data = resp.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  // ── Messaging ─────────────────────────────────────────────────────────────

  /// POST /api/v1/send, send a message to a peer.
  ///
  /// [recipient] is the peer's fqid / name / fingerprint (e.g.
  /// `lumina@chef.skworld`). [message] is the plaintext content.
  ///
  /// The live contract returns `{ok, reply:{full message}, message:{full
  /// message}}`, the echoed user turn AND the agent's reply, both already
  /// persisted server-side. We surface BOTH (parsed) so the caller can render
  /// the reply bubble immediately, without waiting for the next history poll.
  /// We also tolerate the OLDER daemon shape (`{delivered, envelope_id,
  /// transport_used}`) so a mixed fleet keeps working.
  ///
  /// Both `peer_id` and `recipient` are sent (the contract reads `peer_id`;
  /// `recipient` is kept for the legacy daemon).
  Future<SendResult> sendMessage({
    required String recipient,
    required String message,
    String? threadId,
    String? inReplyTo,
    String? contentType,
    Map<String, dynamic>? rich,
  }) async {
    final body = <String, dynamic>{
      // Contract key first, legacy key second (both harmless / additive).
      'peer_id': recipient,
      'recipient': recipient,
      'content': message,
      'message': message,
      'thread_id': threadId,
      // Contract field name is `reply_to_id`; keep `in_reply_to` for the older
      // daemon build that read that key (additive, both harmless).
      'reply_to_id': inReplyTo,
      'in_reply_to': inReplyTo,
      'content_type': ?contentType,
      'rich': ?rich,
    };
    final resp = await _dio.post('/api/v1/send', data: body);
    final data = resp.data is Map
        ? Map<String, dynamic>.from(resp.data as Map)
        : <String, dynamic>{};
    final code = resp.statusCode ?? 0;
    final ok = (data['ok'] as bool?) ?? (code >= 200 && code < 300);
    final echoed = data['message'];
    final reply = data['reply'];
    return SendResult(
      // `delivered` is true for a 2xx contract response (`ok`) OR the legacy
      // `delivered` flag.
      delivered: (data['delivered'] as bool?) ?? ok,
      envelopeId: data['envelope_id'] as String? ??
          (echoed is Map ? echoed['id'] as String? : null) ??
          '',
      transportUsed: data['transport_used'] as String?,
      echoedMessage:
          echoed is Map ? Map<String, dynamic>.from(echoed) : null,
      reply: reply is Map ? Map<String, dynamic>.from(reply) : null,
    );
  }

  /// GET /api/v1/inbox, poll for new incoming messages.
  Future<List<InboxMessage>> getInbox() async {
    final resp = await _dio.get('/api/v1/inbox');
    final list = resp.data as List<dynamic>;
    return list
        .map((e) => InboxMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/v1/conversations, list known conversations.
  Future<List<Map<String, dynamic>>> getConversations() async {
    final resp = await _dio.get('/api/v1/conversations');
    return (resp.data as List<dynamic>)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  // ── Peers ─────────────────────────────────────────────────────────────────

  /// GET /api/v1/peers, list all known peers.
  Future<List<PeerInfo>> getPeers() async {
    final resp = await _dio.get('/api/v1/peers');
    final list = resp.data as List<dynamic>;
    return list
        .map((e) => PeerInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Agents ────────────────────────────────────────────────────────────────

  /// GET /api/v1/agents, list known agents.
  Future<List<Map<String, dynamic>>> getAgents() async {
    final resp = await _dio.get('/api/v1/agents');
    return (resp.data as List<dynamic>)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  // ── Groups ──────────────────────────────────────────────────────────────

  /// GET /api/v1/groups/:groupId/members, list members of a group.
  Future<List<Map<String, dynamic>>> getGroupMembers(String groupId) async {
    final resp = await _dio.get('/api/v1/groups/$groupId/members');
    return (resp.data as List<dynamic>)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  /// POST /api/v1/groups, create a new group chat.
  ///
  /// [name] is required. [description] and [memberUris] are optional.
  /// Returns a [CreateGroupResult] with the group ID and AES-256-GCM key info.
  Future<CreateGroupResult> createGroup({
    required String name,
    String? description,
    List<String> memberUris = const [],
  }) async {
    final body = <String, dynamic>{'name': name};
    if (description != null && description.isNotEmpty) {
      body['description'] = description;
    }
    if (memberUris.isNotEmpty) {
      body['members'] =
          memberUris.map((u) => <String, dynamic>{'identity': u}).toList();
    }
    final resp = await _dio.post('/api/v1/groups', data: body);
    return CreateGroupResult.fromJson(resp.data as Map<String, dynamic>);
  }

  /// POST /api/v1/groups/:groupId/members, add a member.
  Future<void> addGroupMember(
    String groupId, {
    required String identity,
    String role = 'member',
  }) async {
    await _dio.post(
      '/api/v1/groups/$groupId/members',
      data: {'identity': identity, 'role': role},
    );
  }

  /// DELETE /api/v1/groups/:groupId/members/:identity, remove a member.
  Future<void> removeGroupMember(String groupId, String identity) async {
    await _dio.delete('/api/v1/groups/$groupId/members/$identity');
  }

  /// PUT /api/v1/groups/:groupId, update group name or description.
  Future<void> updateGroupInfo(
    String groupId, {
    String? name,
    String? description,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (description != null) body['description'] = description;
    await _dio.put('/api/v1/groups/$groupId', data: body);
  }

  /// DELETE /api/v1/groups/:groupId/members/self, leave a group.
  Future<void> leaveGroup(String groupId) async {
    await _dio.delete('/api/v1/groups/$groupId/members/self');
  }

  /// DELETE /api/v1/groups/:groupId, delete a whole group (admin-only).
  ///
  /// The server gates this to an admin (the creator); a non-admin caller gets
  /// a 403. Throws on any non-2xx so the caller can surface "not allowed".
  Future<void> deleteGroup(String groupId) async {
    await _dio.delete('/api/v1/groups/$groupId');
  }

  // ── Presence ──────────────────────────────────────────────────────────────

  /// POST /api/v1/presence, broadcast presence status.
  Future<void> updatePresence({
    required String status,
    String? message,
  }) async {
    await _dio.post('/api/v1/presence', data: {
      'status': status,
      'message': message,
    });
  }

  // ── Identity ──────────────────────────────────────────────────────────────

  /// GET /api/v1/identity, return this node's PGP fingerprint and name.
  Future<IdentityInfo> getIdentity() async {
    final resp = await _dio.get<Map<String, dynamic>>('/api/v1/identity');
    return IdentityInfo.fromJson(resp.data ?? {});
  }

  // ── WebRTC ────────────────────────────────────────────────────────────────

  /// GET /api/v1/webrtc/ice-config, ICE server list with TURN credentials.
  ///
  /// Returns the list ready to pass to RTCPeerConnection config['iceServers'].
  /// Falls back to Google STUN when the daemon is unreachable.
  Future<List<Map<String, dynamic>>> getIceConfig() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/api/v1/webrtc/ice-config',
      );
      final data = resp.data ?? {};
      final servers = data['ice_servers'] as List<dynamic>? ?? [];
      return servers
          .whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
    } catch (_) {
      return [
        {'urls': 'stun:stun.l.google.com:19302'},
      ];
    }
  }

  /// GET /api/v1/webrtc/peers, list peers in a signaling room.
  Future<Map<String, dynamic>> getWebRTCPeers({String? room}) async {
    final resp = await _dio.get<Map<String, dynamic>>(
      '/api/v1/webrtc/peers',
      queryParameters: room != null ? {'room': room} : null,
    );
    return resp.data ?? {};
  }

  // ── Signing ───────────────────────────────────────────────────────────────

  /// POST /api/v1/sign, ask the daemon to sign [nonce] with the local PGP key.
  ///
  /// The private key never leaves the daemon; the app only receives the
  /// armored PGP signature.
  Future<String> signNonce(String nonce) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '/api/v1/sign',
      data: {'nonce': nonce},
    );
    return (resp.data ?? {})['signature'] as String? ?? '';
  }
  // ── Typed-message contract (react / edit / receipt / thread / conversation) ─

  /// POST /api/v1/react -- toggle an emoji reaction on a message.
  ///
  /// [op] is 'add' or 'remove'. Same-origin via the webui. Returns true on a
  /// 2xx; callers treat reactions optimistically and tolerate failure.
  Future<bool> react({
    required String conversationId,
    required String messageId,
    required String emoji,
    String op = 'add',
  }) async {
    try {
      final resp = await _dio.post('/api/v1/react', data: {
        'conversation_id': conversationId,
        'message_id': messageId,
        'emoji': emoji,
        'op': op,
      });
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 300;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/edit -- edit a message body (server enforces the 24h window).
  Future<bool> edit({
    required String messageId,
    required String body,
  }) async {
    try {
      final resp = await _dio.post('/api/v1/edit', data: {
        'message_id': messageId,
        'body': body,
      });
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 300;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/receipt -- mark a message delivered/read.
  ///
  /// [kind] is 'delivered' or 'read'.
  Future<bool> receipt({
    required String conversationId,
    required String messageId,
    required String kind,
  }) async {
    try {
      final resp = await _dio.post('/api/v1/receipt', data: {
        'conversation_id': conversationId,
        'message_id': messageId,
        'kind': kind,
      });
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 300;
    } catch (_) {
      return false;
    }
  }

  /// GET /api/v1/thread/{id} -- fetch all messages in a thread.
  ///
  /// Returns raw maps (the caller builds [ChatMessage]s with the right
  /// directionality). Empty list on error.
  Future<List<Map<String, dynamic>>> getThread(String threadId) async {
    try {
      final resp = await _dio.get<dynamic>(
        '/api/v1/thread/${Uri.encodeComponent(threadId)}',
      );
      final data = resp.data;
      final list = data is Map ? (data['messages'] as List?) : (data as List?);
      return (list ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// GET /api/v1/conversations/{id} -- full typed-contract conversation
  /// (messages with reactions/receipts/edits). Empty list on error.
  Future<List<Map<String, dynamic>>> getConversationFull(
    String conversationId,
  ) async {
    try {
      final resp = await _dio.get<dynamic>(
        '/api/v1/conversations/${Uri.encodeComponent(conversationId)}',
      );
      final data = resp.data;
      final list = data is Map ? (data['messages'] as List?) : (data as List?);
      return (list ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // ── File Transfers ────────────────────────────────────────────────────────

  /// GET /api/v1/file_status?transfer_id={id}, poll file transfer progress.
  ///
  /// Returns a [FileTransferStatus] or throws on HTTP error.
  Future<FileTransferStatus> getFileStatus(String transferId) async {
    final resp = await _dio.get<Map<String, dynamic>>(
      '/api/v1/file_status',
      queryParameters: {'transfer_id': transferId},
    );
    return FileTransferStatus.fromJson(resp.data ?? {});
  }

  /// POST /upload, upload a file as multipart to [recipient].
  ///
  /// The daemon stores the file, starts the transfer, and returns
  /// `{id, transfer_id, filename}`.  Pass the raw [bytes] plus a [filename]
  /// (web has no file paths, so we always upload from bytes).  [caption] is an
  /// optional human note delivered alongside the file.
  ///
  /// Returns an [UploadResult]; throws on HTTP error.
  Future<UploadResult> uploadFile({
    required String recipient,
    required List<int> bytes,
    required String filename,
    String caption = '',
  }) async {
    final form = FormData.fromMap({
      'recipient': recipient,
      'caption': caption,
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final resp = await _dio.post<Map<String, dynamic>>(
      '/upload',
      data: form,
      // Multipart sets its own Content-Type (with boundary); override the
      // client-wide application/json default for this request.
      options: Options(contentType: 'multipart/form-data'),
    );
    return UploadResult.fromJson(resp.data ?? {});
  }

  /// Absolute URL for downloading a completed transfer's file payload.
  ///
  /// `GET /file/{transferId}`, used as an `<img>`/download src.  Built from
  /// the client's configured [baseUrl] so it honours the runtime daemon URL.
  String fileUrl(String transferId) =>
      '${_baseUrl()}/file/${Uri.encodeComponent(transferId)}';

  /// Absolute URL for a transfer's thumbnail preview.
  ///
  /// `GET /file/{transferId}/thumb`.
  String thumbUrl(String transferId) =>
      '${_baseUrl()}/file/${Uri.encodeComponent(transferId)}/thumb';

  /// The client's base URL with any trailing slash stripped, so the helpers
  /// above can append `/file/...` paths cleanly.
  String _baseUrl() {
    var b = _dio.options.baseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }
}

// ── Data transfer objects ──────────────────────────────────────────────────

class SendResult {
  const SendResult({
    required this.delivered,
    required this.envelopeId,
    this.transportUsed,
    this.echoedMessage,
    this.reply,
  });

  final bool delivered;
  final String envelopeId;
  final String? transportUsed;

  /// The server-persisted user turn from the contract `message` field (full
  /// message map: `{id,sender,body,ts,...}`). Null on the legacy daemon.
  final Map<String, dynamic>? echoedMessage;

  /// The agent's reply from the contract `reply` field (full message map).
  /// Null when the daemon did not return a synchronous reply.
  final Map<String, dynamic>? reply;
}

class InboxMessage {
  const InboxMessage({
    required this.envelopeId,
    required this.sender,
    required this.recipient,
    required this.content,
    required this.createdAt,
    this.threadId,
    this.inReplyTo,
    this.isEncrypted = true,
  });

  final String envelopeId;
  final String sender;
  final String recipient;
  final String content;
  final DateTime createdAt;
  final String? threadId;
  final String? inReplyTo;
  final bool isEncrypted;

  factory InboxMessage.fromJson(Map<String, dynamic> json) {
    return InboxMessage(
      envelopeId: json['envelope_id'] as String? ?? '',
      sender: json['sender'] as String? ?? '',
      recipient: json['recipient'] as String? ?? '',
      content: json['content'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      threadId: json['thread_id'] as String?,
      inReplyTo: json['in_reply_to'] as String?,
      isEncrypted: json['encrypted'] as bool? ?? true,
    );
  }
}

class PeerInfo {
  const PeerInfo({
    required this.name,
    this.fingerprint,
    this.lastSeen,
    this.transports = const [],
  });

  final String name;
  final String? fingerprint;
  final DateTime? lastSeen;
  final List<String> transports;

  factory PeerInfo.fromJson(Map<String, dynamic> json) {
    final transports = <String>[];
    if (json['transports'] is List) {
      for (final t in json['transports'] as List) {
        if (t is Map) transports.add(t['transport'] as String? ?? '');
      }
    }
    return PeerInfo(
      name: json['name'] as String? ?? '',
      fingerprint: json['fingerprint'] as String?,
      lastSeen: json['last_seen'] != null
          ? DateTime.tryParse(json['last_seen'] as String)
          : null,
      transports: transports,
    );
  }
}

class CreateGroupResult {
  const CreateGroupResult({
    required this.groupId,
    required this.name,
    this.description,
    this.memberCount = 0,
    this.keyId,
    this.keyAlgorithm = 'AES-256-GCM',
    this.members = const [],
  });

  final String groupId;
  final String name;
  final String? description;
  final int memberCount;
  /// Short identifier of the group encryption key.
  final String? keyId;
  final String keyAlgorithm;
  final List<String> members;

  factory CreateGroupResult.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'] as List<dynamic>? ?? [];
    return CreateGroupResult(
      groupId: json['group_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      memberCount: json['member_count'] as int? ?? 0,
      keyId: json['key_id'] as String?,
      keyAlgorithm: json['key_algorithm'] as String? ?? 'AES-256-GCM',
      members: rawMembers
          .map((e) =>
              (e is Map ? e['identity'] as String? : e as String?) ?? '')
          .where((s) => s.isNotEmpty)
          .toList(),
    );
  }
}

/// Result of a successful `POST /upload`, the daemon's handle for the file.
///
/// `transferId` is what the file-transfer bubble polls and what
/// [SKCommsClient.fileUrl] / [SKCommsClient.thumbUrl] reference.
class UploadResult {
  const UploadResult({
    required this.id,
    required this.transferId,
    required this.filename,
  });

  final String id;
  final String transferId;
  final String filename;

  factory UploadResult.fromJson(Map<String, dynamic> json) {
    return UploadResult(
      id: json['id'] as String? ?? '',
      transferId: json['transfer_id'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
    );
  }
}

class IdentityInfo {
  const IdentityInfo({
    required this.fingerprint,
    this.name,
    this.email,
  });

  final String fingerprint;
  final String? name;
  final String? email;

  factory IdentityInfo.fromJson(Map<String, dynamic> json) {
    return IdentityInfo(
      fingerprint: json['fingerprint'] as String? ?? '',
      name: json['name'] as String?,
      email: json['email'] as String?,
    );
  }
}

// ── Riverpod provider ──────────────────────────────────────────────────────

/// SKCommsClient bound to the runtime-configurable daemon URL.
///
/// Watching [daemonUrlProvider] means changing the daemon URL in the settings
/// screen rebuilds this client so all subsequent calls hit the new host.
final skcommsClientProvider = Provider<SKCommsClient>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  final sessionService = ref.watch(operatorSessionServiceProvider);
  return SKCommsClient(baseUrl: baseUrl, sessionService: sessionService);
});


// ── File Transfer ──────────────────────────────────────────────────────────

/// Status snapshot for an in-flight or completed file transfer.
///
/// Returned by GET /api/v1/file_status?transfer_id={id}.
/// The widget polls every 2 s and stops once [isTerminal] is true.
class FileTransferStatus {
  const FileTransferStatus({
    required this.transferId,
    required this.status,
    required this.fileName,
    required this.fileSize,
    required this.bytesTransferred,
    this.speedBps = 0,
    this.errorMessage,
  });

  final String transferId;

  /// Raw status string from the daemon:
  ///   'pending' | 'in_progress' | 'completed' | 'failed'
  final String status;

  /// Display name of the file being transferred.
  final String fileName;

  /// Total file size in bytes (may be 0 if unknown).
  final int fileSize;

  /// Number of bytes transferred so far.
  final int bytesTransferred;

  /// Current transfer speed in bytes per second (0 when not transferring).
  final int speedBps;

  /// Set when [isFailed] is true.
  final String? errorMessage;

  // ── Derived helpers ──────────────────────────────────────────────────────

  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isTerminal => isCompleted || isFailed;

  /// Transfer progress in [0.0, 1.0]. Returns 1.0 when completed.
  double get progress {
    if (isCompleted) return 1.0;
    if (fileSize <= 0) return 0.0;
    return (bytesTransferred / fileSize).clamp(0.0, 1.0);
  }

  /// Human-readable transfer speed, e.g. "1.4 MB/s".
  String get speedLabel {
    if (speedBps <= 0) return '';
    if (speedBps < 1024) return '$speedBps B/s';
    if (speedBps < 1024 * 1024) {
      return '${(speedBps / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(speedBps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  factory FileTransferStatus.fromJson(Map<String, dynamic> json) {
    return FileTransferStatus(
      transferId: json['transfer_id'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      fileName: json['file_name'] as String? ?? '',
      fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
      bytesTransferred: (json['bytes_transferred'] as num?)?.toInt() ?? 0,
      speedBps: (json['speed_bps'] as num?)?.toInt() ?? 0,
      errorMessage: json['error_message'] as String?,
    );
  }
}
