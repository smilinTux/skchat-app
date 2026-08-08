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
///
/// [approved] (Phase 3, approval-to-link) is explicit on every row the server
/// sends now, both from `GET .../devices` and `GET .../devices/pending`
/// (`device_routes.py`), so it defaults `true` here only for a body a test
/// hand-writes without the field, never as a guess about a real payload.
/// A device with `approved: false` cannot mint a session at all: it enrolled
/// with the shared operator token but nobody has vouched for it yet.
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
    this.approved = true,
  });

  final String deviceFp;
  final String label;
  final String labelSource;
  final String platform;
  final double enrolledAt;
  final double lastSeen;
  final List<String> keyIds;
  final bool isCurrent;
  final bool approved;

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
        approved: j['approved'] as bool? ?? true,
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

/// Why an approve call failed, distinguished so the UI can show the right
/// message instead of a generic "something went wrong".
///
/// There is no self-approve case: approving is never rejected for matching
/// the caller's own fingerprint, only for missing the session that lets the
/// server identify a vouching device at all (`device_routes.py:approve`).
enum DeviceApprovalFailureReason {
  /// 400: the caller has no resolvable operator session, so the server
  /// cannot tell that an already-approved device is doing the vouching.
  noOperatorSession,

  /// 404: no device with that fingerprint is enrolled at all.
  notFound,

  /// Any other non-2xx response, or a transport-level failure.
  unknown,
}

/// Thrown by [DeviceListService.approve] on a non-2xx response, carrying a
/// typed [reason] so the caller can branch instead of catching a raw
/// [DioException].
class DeviceApprovalException implements Exception {
  const DeviceApprovalException(this.reason, this.message, {this.statusCode});

  final DeviceApprovalFailureReason reason;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'DeviceApprovalException($reason, $statusCode): $message';
}

/// Why a deny call failed, distinguished so the UI can show the right
/// message instead of a generic "something went wrong".
///
/// Deny is a full unlink (`device_routes.py:deny` delegates to the same
/// `unlink_device` as the single-device DELETE), so it carries the same
/// self-lockout shape as [DeviceUnlinkFailureReason]: no session, and no
/// denying the device making the call.
enum DeviceDenyFailureReason {
  /// 400: the caller has no resolvable operator session.
  noOperatorSession,

  /// 400: the target fingerprint is the device making the call.
  selfDeny,

  /// 404: no device with that fingerprint exists.
  notFound,

  /// Any other non-2xx response, or a transport-level failure.
  unknown,
}

/// Thrown by [DeviceListService.deny] on a non-2xx response, carrying a
/// typed [reason] so the caller can branch instead of catching a raw
/// [DioException].
class DeviceDenyException implements Exception {
  const DeviceDenyException(this.reason, this.message, {this.statusCode});

  final DeviceDenyFailureReason reason;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'DeviceDenyException($reason, $statusCode): $message';
}

/// Why a rename call failed, distinguished so the UI can show the right
/// message instead of a generic "something went wrong".
///
/// `device_routes.py:rename` never returns a machine-readable error code
/// either, so these are told apart purely by HTTP status: 400 covers every
/// shape of invalid label (empty, whitespace-only, missing, or non-string),
/// 404 an unknown fingerprint.
enum DeviceRenameFailureReason {
  /// 400: the label was empty, whitespace-only, missing, or not a string.
  invalidLabel,

  /// 404: no device with that fingerprint exists.
  notFound,

  /// Any other non-2xx response, or a transport-level failure.
  unknown,
}

/// Thrown by [DeviceListService.rename] on a non-2xx response, carrying a
/// typed [reason] so the caller can branch instead of catching a raw
/// [DioException].
class DeviceRenameException implements Exception {
  const DeviceRenameException(this.reason, this.message, {this.statusCode});

  final DeviceRenameFailureReason reason;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'DeviceRenameException($reason, $statusCode): $message';
}

