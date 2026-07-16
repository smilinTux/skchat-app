import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'guest_group_service.dart' show guestGroupServiceProvider;

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

  Future<List<ModeCPending>> pending() async {
    final r = await _dio.get<Map<String, dynamic>>('$_base/api/v1/mode-c/pending');
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
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    return r.data ?? const {};
  }

  /// The durably-admitted peers (TOFU pin store), newest first, non-revoked.
  Future<List<Map<String, dynamic>>> admitted() async {
    final r = await _dio.get<Map<String, dynamic>>('$_base/api/v1/mode-c/admitted');
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
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
  }
}

final modeCServiceProvider = Provider<ModeCService>(
  (ref) => ModeCService(baseUrl: ref.watch(guestGroupServiceProvider).baseUrl),
);
