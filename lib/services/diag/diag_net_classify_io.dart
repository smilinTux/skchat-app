// Native classification of the object `DioException.error` carries when
// `DioException.type` is `connectionError` or `unknown` (spec 4.3: "mapping
// DioException.type + SocketException details to the enum"). Selected via
// the `diag_net_classify.dart` conditional-import seam, same pattern as
// `device_label.dart` -> `device_label_io.dart`.
//
// Reads exception TYPE and, at most, the message/OSError CODE of a
// SocketException to pick a bucket. Never returns, stores, or logs the
// message text itself: the only thing that leaves this function is a
// [NetFailureKind] enum value, so there is no path from here into a leaked
// hostname, URL or token.

import 'dart:io';

import 'diag_event.dart';

/// ECONNREFUSED across the platforms Flutter natively targets: Linux/Android
/// 111, macOS/iOS 61, Windows 10061 (WSAECONNREFUSED).
const _refusedErrorCodes = {111, 61, 10061};

NetFailureKind classifyUnderlyingError(Object? error) {
  if (error is HandshakeException || error is TlsException) {
    return NetFailureKind.tls;
  }
  if (error is SocketException) {
    final message = error.message.toLowerCase();
    if (message.contains('lookup') || message.contains('resolve')) {
      return NetFailureKind.dns;
    }
    final errorCode = error.osError?.errorCode;
    if (errorCode != null && _refusedErrorCodes.contains(errorCode)) {
      return NetFailureKind.refused;
    }
    if (message.contains('refused')) {
      return NetFailureKind.refused;
    }
    return NetFailureKind.unknown;
  }
  return NetFailureKind.unknown;
}
