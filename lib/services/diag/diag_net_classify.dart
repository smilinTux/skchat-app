/// Platform seam for classifying the underlying, non-Dio error object a
/// `connectionError`/`unknown` [DioException] wraps. Same shape as
/// `device_label.dart`: the real implementation (native, `dart:io`
/// `SocketException`/`HandshakeException` introspection) lives in
/// `diag_net_classify_io.dart`; on web (no `dart:io`) the stub always
/// returns [NetFailureKind.unknown].
library;

import 'diag_event.dart';
import 'diag_net_classify_stub.dart'
    if (dart.library.io) 'diag_net_classify_io.dart' as impl;

NetFailureKind classifyUnderlyingError(Object? error) =>
    impl.classifyUnderlyingError(error);
