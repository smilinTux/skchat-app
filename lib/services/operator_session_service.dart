import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/foundation.dart" show visibleForTesting;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "daemon_config.dart";
import "guest_identity.dart";
import "operator_session_store.dart" as op_session_store;
import "operator_token.dart" as op_token;

/// A safety margin (seconds) subtracted from a cached token's `exp` before
/// treating it as still valid, so a token that is about to expire is refreshed
/// proactively rather than being handed to a caller that then races the
/// daemon's own clock skew tolerance.
const _kExpirySafetyMarginSeconds = 30;

/// How long a FAILED handshake is remembered before [ensureSession] will try
/// again. Every gated request runs [ensureSession] (via the Dio
/// interceptor), so without this an unenrolled client (the current state for
/// everyone, enrollment UI is a later task) would fire a challenge + session
/// round-trip, the second of which 401s, before EVERY gated `/api/v1`
/// request. A short negative-cache window turns that into one round-trip per
/// window instead of one per request.
const _kNegativeCacheWindow = Duration(seconds: 30);

/// Serialize [value] the same way the server does: `json.dumps(obj,
/// sort_keys=True, separators=(",", ":"))`. Map keys are sorted (recursively,
/// for nested maps); list order is preserved. This does NOT rely on Dart's
/// default `jsonEncode`, whose key order is insertion order, not sorted, so a
/// map built in the "wrong" order would sign/verify a different byte string
/// than the server expects.
///
/// Note: Python's `json.dumps` defaults to `ensure_ascii=True`, which escapes
/// any non-ASCII character to a `\uXXXX` sequence. Dart's `jsonEncode` does
/// NOT do this by default, it emits UTF-8 bytes as-is. Every field currently
/// signed through this function (`device_fp`, `nonce`, `device_pubkey`) is
/// ASCII-only (hex fingerprints, base64, server-issued nonces), so the two
/// encodings agree today. If a future signed payload ever carries a
/// non-ASCII value, this function would need to escape it the same way
/// (`\uXXXX`, matching Python) or the client and server would sign/verify
/// different byte strings for the same logical value.
String canonicalJson(Object? value) {
  final buf = StringBuffer();
  _writeCanonical(value, buf);
  return buf.toString();
}

void _writeCanonical(Object? value, StringBuffer buf) {
  if (value is Map) {
    buf.write("{");
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buf.write(",");
      buf.write(jsonEncode(keys[i]));
      buf.write(":");
      _writeCanonical(value[keys[i]], buf);
    }
    buf.write("}");
  } else if (value is List) {
    buf.write("[");
    for (var i = 0; i < value.length; i++) {
      if (i > 0) buf.write(",");
      _writeCanonical(value[i], buf);
    }
    buf.write("]");
  } else {
    // Leaf: string / num / bool / null. jsonEncode already renders these with
    // no extraneous whitespace and matches Python's json.dumps for these types
    // (lowercase true/false/null, no NaN/Infinity in our payloads).
    buf.write(jsonEncode(value));
  }
}

/// Decode the `exp` (unix seconds) claim out of a JWT's payload segment
/// without verifying the signature. Client-side use only, to decide whether a
/// CACHED token is worth reusing; the daemon is the one true verifier of the
/// signature on every real request. Returns null on any malformed input.
int? _jwtExpClaim(String jwt) {
  final parts = jwt.split(".");
  if (parts.length < 2) return null;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final decoded = jsonDecode(payload);
    if (decoded is Map) {
      final exp = decoded["exp"];
      if (exp is num) return exp.toInt();
    }
  } catch (_) {
    // Malformed / non-JWT string, treat as no expiry info (caller re-auths).
  }
  return null;
}

