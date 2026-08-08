import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
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

/// One row of the operator "Linked Devices" list, mirroring the payload from
/// `GET /api/v1/operator/devices` (`skchat/device_routes.py:list_devices`,
/// sourced from `device_registry.list_devices()`).
///
/// [enrolledAt] and [lastSeen] are epoch seconds (the registry stores
/// `time.time()` floats, not ISO strings). [isCurrent] is computed
/// server-side from the caller's own operator session, so it reflects "the
/// device making THIS request", not any client-local guess.
class LinkedDevice {
  const LinkedDevice({
    required this.deviceFp,
    required this.label,
    required this.labelSource,
    required this.platform,
    required this.enrolledAt,
    required this.lastSeen,
    this.keyIds = const [],
    this.isCurrent = false,
  });

  final String deviceFp;
  final String label;
  final String labelSource;
  final String platform;
  final double enrolledAt;
  final double lastSeen;
  final List<String> keyIds;
  final bool isCurrent;

  factory LinkedDevice.fromJson(Map<String, dynamic> j) => LinkedDevice(
        deviceFp: j['device_fp'] as String? ?? '',
        label: j['label'] as String? ?? '',
        labelSource: j['label_source'] as String? ?? '',
        platform: j['platform'] as String? ?? '',
        enrolledAt: (j['enrolled_at'] as num?)?.toDouble() ?? 0,
        lastSeen: (j['last_seen'] as num?)?.toDouble() ?? 0,
        keyIds: ((j['key_ids'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        isCurrent: j['is_current'] as bool? ?? false,
      );
}

/// Per-step outcome of unlinking one device (`skchat/device_unlink.py:
/// unlink_device`'s return dict), surfaced by both the single-device DELETE
/// and, per fingerprint, by unlink-others.
///
/// [isDegraded] mirrors the server's own "degraded" test in
/// `device_routes.py:unlink_others`: a report is degraded when some prekey
/// slot could not be removed, the registry had no slots to work from, or a
/// capauth record failed to revoke. A degraded unlink is not a failure, the
/// device IS unlinked, but the UI should say so rather than claim a clean
/// success.
class DeviceUnlinkReport {
  const DeviceUnlinkReport({
    required this.deviceFp,
    required this.sessionsRevoked,
    required this.slotsRemoved,
    required this.slotsFailed,
    required this.registryHadNoSlots,
    required this.storeRemoved,
    required this.capauthRevoked,
    required this.capauthRecordsFailed,
    required this.registryMarked,
  });

  final String deviceFp;
  final bool sessionsRevoked;
  final List<String> slotsRemoved;
  final List<String> slotsFailed;
  final bool registryHadNoSlots;
  final bool storeRemoved;
  final bool capauthRevoked;
  final int capauthRecordsFailed;
  final bool registryMarked;

  bool get isDegraded =>
      slotsFailed.isNotEmpty || registryHadNoSlots || capauthRecordsFailed > 0;

  factory DeviceUnlinkReport.fromJson(Map<String, dynamic> j) =>
      DeviceUnlinkReport(
        deviceFp: j['device_fp'] as String? ?? '',
        sessionsRevoked: j['sessions_revoked'] as bool? ?? false,
        slotsRemoved: ((j['slots_removed'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        slotsFailed: ((j['slots_failed'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        registryHadNoSlots: j['registry_had_no_slots'] as bool? ?? false,
        storeRemoved: j['store_removed'] as bool? ?? false,
        capauthRevoked: j['capauth_revoked'] as bool? ?? false,
        capauthRecordsFailed:
            (j['capauth_records_failed'] as num?)?.toInt() ?? 0,
        registryMarked: j['registry_marked'] as bool? ?? false,
      );
}

/// Result of `POST /api/v1/operator/devices/unlink-others`
/// (`device_routes.py:unlink_others`).
///
/// [skipped] holds fingerprints that vanished between the listing pass and
/// the unlink attempt (a KeyError on the server); [degraded] is the subset of
/// [unlinked] whose [DeviceUnlinkReport.isDegraded] came back true. Both are
/// disjoint from a clean success and the UI should render them, not swallow
/// them into a bare count.
class UnlinkOthersResult {
  const UnlinkOthersResult({
    required this.unlinked,
    required this.reports,
    required this.skipped,
    required this.degraded,
  });

  final List<String> unlinked;
  final Map<String, DeviceUnlinkReport> reports;
  final List<String> skipped;
  final List<String> degraded;

  factory UnlinkOthersResult.fromJson(Map<String, dynamic> j) {
    final rawReports = (j['reports'] as Map?) ?? const {};
    return UnlinkOthersResult(
      unlinked:
          ((j['unlinked'] as List?) ?? const []).whereType<String>().toList(),
      reports: rawReports.map(
        (k, v) => MapEntry(
          k as String,
          DeviceUnlinkReport.fromJson((v as Map).cast<String, dynamic>()),
        ),
      ),
      skipped:
          ((j['skipped'] as List?) ?? const []).whereType<String>().toList(),
      degraded:
          ((j['degraded'] as List?) ?? const []).whereType<String>().toList(),
    );
  }
}

/// Why an unlink call failed, distinguished so the UI can show the right
/// message instead of a generic "something went wrong".
///
/// The server (`device_routes.py`) never returns a machine-readable error
/// code, only an HTTP status plus a human-readable `detail` string, so
/// [selfUnlink] vs [noOperatorSession] are told apart by matching stable
/// substrings of that detail text. If the server's wording ever changes in a
/// way that breaks the match, the failure still surfaces correctly as
/// [unknown] with the original message intact, it just loses the specific
/// branch.
enum DeviceUnlinkFailureReason {
  /// 400: the target fingerprint is the device making the call.
  selfUnlink,

  /// 400: the caller has no resolvable operator session, so the server
  /// cannot tell whether the target is the caller's own device.
  noOperatorSession,

  /// 404: no device with that fingerprint exists.
  notFound,

  /// Any other non-2xx response, or a transport-level failure.
  unknown,
}

/// Thrown by [DeviceListService.unlink] / [DeviceListService.unlinkOthers] on
/// a non-2xx response, carrying a typed [reason] so the caller can branch
/// (e.g. disable the button vs. show "sign in again") instead of catching a
/// raw [DioException].
class DeviceUnlinkException implements Exception {
  const DeviceUnlinkException(this.reason, this.message, {this.statusCode});

  final DeviceUnlinkFailureReason reason;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'DeviceUnlinkException($reason, $statusCode): $message';
}

DeviceUnlinkException _mapUnlinkError(DioException e) {
  final status = e.response?.statusCode;
  final data = e.response?.data;
  final detail = (data is Map && data['detail'] is String)
      ? data['detail'] as String
      : (e.message ?? 'device unlink request failed');
  if (status == 404) {
    return DeviceUnlinkException(
      DeviceUnlinkFailureReason.notFound,
      detail,
      statusCode: status,
    );
  }
  if (status == 400) {
    // Check "operator session" FIRST: the no-session detail also mentions
    // "unlinking the device you are using" as part of explaining WHY a
    // session is needed, so a "you are using" match alone cannot tell the
    // two apart. "cannot unlink the device you are using" (the self-unlink
    // detail's own opening clause) is unique to that case.
    if (detail.contains('operator session')) {
      return DeviceUnlinkException(
        DeviceUnlinkFailureReason.noOperatorSession,
        detail,
        statusCode: status,
      );
    }
    if (detail.contains('cannot unlink the device you are using')) {
      return DeviceUnlinkException(
        DeviceUnlinkFailureReason.selfUnlink,
        detail,
        statusCode: status,
      );
    }
  }
  return DeviceUnlinkException(
    DeviceUnlinkFailureReason.unknown,
    detail,
    statusCode: status,
  );
}

/// Operator controls for the "Linked Devices" surface, driven by
/// `/api/v1/operator/devices*` on the skchat web-UI.
///
/// **These routes need the operator SESSION, not just the pasted token.** They
/// are capability-mapped server-side, so with `SKCHAT_DATAPLANE_AUTH=1` the
/// data-plane gate runs first and only accepts `Authorization: Bearer <session>`
/// or `X-CapAuth-Token`. It does NOT recognise `X-Operator-Token`, so a request
/// carrying only the pasted token is rejected with 401 "capauth authentication
/// required" BEFORE the route's own operator check ever runs, and the whole
/// screen fails to load.
///
/// So this attaches the session via [buildOperatorAuthInterceptor], the same way
/// [SkcommsClient] and [SkcapstoneClient] do. The pasted `X-Operator-Token` is
/// still sent alongside it: it is what authorizes the gate-exempt enrollment
/// routes, and it keeps this working if the data-plane gate is off.
///
/// The unlink routes additionally REQUIRE a session on the server side, since a
/// caller with no device identity cannot be told apart from the device it would
/// be unlinking, so the self-lockout guard could not fire.
class DeviceListService {
  DeviceListService({Dio? dio, String? webuiBaseUrl, OperatorSessionService? sessionService})
      : _dio = dio ?? Dio(),
        _base = _strip(webuiBaseUrl ?? kDefaultSkchatWebuiUrl) {
    _dio.interceptors.add(buildOperatorAuthInterceptor(sessionService, () => _dio));
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

  /// List every device linked to this operator identity, newest enrollment
  /// first (the server already sorts). The response envelope wraps the rows
  /// under `devices`, it is not a bare array.
  Future<List<LinkedDevice>> list() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/api/v1/operator/devices',
      options: _opts(),
    );
    final rows = (r.data?['devices'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((m) => LinkedDevice.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Unlink one device by fingerprint.
  ///
  /// Throws [DeviceUnlinkException] on a non-2xx response: 400 when
  /// [deviceFp] is the device making the call or the caller has no operator
  /// session, 404 when the fingerprint is unknown.
  Future<DeviceUnlinkReport> unlink(String deviceFp) async {
    try {
      final r = await _dio.delete<Map<String, dynamic>>(
        '$_base/api/v1/operator/devices/$deviceFp',
        options: _opts(),
      );
      return DeviceUnlinkReport.fromJson(r.data ?? const {});
    } on DioException catch (e) {
      throw _mapUnlinkError(e);
    }
  }

  /// Unlink every OTHER device, sparing the one making this call.
  ///
  /// Throws [DeviceUnlinkException] on a non-2xx response: 400 when the
  /// caller has no operator session (unlink-others cannot tell which device
  /// to spare without one).
  Future<UnlinkOthersResult> unlinkOthers() async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '$_base/api/v1/operator/devices/unlink-others',
        data: const {},
        options: _opts(),
      );
      return UnlinkOthersResult.fromJson(r.data ?? const {});
    } on DioException catch (e) {
      throw _mapUnlinkError(e);
    }
  }
}

final deviceListServiceProvider = Provider<DeviceListService>(
  (ref) => DeviceListService(
    webuiBaseUrl: _webOriginOrNull(),
    sessionService: ref.read(operatorSessionServiceProvider),
  ),
);
