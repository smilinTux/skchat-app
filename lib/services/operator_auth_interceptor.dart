import 'package:dio/dio.dart';

import 'operator_session_service.dart';

/// Any request whose path falls under this prefix is the operator-auth
/// handshake itself (`GET .../challenge`, `POST .../session`, run by
/// [OperatorSessionService] on its OWN Dio instance). The interceptor exempts
/// these paths so it never asks [OperatorSessionService.ensureSession] to
/// authenticate the very requests that constitute the handshake (recursion).
const _kAuthHandshakePathMarker = '/api/v1/auth/';

/// Extra-map key the retry guard uses to mark a request already retried once
/// after a 401, so a daemon that keeps returning 401 fails once, not forever.
const kAuthRetriedExtraKey = 'skAuthRetried';

bool isAuthHandshakePath(String path) =>
    path.startsWith(_kAuthHandshakePathMarker);

/// Builds the operator-session Bearer interceptor shared by every daemon Dio
/// client (the SKComms data client AND the PQ prekey client).
///
/// Attaches `Authorization: Bearer <session>` best-effort and retries once on a
/// 401 after clearing the cached session and re-running the handshake.
///
/// Ship-dark contract: the skchat server gate that checks this header is OFF by
/// default, so this interceptor must NEVER block or fail a request just because
/// a session could not be minted (e.g. a fresh, unenrolled device). Any
/// [OperatorSessionService.ensureSession] failure is swallowed and the request
/// proceeds without the header.
///
/// [dio] is a getter (not the Dio itself) because the interceptor is added
/// inside the client constructor, before the `final _dio` field is fully
/// assignable to a captured local; the closure resolves it lazily on the retry
/// path.
InterceptorsWrapper buildOperatorAuthInterceptor(
  OperatorSessionService? session,
  Dio Function() dio,
) {
  return InterceptorsWrapper(
    onRequest: (options, handler) async {
      if (session == null || isAuthHandshakePath(options.path)) {
        return handler.next(options);
      }
      try {
        final token = await session.ensureSession();
        options.headers['Authorization'] = 'Bearer $token';
      } catch (_) {
        // No session available yet (not enrolled, daemon unreachable, etc).
        // Proceed unauthenticated; the server gate is off by default, so this
        // must not block the request.
      }
      return handler.next(options);
    },
    onError: (err, handler) async {
      final options = err.requestOptions;
      final alreadyRetried = options.extra[kAuthRetriedExtraKey] == true;
      if (session == null ||
          err.response?.statusCode != 401 ||
          alreadyRetried ||
          isAuthHandshakePath(options.path)) {
        return handler.next(err);
      }

      session.clearSession();
      try {
        final freshToken = await session.ensureSession();
        final retryOptions = options.copyWith(
          headers: {
            ...options.headers,
            'Authorization': 'Bearer $freshToken',
          },
          extra: {
            ...options.extra,
            kAuthRetriedExtraKey: true,
          },
        );
        final retryResponse = await dio().fetch(retryOptions);
        return handler.resolve(retryResponse);
      } catch (_) {
        // Re-auth itself failed (or the retried request failed again); surface
        // the ORIGINAL error rather than a re-auth exception.
        return handler.next(err);
      }
    },
  );
}