/// Client-side operator-auth handshake: proves this device holds the
/// enrolled device key and exchanges that proof for a short-lived bearer
/// session JWT, the token every operator-gated daemon route will require
/// (wired in by the Dio interceptor, a later task; this service only mints
/// and caches the token).
///
/// Two flows:
///  - [ensureSession]: the day-to-day challenge-response. `GET
///    /api/v1/auth/challenge` for a nonce, sign the canonical
///    `{device_fp, nonce}` with the already-enrolled device key
///    ([GuestIdentity]), `POST /api/v1/auth/session` to redeem the signature
///    for a session JWT. Caches the token (via the dedicated
///    `operator_session_store` localStorage/secure-storage seam, kept
///    SEPARATE from the unrelated `operator_token.dart` seam) so a page
///    reload / app restart does not force a fresh handshake for every call.
///  - [enroll]: the one-time device-key registration, done once per device
///    inside an operator-opened enrollment window (`openEnrollWindow`
///    fetches that window's nonce). A later UI task drives this; this
///    service only implements the wire calls.
///
/// The cache-validity check decodes the cached JWT's own `exp` claim (rather
/// than tracking a second expiry value alongside it), so the ONLY thing that
/// needs to survive a reload is the token string itself, the same single
/// value the dedicated `operator_session_store` seam already stores.
///
/// [ensureSession] also runs a short negative cache (a recent failed
/// handshake is remembered for [_kNegativeCacheWindow] before retrying) and
/// coalesces concurrent callers onto a single in-flight handshake future, see
/// the method doc for details.
class OperatorSessionService {
  /// [dio] may be injected (tests) to supply a canned [HttpClientAdapter];
  /// its [BaseOptions.baseUrl] is set from [baseUrl] when both are provided,
  /// matching [SKCommsClient]'s constructor contract. [identity] defaults to
  /// the real platform [GuestIdentity] (WebCrypto device key). [tokenReader]
  /// / [tokenWriter] default to the dedicated `operator_session_store`
  /// module-level functions (a storage key SEPARATE from `operator_token.dart`,
  /// which holds the unrelated, manually-pasted SKCHAT_GUEST_OPERATOR_TOKEN
  /// secret, never share the two); tests inject an in-memory fake so the
  /// cache path can be exercised without depending on the web-only
  /// localStorage implementation. [now] defaults to [DateTime.now] and is
  /// only overridden by tests, to drive the negative-cache window
  /// deterministically.
  OperatorSessionService({
    String? baseUrl,
    Dio? dio,
    GuestIdentity? identity,
    String? Function()? tokenReader,
    void Function(String?)? tokenWriter,
    DateTime Function()? now,
    String? Function()? operatorTokenReader,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl ?? kDefaultDaemonUrl,
               connectTimeout: const Duration(seconds: 5),
               receiveTimeout: const Duration(seconds: 10),
               headers: {"Content-Type": "application/json"},
             ),
           ),
       _identity = identity ?? createGuestIdentity(),
       _readToken = tokenReader ?? op_session_store.operatorSessionToken,
       _writeToken = tokenWriter ?? op_session_store.setOperatorSessionToken,
       _now = now ?? DateTime.now,
       _readOperatorToken = operatorTokenReader ?? op_token.operatorToken {
    if (dio != null && baseUrl != null) {
      _dio.options.baseUrl = baseUrl;
    }
  }

  final Dio _dio;
  final GuestIdentity _identity;
  final String? Function() _readToken;
  final void Function(String?) _writeToken;
  final DateTime Function() _now;

  /// Read seam for the manually-pasted `SKCHAT_GUEST_OPERATOR_TOKEN` secret
  /// (the UNRELATED credential from the minted session JWT above, see the
  /// class doc and `operator_token.dart`'s own header comment). Defaults to
  /// the real `operator_token.dart` module; tests inject a fake so this can
  /// be exercised without depending on the web-only localStorage
  /// implementation. Consumed by [openEnrollWindow] to authenticate the
  /// server's operator-gated `enroll/open` route, the same header
  /// `mode_c_service.dart` / `guest_group_service.dart` already send for
  /// their own operator-gated routes.
  final String? Function() _readOperatorToken;

  /// This service's [GuestIdentity], exposed read-only so a caller (e.g. the
  /// device-enrollment UI) can read the device's fingerprint/public key via
  /// [GuestIdentity.ensure] without re-deriving or duplicating any signing
  /// logic. Mirrors the existing `identity` getter on [GuestGroupService].
  GuestIdentity get identity => _identity;

  /// Exposed for tests only: proves (via reference identity, so it works
  /// regardless of the web/native storage stub in play under `flutter test`)
  /// that this instance's default reader/writer are NOT the unrelated
  /// `operator_token` seam's functions. Regression guard for Fix 1.
  @visibleForTesting
  String? Function() get debugTokenReader => _readToken;

