import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'guest_group_service.dart' show guestGroupServiceProvider;
import 'operator_token.dart';

/// A pending Mode C accept assertion awaiting the operator's counter-signature.
class ModeCPending {
  const ModeCPending({
    required this.jti,
    required this.groupId,
    required this.peerFp,
    required this.sas,
  });

  final String jti;
  final String groupId;

  /// The peer's bundle fingerprint (identity to compare against the SAS).
  final String peerFp;

  /// 6-digit Short Authentication String, compared out-of-band with the peer to
  /// catch a MITM key swap before admitting them.
  final String sas;

  factory ModeCPending.fromJson(Map<String, dynamic> j) => ModeCPending(
        jti: (j['jti'] as String?) ?? '',
        groupId: (j['group_id'] as String?) ?? '',
        peerFp: (j['peer_fp'] as String?) ?? '',
        sas: (j['sas'] as String?) ?? '',
      );
}

/// Operator-side Mode C review: list pending accept assertions and counter-sign
/// them into a mutual join record. Operator-gated server-side (tailnet/loopback
/// or SKCHAT_GUEST_OPERATOR_TOKEN), so this only works from the operator origin.
class ModeCService {
  ModeCService({required String baseUrl, Dio? dio})
      : _dio = dio ?? Dio(),
        _base = baseUrl;

  final Dio _dio;
  final String _base;

  /// Request options with the operator token header when one is configured, so
  /// the operator UI also works over the public Funnel (not just the tailnet).
  /// No token => no header => tailnet/loopback gating applies as before.
  Options _opts({bool json = false}) {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    final tok = operatorToken();
    if (tok != null) headers['X-Operator-Token'] = tok;
    return Options(headers: headers);
  }

  Future<List<ModeCPending>> pending() async {
    final r = await _dio.get<Map<String, dynamic>>('$_base/api/v1/mode-c/pending',
        options: _opts());
    return ((r.data?['pending'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => ModeCPending.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Counter-sign the pending accept for [jti]. Returns the mutual join record on
  /// success. Throws (Dio) on a non-2xx (e.g. 404 if it was already handled).
  Future<Map<String, dynamic>> counterSign(String jti) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/mode-c/counter-sign',
      data: {'jti': jti},
      options: _opts(json: true),
    );
    return r.data ?? const {};
  }

  /// The durably-admitted peers (TOFU pin store), newest first, non-revoked.
  Future<List<Map<String, dynamic>>> admitted() async {
    final r = await _dio.get<Map<String, dynamic>>('$_base/api/v1/mode-c/admitted',
        options: _opts());
    return ((r.data?['admitted'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  /// Revoke an admitted peer's trust pin (H5). It drops out of [admitted].
  Future<void> revoke(String peerFp) async {
    await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/mode-c/revoke',
      data: {'peer_fp': peerFp},
      options: _opts(json: true),
    );
  }

  /// The opt-in-trusted peer-operators (Mode B): agents under them auto-admit.
  Future<List<Map<String, dynamic>>> trustedOperators() async {
    final r = await _dio.get<Map<String, dynamic>>(
        '$_base/api/v1/mode-c/trusted-operators',
        options: _opts());
    return ((r.data?['trusted_operators'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  /// EXPLICITLY trust a peer-operator by FQID + its PGP identity pubkey (Mode B).
  Future<void> trustOperator(String operatorId, String operatorPubkey) async {
    await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/mode-c/trust-operator',
      data: {'operator_id': operatorId, 'operator_pubkey': operatorPubkey},
      options: _opts(json: true),
    );
  }

  /// Revoke trust in a peer-operator (H5). Its agents stop inheriting.
  Future<void> untrustOperator(String operatorId) async {
    await _dio.post<Map<String, dynamic>>(
      '$_base/api/v1/mode-c/untrust-operator',
      data: {'operator_id': operatorId},
      options: _opts(json: true),
    );
  }
}

final modeCServiceProvider = Provider<ModeCService>(
  (ref) => ModeCService(baseUrl: ref.watch(guestGroupServiceProvider).baseUrl),
);
