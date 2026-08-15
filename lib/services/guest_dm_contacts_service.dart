import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'diag/diag_error_sink.dart';
import 'diag/diag_interceptor.dart';
import 'operator_auth_interceptor.dart';
import 'operator_session_service.dart';
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
/// the S4 `/api/v1/guest-dm/contacts` API.
///
/// **These routes need the operator SESSION, not just the pasted token.** They
/// are capability-mapped server-side, so with `SKCHAT_DATAPLANE_AUTH=1` the
/// data-plane gate runs first and only accepts `Authorization: Bearer <session>`
/// or `X-CapAuth-Token`. It does NOT recognise `X-Operator-Token`, so a request
/// carrying only the pasted token is rejected with 401 "capauth authentication
/// required" BEFORE the route's own operator check ever runs, and every one of
/// these calls (list, update, revoke, group expiry) fails identically.
///
/// So this attaches the session via [buildOperatorAuthInterceptor], the same way
/// [DeviceListService] does. The pasted `X-Operator-Token` is still sent
/// alongside it: it is what authorizes the gate-exempt routes, and it keeps
/// this working if the data-plane gate is off.
class GuestDmContactsService {
  GuestDmContactsService({
    Dio? dio,
    String? webuiBaseUrl,
    OperatorSessionService? sessionService,
  })  : _dio = dio ?? Dio(),
        _base = _strip(webuiBaseUrl ?? kDefaultSkchatWebuiUrl) {
    _dio.interceptors.add(buildOperatorAuthInterceptor(sessionService, () => _dio));
    // Network breadcrumbs (card 0a5b8e07): immediately after the auth
    // interceptor, same placement everywhere else in this file family.
    _dio.interceptors.add(buildDiagInterceptor(emitDiagEvent));
  }

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

  /// Revoke a contact: the guest loses access everywhere and the link dies.
  Future<void> revoke(String fp) async {
    await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest-dm/contacts/$fp/revoke',
      data: const {},
      options: _opts(),
    );
  }

  /// Revoke a contact's seat in ONE group only (guest-dm G7). Same route as
  /// [revoke] but with a `group_id` body, which the server (guest_group_
  /// routes.py `guest_dm_contact_revoke`) treats as a per-group revoke: this
  /// person's other conversations with us are untouched.
  Future<void> revokeGroupMembership(String fp, String groupId) async {
    await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/guest-dm/contacts/$fp/revoke',
      data: {'group_id': groupId},
      options: _opts(),
    );
  }

  /// Set the WHOLE-ROOM expiry on a dm-family group: after [groupTtl] seconds
  /// every guest of this room is locked out with reason `group_expired`.
  ///
  /// Distinct from [updateContact]'s `contactTtl`, which expires ONE person
  /// everywhere. This expires ONE room for everyone, touches nobody's contact
  /// row, and deletes nothing (the operator keeps their own history).
  ///
  /// Returns the absolute epoch-seconds expiry the server stored, so the caller
  /// can render the new state without a refetch.
  Future<double?> setGroupExpiry(String groupId, {required int groupTtl}) async {
    final r = await _dio.patch<Map<String, dynamic>>(
      '$_base/api/v1/guest-dm/groups/$groupId',
      data: {'group_ttl': groupTtl},
      options: _opts(),
    );
    return (r.data?['expires_at'] as num?)?.toDouble();
  }

  /// Clear a room's whole-group expiry so it stops expiring.
  ///
  /// Unlike the per-contact case (whose route has no clear, so the sheet writes
  /// a far-future TTL), the group route takes an explicit `expires_at: null`
  /// and REMOVES the field, so "no expiry" here really means unset.
  Future<void> clearGroupExpiry(String groupId) async {
    await _dio.patch<Map<String, dynamic>>(
      '$_base/api/v1/guest-dm/groups/$groupId',
      data: const {'expires_at': null},
      options: _opts(),
    );
  }
}

final guestDmContactsServiceProvider = Provider<GuestDmContactsService>(
  (ref) => GuestDmContactsService(
    webuiBaseUrl: _webOriginOrNull(),
    sessionService: ref.read(operatorSessionServiceProvider),
  ),
);