  @visibleForTesting
  void Function(String?) get debugTokenWriter => _writeToken;

  /// Exposed for tests only: the operator-token read seam (see
  /// [_readOperatorToken]'s doc), so a regression test can pin its DEFAULT
  /// to the real `operator_token.dart` module (the opposite requirement
  /// from [debugTokenReader] above, which must NOT default there).
  @visibleForTesting
  String? Function() get debugOperatorTokenReader => _readOperatorToken;

  /// Set (only while a handshake is running) so concurrent [ensureSession]
  /// calls await the SAME in-flight future instead of each starting their
  /// own handshake.
  Future<String>? _inFlightHandshake;

  /// When non-null and still in the future, a recent handshake failed and
  /// [ensureSession] short-circuits with [_negativeCacheError] instead of
  /// re-running it.
  DateTime? _negativeCacheUntil;
  Object? _negativeCacheError;

  /// Return a cached, unexpired session JWT if one is stored; otherwise run
  /// the full challenge-response handshake, cache the result, and return it.
  ///
  /// Two perf guards sit in front of the handshake:
  ///  - In-flight coalescing: if a handshake is already running, this call
  ///    awaits that SAME future rather than starting a second one.
  ///  - Negative caching: if the most recent handshake failed within the
  ///    last [_kNegativeCacheWindow], this call rethrows that failure
  ///    immediately without hitting the network again. A successful call, or
  ///    [clearSession], resets the negative cache.
  Future<String> ensureSession() async {
    final cached = _readToken();
    if (cached != null && cached.isNotEmpty && _isUnexpired(cached)) {
      return cached;
    }

    final inFlight = _inFlightHandshake;
    if (inFlight != null) {
      return inFlight;
    }

    final negativeCacheUntil = _negativeCacheUntil;
    if (negativeCacheUntil != null && _now().isBefore(negativeCacheUntil)) {
      throw _negativeCacheError ??
          StateError(
            "operator session handshake recently failed; still within the "
            "negative-cache window",
          );
    }

    final handshake = _runHandshake();
    _inFlightHandshake = handshake;
    try {
      final token = await handshake;
      _negativeCacheUntil = null;
      _negativeCacheError = null;
      return token;
    } catch (e) {
      _negativeCacheUntil = _now().add(_kNegativeCacheWindow);
      _negativeCacheError = e;
      rethrow;
    } finally {
      _inFlightHandshake = null;
    }
  }

  /// The actual challenge-response wire exchange, factored out of
  /// [ensureSession] so the negative-cache / in-flight bookkeeping there
  /// stays focused on caching concerns, not the handshake mechanics.
  Future<String> _runHandshake() async {
    final kp = await _identity.ensure();
    final deviceFp = kp.fingerprint;

    final challengeResp = await _dio.get<Map<String, dynamic>>(
      "/api/v1/auth/challenge",
    );
    final nonce = challengeResp.data?["nonce"] as String?;
    if (nonce == null || nonce.isEmpty) {
      // THROW rather than fall back to "": an empty nonce would sign a
      // bogus payload and, worse, let the interceptor's swallow-and-proceed
      // path silently attach a garbage Bearer header instead of cleanly
      // proceeding unauthenticated.
      throw StateError(
        "operator auth challenge response missing required field 'nonce'",
      );
    }

    final signed = canonicalJson({"device_fp": deviceFp, "nonce": nonce});
    final sig = await _identity.sign(signed);

    final sessionResp = await _dio.post<Map<String, dynamic>>(
      "/api/v1/auth/session",
      data: {"device_fp": deviceFp, "nonce": nonce, "sig": sig},
    );
    final token = sessionResp.data?["session_token"] as String?;
    if (token == null || token.isEmpty) {
      // Same reasoning: an empty token must not be cached or handed to the
      // interceptor as a real Bearer value.
      throw StateError(
        "operator auth session response missing required field "
        "'session_token'",
      );
    }

    _writeToken(token);
    return token;
  }

  /// Drop the cached session token, forcing the next [ensureSession] call to
  /// run a fresh challenge-response handshake. Used by the Dio interceptor
  /// (SKCommsClient) when a request comes back 401: the cached token is
  /// presumably stale or revoked, so it is discarded before retrying. Also
  /// resets the negative cache, so a caller that explicitly clears the
  /// session (as opposed to one that just keeps calling [ensureSession]) is
  /// not forced to wait out a stale failure window.
  void clearSession() {
    _writeToken(null);
    _negativeCacheUntil = null;
    _negativeCacheError = null;
  }

