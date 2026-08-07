import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'guest_identity.dart';
import 'operator_token.dart' as op_token;
import 'pq_dm_codec.dart';

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

  // Phase 2 (SKCHAT_PQ_INVITES_ENABLED): PQ-seal the guest's outgoing messages
  // to the operator's bc-verified hybrid prekey. The guest holds no hybrid key
  // of its own (pqdm encapsulates an ephemeral inside each seal), so this is the
  // send direction only; the operator opens with its hybrid private key.
  final PqDmCodec _pqCodec = PqDmCodec();
  // token -> plaintext for THIS guest's own sealed sends, so `conversation()`
  // can render our own ciphertext (we sealed to the operator, we cannot open it)
  // as the original text when history echoes it back.
  final Map<String, String> _ownEcho = {};
  String? _opSignedPrekeyHex; // operator 1216-byte hybrid prekey, hex
  String? _opBc; // bundle commitment b64u(sha256(canonical{identity,prekey}))
  String? _opIdentityKey; // operator full identity pubkey (commitment input)

  GuestIdentity get identity => _identity;
  String get baseUrl => _base;

  /// Phase 2: stash the operator's PQ sealing material from the invite preview.
  /// `send()` PQ-seals only when all three are present AND the bc commitment
  /// verifies; otherwise it sends cleartext (backward-compatible, flag off).
  void configureSealing({String? signedPrekey, String? bc, String? identityKey}) {
    _opSignedPrekeyHex = (signedPrekey ?? '').isEmpty ? null : signedPrekey;
    _opBc = (bc ?? '').isEmpty ? null : bc;
    _opIdentityKey = (identityKey ?? '').isEmpty ? null : identityKey;
  }

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
    String? jti,
    String? bc,
  }) async {
    final kp = await _identity.ensure();
    final data = <String, dynamic>{
      'invite_token': inviteToken,
      'display_name': displayName,
      'guest_pubkey': kp.publicKeyB64,
    };
    // Phase 1 (SKCHAT_PQ_INVITES_ENABLED): bind this freshly-generated guest key
    // to THIS invite by signing the canonical {bc, guest_pubkey, jti}. Keys are
    // inserted alphabetically so jsonEncode reproduces the server's `_canonical`
    // (sort_keys + compact separators) byte-for-byte. A stolen link replayed by
    // a party who lacks this key -> server 401. When the operator hasn't enabled
    // signed invites, jti/bc are absent and no guest_sig is sent (not required).
    if (jti != null && jti.isNotEmpty && bc != null && bc.isNotEmpty) {
      final canonical = jsonEncode({
        'bc': bc,
        'guest_pubkey': kp.publicKeyB64,
        'jti': jti,
      });
      data['guest_sig'] = await _identity.sign(canonical);
    }
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest/join',
      data: data,
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
    // Phase 2: our own sends were sealed to the operator (we cannot open them),
    // so render them from the local token->plaintext echo when history returns
    // our ciphertext. The message text arrives under 'body' (what the bubble
    // renders) or 'content'; replace whichever holds our own sealed token.
    // Operator->guest messages are handled by the reverse leg.
    for (final m in msgs) {
      for (final key in const ['body', 'content']) {
        final c = m[key];
        if (c is String && _ownEcho.containsKey(c)) {
          m[key] = _ownEcho[c];
        }
      }
    }
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
    // Phase 2: PQ-seal to the operator BEFORE signing/sending, so the advisory
    // signature covers the exact wire bytes and the stored content is the pqdm1
    // ciphertext (not plaintext). No-op when sealing is not configured.
    final wireBody = await _sealForOperator(body);
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final canonical = _canonicalSignPayload(groupId, wireBody, ts);
    final sig = await _identity.sign(canonical);
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest/send',
      data: {
        'body': wireBody,
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

  /// guest-dm C2/S5: change this guest's OWN display name. Returns the server
  /// response, which includes the REMINTED `session_token` (the caller MUST swap
  /// its stored token for this one, or the rename silently reverts on the next
  /// request) and the server-enforced `display_name`.
  Future<Map<String, dynamic>> rename({
    required String sessionToken,
    required String name,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest/name',
      data: {'display_name': name},
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

  /// Phase 2: PQ-seal [body] to the operator's bc-verified hybrid prekey and
  /// return the `pqdm1:` wire token (remembering token -> plaintext so we can
  /// render our own send). Returns [body] unchanged when sealing is not
  /// configured (operator has no signed invite, or the flag is off). Fail-closed:
  /// a prekey that does not match the invite commitment ABORTS the send rather
  /// than falling back to cleartext to a possibly-swapped prekey (H3).
  Future<String> _sealForOperator(String body) async {
    final spk = _opSignedPrekeyHex;
    final bc = _opBc;
    final idk = _opIdentityKey;
    if (spk == null || bc == null || idk == null) return body;
    if (PqDmCodec.isHybridToken(body)) return body; // already a token (re-send)
    if (!await _commitmentOk(idk, spk, bc)) {
      throw StateError(
        'operator prekey failed the invite bundle commitment (bc); '
        'refusing to send to an unverified prekey',
      );
    }
    final token = await _pqCodec.sealToken(
      Uint8List.fromList(utf8.encode(body)),
      _hexToBytes(spk),
    );
    _ownEcho[token] = body;
    return token;
  }

  /// H3 anti-downgrade check: `b64u(sha256(canonical{identity_key,
  /// signed_prekey})) == bc`. The canonical matches the server's
  /// `pq_invites._canonical` (sort_keys + compact separators); keys inserted
  /// alphabetically so `jsonEncode` reproduces it byte-for-byte.
  Future<bool> _commitmentOk(
      String identityKey, String signedPrekey, String bc) async {
    final canonical = jsonEncode({
      'identity_key': identityKey,
      'signed_prekey': signedPrekey,
    });
    final digest = await Sha256().hash(utf8.encode(canonical));
    final got = base64Url.encode(digest.bytes).replaceAll('=', '');
    return got == bc;
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
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
    // Default to the app-stored operator token so minting also works over the
    // public Funnel once SKCHAT_GUEST_OPERATOR_TOKEN is set server-side.
    final tok = (operatorToken != null && operatorToken.isNotEmpty)
        ? operatorToken
        : op_token.operatorToken();
    if (tok != null && tok.isNotEmpty) {
      headers['X-Operator-Token'] = tok;
    }
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/groups/$groupId/invite',
      data: {if (ttl != null) 'ttl': ttl, 'single_use': singleUse},
      options: Options(headers: headers),
    );
    return r.data ?? const {};
  }

  /// Mint an Invite-to-DM link (guest-dm C1): a NEW 2-seat DM guest group with
  /// the operator in seat 1, so the guest lands directly in a 1:1 with the
  /// operator (no group). Posts to `/api/v1/groups/dm/invite?mode=dm`; the path
  /// group id is unused for `mode=dm` (see guest_group_routes.operator_create_invite),
  /// so a literal `dm` placeholder is sent.
  ///
  /// [singleUse] (default true, per the locked decision) mints a one-shot link;
  /// pass false for the operator's standing, reusable my-DM-link (server marks it
  /// `reusable`, never single-use, with a `dm_reuse` claim). [alias] pre-sets the
  /// operator's private nickname for whoever joins (only the operator sees it).
  /// [contactTtl] sets the contact-expiry TTL (seconds). Returns `{token,
  /// join_url, ...}`; [joinUrl] is relative - prefix with [fullLink].
  ///
  /// [groupId] defaults to `dm` (a fresh 2-seat DM). Pass an EXISTING guest-DM
  /// group id to add another guest to it (guest-dm G5): the server (G1) flips
  /// that group to `gdm` in place and admits the new guest as a per-person
  /// member. Same request shape either way (per-person alias, contact TTL).
  Future<Map<String, dynamic>> createDmInvite({
    String groupId = 'dm',
    bool singleUse = true,
    int? ttl,
    String? alias,
    int? contactTtl,
    String? operatorToken,
  }) async {
    final headers = <String, dynamic>{'Content-Type': 'application/json'};
    final tok = (operatorToken != null && operatorToken.isNotEmpty)
        ? operatorToken
        : op_token.operatorToken();
    if (tok != null && tok.isNotEmpty) {
      headers['X-Operator-Token'] = tok;
    }
    final data = <String, dynamic>{
      if (ttl != null) 'ttl': ttl,
      'single_use': singleUse,
      // A non-single-use DM link is the operator's standing my-DM-link.
      if (!singleUse) 'reusable': true,
      if (alias != null && alias.trim().isNotEmpty) 'alias': alias.trim(),
      if (contactTtl != null) 'contact_ttl': contactTtl,
    };
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/groups/$groupId/invite',
      queryParameters: const {'mode': 'dm'},
      data: data,
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
