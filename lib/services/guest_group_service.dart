import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'guest_identity.dart';

/// On web, use the actual served ORIGIN (correct host AND port, e.g. the
/// tailscale `:9443`) so guest/invite calls are same-origin and work over the
/// tunnel, not the compile-time default which omits the port. Null on native
/// (falls back to the configured default).
String? _webOriginOrNull() {
  if (!kIsWeb) return null;
  try {
    final o = Uri.base.origin;
    return (o.isNotEmpty && o != 'null') ? o : null;
  } catch (_) {
    return null;
  }
}

/// Result of a successful guest join: the session token + the LiveKit call
/// bootstrap + initial messages. Everything is scoped to ONE group server-side.
class GuestJoinResult {
  const GuestJoinResult({
    required this.sessionToken,
    required this.guestId,
    required this.displayName,
    required this.groupId,
    required this.groupName,
    required this.trust,
    required this.callAvailable,
    this.callRoom,
    this.callToken,
    this.callUrl,
    this.messages = const [],
  });

  final String sessionToken;
  final String guestId;
  final String displayName;
  final String groupId;
  final String groupName;
  final String trust; // "untrusted"
  final bool callAvailable;
  final String? callRoom;
  final String? callToken;
  final String? callUrl;
  final List<Map<String, dynamic>> messages;

