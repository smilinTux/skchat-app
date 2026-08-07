import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'operator_session_service.dart';

/// Any request whose path falls under this prefix is the operator-auth
/// handshake itself (`GET .../challenge`, `POST .../session`, run by
/// [OperatorSessionService] on its OWN Dio instance). The interceptor exempts
/// these paths so it never asks [OperatorSessionService.ensureCredentials] to
/// authenticate the very requests that constitute the handshake (recursion).
const _kAuthHandshakePathMarker = '/api/v1/auth/';

/// Extra-map key the retry guard uses to mark a request already retried once
/// after a 401/403, so a daemon that keeps rejecting fails once, not forever.
const kAuthRetriedExtraKey = 'skAuthRetried';

/// Extra-map key set when the attached credential was the capauth AUDIENCE
/// token (CR-3.4 PR4 `prefer-audience`/`audience-only`). It tells the error
/// path that a 401/403 should fall back to the HS256 session rather than
/// re-running the handshake.
const kUsedAudienceExtraKey = 'skUsedAudience';

bool isAuthHandshakePath(String path) =>
    path.startsWith(_kAuthHandshakePathMarker);

/// The credential the interceptor should attach for a given policy, plus
/// whether it is the audience token (so the error path knows to fall back).
class _Selected {
  const _Selected(this.token, this.usedAudience);
  final String token;
  final bool usedAudience;
}

/// Pick the credential to attach per the server-echoed issuer policy
/// (CR-3.4 PR4). `hs256` (and any unknown value, normalized upstream) attaches
/// the HS256 session, today's behavior. `prefer-audience` attaches the audience
/// token when one is present, else the HS256 session (nothing to prefer).
/// `audience-only` attaches the audience token and, having no HS256 to fall
/// back to, returns null when it is absent (proceed unauthenticated rather than
/// present a token the policy forbids).
_Selected? _selectCredential(OperatorCredentials creds) {
  final audience = creds.audienceToken;
  final hasAudience = audience != null && audience.isNotEmpty;
  switch (creds.issuerPolicy) {
    case 'prefer-audience':
      return hasAudience
          ? _Selected(audience, true)
          : _Selected(creds.sessionToken, false);
    case 'audience-only':
      return hasAudience ? _Selected(audience, true) : null;
    case 'hs256':
    default:
      return _Selected(creds.sessionToken, false);
  }
}

/// Builds the operator-session Bearer interceptor shared by every daemon Dio
/// client (the SKComms data client AND the PQ prekey client).
///
/// Attaches `Authorization: Bearer <credential>` best-effort per the server's
/// issuer policy. Under `prefer-audience` it attaches the capauth audience
/// token and, on a 401/403, retries ONCE with the HS256 session (counting the
/// fallback) so the seat can never hard-lock: the proven HS256 path is one
/// retry away. Under the default `hs256` it attaches the HS256 session and, on
/// a 401, clears + re-handshakes once (unchanged behavior).
///
/// Ship-dark contract: the skchat server gate that checks this header is OFF by
/// default, and the issuer policy defaults to `hs256`, so this interceptor must
/// NEVER block or fail a request just because a credential could not be minted
/// (e.g. a fresh, unenrolled device). Any [ensureCredentials] failure is
/// swallowed and the request proceeds without the header.
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
      // A retried request already carries the exact credential the error path
      // chose; do NOT re-run selection here or we would clobber an HS256
      // fallback with a fresh audience token and loop.
      if (session == null ||
          isAuthHandshakePath(options.path) ||
          options.extra[kAuthRetriedExtraKey] == true) {
        return handler.next(options);
      }
      try {
        final creds = await session.ensureCredentials();
        final selected = _selectCredential(creds);
        if (selected != null) {
          options.headers['Authorization'] = 'Bearer ${selected.token}';
          if (selected.usedAudience) {
            options.extra[kUsedAudienceExtraKey] = true;
          }
        }
      } catch (_) {
        // No credential available yet (not enrolled, daemon unreachable, etc).
        // Proceed unauthenticated; the server gate is off by default, so this
        // must not block the request.
      }
      return handler.next(options);
    },
    onError: (err, handler) async {
      final options = err.requestOptions;
      final status = err.response?.statusCode;
      final alreadyRetried = options.extra[kAuthRetriedExtraKey] == true;
      final usedAudience = options.extra[kUsedAudienceExtraKey] == true;

      if (session == null ||
          alreadyRetried ||
          isAuthHandshakePath(options.path)) {
        return handler.next(err);
      }

      // CR-3.4 PR4 prefer-audience fallback: an audience-credential request that
      // 401/403s retries ONCE with the already-minted HS256 session. No
      // clearSession() (the HS256 credential is still valid; we are falling
      // back, not refreshing).
      if (usedAudience && (status == 401 || status == 403)) {
        try {
          final creds = await session.ensureCredentials();
          session.recordAudienceFallback();
          debugPrint(
            'operator-auth: audience credential drew $status on '
            '${options.path}; fell back to HS256 '
            '(fallback #${session.audienceFallbackCount})',
          );
          final retryOptions = options.copyWith(
            headers: {
              ...options.headers,
              'Authorization': 'Bearer ${creds.sessionToken}',
            },
            extra: {
              ...options.extra,
              kAuthRetriedExtraKey: true,
              kUsedAudienceExtraKey: false,
            },
          );
          final retryResponse = await dio().fetch(retryOptions);
          return handler.resolve(retryResponse);
        } catch (_) {
          return handler.next(err);
        }
      }

      // Default hs256 path: a 401 means the cached session is stale/revoked, so
      // clear it, re-handshake, and retry once (unchanged behavior).
      if (status == 401 && !usedAudience) {
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
          // Re-auth itself failed (or the retried request failed again);
          // surface the ORIGINAL error rather than a re-auth exception.
          return handler.next(err);
        }
      }

      return handler.next(err);
    },
  );
}
