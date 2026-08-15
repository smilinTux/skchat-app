// Compile-time fallback for a target with no `dart:io` (web). Mirrors the
// `device_label_stub.dart` / `device_label_io.dart` platform-seam pattern
// used elsewhere in `lib/services/`.
//
// On web there is no `SocketException` / `HandshakeException` type
// information to introspect (dio's browser adapter surfaces a different,
// less detailed error shape), so an underlying `connectionError`/`unknown`
// `DioException` classifies as [NetFailureKind.unknown] here rather than
// guessing from a JS error object. See `diag_net_classify_io.dart` for the
// native implementation this stubs.

import 'diag_event.dart';

NetFailureKind classifyUnderlyingError(Object? error) => NetFailureKind.unknown;