  /// True if a cached, unexpired session token exists RIGHT NOW. A pure
  /// cache read: no network call, no handshake, and no interaction with the
  /// negative cache. Safe to call opportunistically (e.g. when a screen
  /// mounts) to decide whether to show a "linked" state without risking a
  /// failed-handshake negative-cache window blocking a real enrollment flow
  /// that follows shortly after (an unconditional [ensureSession] call would
  /// not be safe there: if no token is cached it falls through to a full
  /// handshake attempt, which fails for a not-yet-enrolled device and arms
  /// the negative cache for [_kNegativeCacheWindow], which would then also
  /// block the FOLLOW-UP [ensureSession] call inside the enrollment flow).
  bool hasLiveSession() {
    final cached = _readToken();
    return cached != null && cached.isNotEmpty && _isUnexpired(cached);
  }

  /// True when [token] is a decodable JWT-shaped string whose `exp` claim is
  /// still comfortably in the future. A token with no readable `exp` (not a
  /// JWT, or malformed) is treated as expired, the safe default, it forces a
  /// fresh handshake rather than trusting an unverifiable cached value.
  bool _isUnexpired(String token) {
    final exp = _jwtExpClaim(token);
    if (exp == null) return false;
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    return exp > now + _kExpirySafetyMarginSeconds;
  }

  /// One-time device-key enrollment: sign the canonical
  /// `{device_pubkey, nonce: windowNonce}` with this device's key and POST it
  /// to bind the key server-side. The server's returned `device_fp` is
  /// expected to equal [GuestIdentity]'s own `fingerprint` derivation (both
  /// sides fingerprint the same SPKI base64 string identically).
  Future<void> enroll(String windowNonce) async {
    final kp = await _identity.ensure();
    final signed = canonicalJson({
      "device_pubkey": kp.publicKeyB64,
      "nonce": windowNonce,
    });
    final sig = await _identity.sign(signed);
    await _dio.post<Map<String, dynamic>>(
      "/api/v1/auth/enroll",
      data: {
        "device_pubkey": kp.publicKeyB64,
        "window_nonce": windowNonce,
        "sig": sig,
      },
    );
  }

  /// Operator-side call that opens a time-boxed enrollment window: `POST
  /// /api/v1/auth/enroll/open` (no body) -> `{window_nonce, exp}`. The
  /// returned `window_nonce` is what a NEW device signs via [enroll] to
  /// complete registration before the window's `exp`.
  ///
  /// The server guards this route with `_require_operator`: when
  /// `SKCHAT_GUEST_OPERATOR_TOKEN` is set, a caller must present it as the
  /// `X-Operator-Token` header (or over the tailnet/loopback, which the
  /// server trusts without a token). Without this header, anyone reaching
  /// the public Funnel could open an enrollment window and self-enroll a
  /// device, so this attaches the stored operator token (read via
  /// [_readOperatorToken]) whenever one is set. When none is stored, the
  /// request goes out with no header, and the server's own 401/403 is
  /// surfaced to the caller as-is (the enrollment UI already turns that into
  /// a friendly "set your operator token" message).
  Future<Map<String, dynamic>> openEnrollWindow() async {
    final tok = _readOperatorToken();
    final headers = <String, dynamic>{};
    if (tok != null && tok.isNotEmpty) {
      headers["X-Operator-Token"] = tok;
    }
    final resp = await _dio.post<Map<String, dynamic>>(
      "/api/v1/auth/enroll/open",
      options: headers.isEmpty ? null : Options(headers: headers),
    );
    return resp.data ?? const {};
  }
}

// ── Riverpod provider ───────────────────────────────────────────────────────

/// OperatorSessionService bound to the runtime-configurable daemon URL, the
/// same host every other daemon-facing client ([SKCommsClient],
/// [ConsentService], ...) uses. Watching [daemonUrlProvider] means changing
/// the daemon URL in settings rebuilds this client so the handshake hits the
/// new host.
final operatorSessionServiceProvider = Provider<OperatorSessionService>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  return OperatorSessionService(baseUrl: baseUrl);
});
