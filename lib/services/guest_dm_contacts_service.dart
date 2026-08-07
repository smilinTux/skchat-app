import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'operator_token.dart' as op_token;

String? _webOriginOrNull() {
  if (!kIsWeb) return null;
  try {
    final o = Uri.base.origin;
    return (o.isNotEmpty && o != 'null') ? o : null;
  } catch (_) {
    return null;
  }
}

/// One operator-side guest-DM contact (S4 `dm_contacts` row). The [alias] is
/// operator-only metadata; the guest never sees it and no `/guest/*` route
/// returns it.
class GuestContact {
  const GuestContact({
    required this.fp,
    required this.guestName,
    this.alias,
    this.groupId = '',
    this.status = 'active',
    this.muted = false,
    this.contactExpiresAt,
  });

  final String fp;
  final String guestName;
  final String? alias;
  final String groupId;
  final String status; // active | revoked | expired
  final bool muted;
  final double? contactExpiresAt; // epoch seconds

  bool get isRevoked => status == 'revoked';
  bool get isExpired => status == 'expired';
  bool get isActive => !isRevoked && !isExpired;

  /// Alias-wins title (matches the Conversation.guestTitle anti-spoofing rule).
  String get title {
    final a = alias?.trim();
    if (a != null && a.isNotEmpty) return a;
    final n = guestName.trim();
    return 'guest: ${n.isEmpty ? 'guest' : n}';
  }

  factory GuestContact.fromJson(Map<String, dynamic> j) => GuestContact(
        fp: j['fp'] as String? ?? '',
        guestName: j['guest_name'] as String? ?? '',
        alias: j['alias'] as String?,
        groupId: j['group_id'] as String? ?? '',
        status: j['status'] as String? ?? 'active',
        muted: j['muted'] as bool? ?? false,
        contactExpiresAt: (j['contact_expires_at'] as num?)?.toDouble(),
      );

  GuestContact copyWith({
    String? alias,
    String? status,
    bool? muted,
    double? contactExpiresAt,
    bool clearExpiry = false,
  }) =>
      GuestContact(
        fp: fp,
        guestName: guestName,
        alias: alias ?? this.alias,
        groupId: groupId,
        status: status ?? this.status,
        muted: muted ?? this.muted,
        contactExpiresAt:
            clearExpiry ? null : (contactExpiresAt ?? this.contactExpiresAt),
      );
}

/// Operator controls for individual guest-DM contacts (guest-dm C4), driven by
/// the S4 `/api/v1/guest-dm/contacts` API. Operator-gated server-side
/// (tailnet/loopback or the app-stored operator token). Mirrors
/// [GuestInviteService]'s Dio + `X-Operator-Token` handling.
class GuestDmContactsService {
  GuestDmContactsService({Dio? dio, String? webuiBaseUrl})
      : _dio = dio ?? Dio(),
        _base = _strip(webuiBaseUrl ?? kDefaultSkchatWebuiUrl);

  final Dio _dio;
  final String _base;

  static String _strip(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  Options _opts() {
    final headers = <String, dynamic>{'Content-Type': 'application/json'};
    final tok = op_token.operatorToken();
    if (tok != null && tok.isNotEmpty) headers['X-Operator-Token'] = tok;
    return Options(headers: headers);
  }

  /// List every guest-DM contact (operator-only).
  Future<List<GuestContact>> listContacts() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/api/v1/guest-dm/contacts',
      options: _opts(),
    );
    final rows = (r.data?['contacts'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((m) => GuestContact.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Partial-update a contact: [alias] (empty string clears it), [contactTtl]
  /// (seconds from now), and/or [muted]. Only the given fields are sent.
  Future<void> updateContact(
    String fp, {
    String? alias,
    int? contactTtl,
    bool? muted,
  }) async {
    final data = <String, dynamic>{
      if (alias != null) 'alias': alias,
      if (contactTtl != null) 'contact_ttl': contactTtl,
      if (muted != null) 'muted': muted,
    };
    await _dio.patch<Map<String, dynamic>>(
      '$_base/api/v1/guest-dm/contacts/$fp',
      data: data,
      options: _opts(),
    );
  }

  /// Revoke a contact: the guest loses access and the link dies.
  Future<void> revoke(String fp) async {
    await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest-dm/contacts/$fp/revoke',
      data: const {},
      options: _opts(),
    );
  }
}

final guestDmContactsServiceProvider = Provider<GuestDmContactsService>(
    (ref) => GuestDmContactsService(webuiBaseUrl: _webOriginOrNull()));