  factory GuestJoinResult.fromJson(Map<String, dynamic> j) {
    final group = (j['group'] as Map?)?.cast<String, dynamic>() ?? const {};
    final call = (j['call'] as Map?)?.cast<String, dynamic>() ?? const {};
    final msgs = (j['messages'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    return GuestJoinResult(
      sessionToken: j['session_token'] as String? ?? '',
      guestId: j['guest_id'] as String? ?? '',
      displayName: j['display_name'] as String? ?? 'Guest',
      groupId: group['id'] as String? ?? '',
      groupName: group['name'] as String? ?? '',
      trust: j['trust'] as String? ?? 'untrusted',
      callAvailable: call['available'] == true,
      callRoom: call['room'] as String?,
      callToken: call['token'] as String?,
      callUrl: call['lk_url'] as String?,
      messages: msgs,
    );
  }
}

/// Drives the guest-group HTTP surface (`/api/v1/guest/*` + the operator
/// invite mint). Every in-room call carries the guest session token as a bearer
/// header; the server pins it to the bound group, so this service can never
/// reach another conversation.
class GuestGroupService {
  GuestGroupService({Dio? dio, String? webuiBaseUrl, GuestIdentity? identity})
      : _dio = dio ?? Dio(),
        _base = _strip(webuiBaseUrl ?? kDefaultSkchatWebuiUrl),
        _identity = identity ?? createGuestIdentity();

  final Dio _dio;
  final String _base;
  final GuestIdentity _identity;

  GuestIdentity get identity => _identity;
  String get baseUrl => _base;

  static String _strip(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// Preview an invite (group name) without consuming a single-use token.
  Future<Map<String, dynamic>> previewInvite(String token) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/api/v1/guest/invite/$token',
    );
    return r.data ?? const {};
  }

  /// Join the group: ensure a local keypair, then exchange the invite token for
  /// a guest session + call token. The browser's public key is sent so the
  /// server derives the stable `guest:<name>#<fp>` identity.
  Future<GuestJoinResult> join({
    required String inviteToken,
    required String displayName,
  }) async {
    final kp = await _identity.ensure();
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest/join',
      data: {
        'invite_token': inviteToken,
        'display_name': displayName,
        'guest_pubkey': kp.publicKeyB64,
      },
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    return GuestJoinResult.fromJson(r.data ?? const {});
  }

  /// Fetch the bound group's conversation (token-scoped, no group id needed).
  Future<List<Map<String, dynamic>>> conversation(String sessionToken) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/api/v1/guest/conversation',
      options: _bearer(sessionToken),
    );
    final msgs = (r.data?['messages'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    return msgs;
  }

  /// Send a SIGNED text message into the bound group. The signature is over the
  /// canonical `{body, group_id, ts}` JSON (server-recorded as advisory).
  Future<Map<String, dynamic>> send({
    required String sessionToken,
    required String groupId,
    required String body,
    String? replyToId,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final canonical = _canonicalSignPayload(groupId, body, ts);
    final sig = await _identity.sign(canonical);
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest/send',
      data: {
        'body': body,
        'ts': ts,
        'signature': sig,
        if (replyToId != null) 'reply_to_id': replyToId,
      },
      options: _bearer(sessionToken),
    );
    return (r.data?['message'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Add/remove a reaction on a message in the bound group.
  Future<void> react({
    required String sessionToken,
    required String messageId,
    required String emoji,
    bool add = true,
  }) async {
    await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest/react',
      data: {'message_id': messageId, 'emoji': emoji, 'op': add ? 'add' : 'remove'},
      options: _bearer(sessionToken),
    );
  }

  /// Upload a file into the bound group (multipart).
  Future<Map<String, dynamic>> uploadFile({
    required String sessionToken,
    required String filename,
    required List<int> bytes,
    String caption = '',
    String? contentType,
  }) async {
    final form = FormData.fromMap({
      'caption': caption,
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest/file',
      data: form,
      options: _bearer(sessionToken),
    );
    return r.data ?? const {};
  }

  /// Absolute download URL for a transfer (the server gates it to the group).
  String fileUrl(String transferId) => '$_base/api/v1/guest/file/$transferId';

  /// (Re)mint a fresh LiveKit call token for the bound group's room.
  Future<Map<String, dynamic>> callToken(String sessionToken) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest/call',
      data: {},
      options: _bearer(sessionToken),
    );
    return r.data ?? const {};
  }

  Options _bearer(String token) => Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

  /// MUST match guest_groups.canonical_sign_payload on the server (alphabetical
  /// keys, compact separators, ts stringified).
  static String _canonicalSignPayload(String groupId, String body, int ts) =>
      jsonEncode({'body': body, 'group_id': groupId, 'ts': '$ts'});
}

final guestGroupServiceProvider = Provider<GuestGroupService>(
    (ref) => GuestGroupService(webuiBaseUrl: _webOriginOrNull()));

// ── Operator-side invite minting (used from group_info_screen) ───────────────

/// Mint a shareable guest invite link for [groupId]. Operator-gated server-side
/// (tailnet/loopback or SKCHAT_GUEST_OPERATOR_TOKEN). Returns the relative
/// join_url + token. Requires SKCHAT_GUEST_LINKS_ENABLED on the server (404
/// when off, surfaced to the caller as an error).
class GuestInviteService {
  GuestInviteService({Dio? dio, String? webuiBaseUrl})
      : _dio = dio ?? Dio(),
        _base = GuestGroupService._strip(webuiBaseUrl ?? kDefaultSkchatWebuiUrl);

  final Dio _dio;
  final String _base;

  String get baseUrl => _base;

  /// Returns `{token, join_url, ...}`. [joinUrl] is relative, the caller
  /// prefixes [baseUrl] (or the live origin on web) to build the full link.
  Future<Map<String, dynamic>> createInvite({
    required String groupId,
    int? ttl,
    bool singleUse = false,
    String? operatorToken,
  }) async {
    final headers = <String, dynamic>{'Content-Type': 'application/json'};
    if (operatorToken != null && operatorToken.isNotEmpty) {
      headers['X-Operator-Token'] = operatorToken;
    }
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/groups/$groupId/invite',
      data: {if (ttl != null) 'ttl': ttl, 'single_use': singleUse},
      options: Options(headers: headers),
    );
    return r.data ?? const {};
  }

  /// Build the full shareable URL from a relative join_url, prefixing [baseUrl].
  String fullLink(String joinUrl) {
    if (joinUrl.startsWith('http')) return joinUrl;
    final path = joinUrl.startsWith('/') ? joinUrl : '/$joinUrl';
    return '$_base$path';
  }
}

final guestInviteServiceProvider = Provider<GuestInviteService>(
    (ref) => GuestInviteService(webuiBaseUrl: _webOriginOrNull()));