DeviceRenameException _mapRenameError(DioException e) {
  final status = e.response?.statusCode;
  final data = e.response?.data;
  final detail = (data is Map && data['detail'] is String)
      ? data['detail'] as String
      : (e.message ?? 'device rename request failed');
  if (status == 404) {
    return DeviceRenameException(
      DeviceRenameFailureReason.notFound,
      detail,
      statusCode: status,
    );
  }
  if (status == 400) {
    return DeviceRenameException(
      DeviceRenameFailureReason.invalidLabel,
      detail,
      statusCode: status,
    );
  }
  return DeviceRenameException(
    DeviceRenameFailureReason.unknown,
    detail,
    statusCode: status,
  );
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

DeviceApprovalException _mapApprovalError(DioException e) {
  final status = e.response?.statusCode;
  final data = e.response?.data;
  final detail = (data is Map && data['detail'] is String)
      ? data['detail'] as String
      : (e.message ?? 'device approve request failed');
  if (status == 404) {
    return DeviceApprovalException(
      DeviceApprovalFailureReason.notFound,
      detail,
      statusCode: status,
    );
  }
  if (status == 400) {
    // approve() has no self-approve case, every 400 it can return is the
    // missing-session one.
    return DeviceApprovalException(
      DeviceApprovalFailureReason.noOperatorSession,
      detail,
      statusCode: status,
    );
  }
  return DeviceApprovalException(
    DeviceApprovalFailureReason.unknown,
    detail,
    statusCode: status,
  );
}

DeviceDenyException _mapDenyError(DioException e) {
  final status = e.response?.statusCode;
  final data = e.response?.data;
  final detail = (data is Map && data['detail'] is String)
      ? data['detail'] as String
      : (e.message ?? 'device deny request failed');
  if (status == 404) {
    return DeviceDenyException(
      DeviceDenyFailureReason.notFound,
      detail,
      statusCode: status,
    );
  }
  if (status == 400) {
    // Check the self-deny wording first: it is the more specific match,
    // "cannot deny the device you are using" versus the no-session detail's
    // generic "operator session" phrase, mirroring _mapUnlinkError's own
    // ordering for the same reason.
    if (detail.contains('cannot deny the device you are using')) {
      return DeviceDenyException(
        DeviceDenyFailureReason.selfDeny,
        detail,
        statusCode: status,
      );
    }
    if (detail.contains('operator session')) {
      return DeviceDenyException(
        DeviceDenyFailureReason.noOperatorSession,
        detail,
        statusCode: status,
      );
    }
  }
  return DeviceDenyException(
    DeviceDenyFailureReason.unknown,
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

  /// List every device that enrolled with the operator token but has not
  /// been vouched for by an already-approved device yet
  /// (`GET /api/v1/operator/devices/pending`, `device_routes.py:pending`).
  /// Every row comes back with [LinkedDevice.approved] `false`, the server
  /// sets it explicitly rather than leaving it to be inferred.
  Future<List<LinkedDevice>> listPending() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/api/v1/operator/devices/pending',
      options: _opts(),
    );
    final rows = (r.data?['devices'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((m) => LinkedDevice.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Vouch for a pending device by fingerprint, letting it mint a session.
  /// Returns the updated row (`approved: true`).
  ///
  /// Throws [DeviceApprovalException] on a non-2xx response: 400 when the
  /// caller has no operator session (only an already-approved device may
  /// vouch for a new one), 404 when [deviceFp] is not enrolled at all.
  Future<LinkedDevice> approve(String deviceFp) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '$_base/api/v1/operator/devices/$deviceFp/approve',
        data: const {},
        options: _opts(),
      );
      return LinkedDevice.fromJson(r.data ?? const {});
    } on DioException catch (e) {
      throw _mapApprovalError(e);
    }
  }

  /// Reject a pending device by fingerprint. This is a full unlink across
  /// all four stores (same as [unlink]), the row is kept only for audit.
  ///
  /// Throws [DeviceDenyException] on a non-2xx response: 400 when the caller
  /// has no operator session, 400 when [deviceFp] is the device making the
  /// call, 404 when [deviceFp] is unknown.
  Future<DeviceUnlinkReport> deny(String deviceFp) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '$_base/api/v1/operator/devices/$deviceFp/deny',
        data: const {},
        options: _opts(),
      );
      return DeviceUnlinkReport.fromJson(r.data ?? const {});
    } on DioException catch (e) {
      throw _mapDenyError(e);
    }
  }

  /// Rename one device by fingerprint. The server trims and caps [label] at
  /// 64 characters and, on success, sets `label_source` to `"operator"`
  /// (`device_routes.py:rename`), so this is the only way a row earns the
  /// trusted rendering [LinkedDevicesScreen]'s class doc describes. Returns
  /// the updated device row so the caller can refresh in place.
  ///
  /// Throws [DeviceRenameException] on a non-2xx response: 400 when [label]
  /// is empty, whitespace-only, or not a string, 404 when [deviceFp] is
  /// unknown.
  Future<LinkedDevice> rename(String deviceFp, String label) async {
    try {
      final r = await _dio.patch<Map<String, dynamic>>(
        '$_base/api/v1/operator/devices/$deviceFp',
        data: {'label': label},
        options: _opts(),
      );
      return LinkedDevice.fromJson(r.data ?? const {});
    } on DioException catch (e) {
      throw _mapRenameError(e);
    }
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
