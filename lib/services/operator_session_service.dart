import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "daemon_config.dart";
import "guest_identity.dart";
import "operator_token.dart" as op_token;

/// A safety margin (seconds) subtracted from a cached token's `exp` before
/// treating it as still valid, so a token that is about to expire is refreshed
/// proactively rather than being handed to a caller that then races the
/// daemon's own clock skew tolerance.
const _kExpirySafetyMarginSeconds = 30;

/// Serialize [value] the same way the server does: `json.dumps(obj,
/// sort_keys=True, separators=(",", ":"))`. Map keys are sorted (recursively,
/// for nested maps); list order is preserved. This does NOT rely on Dart's
/// default `jsonEncode`, whose key order is insertion order, not sorted, so a
/// map built in the "wrong" order would sign/verify a different byte string
/// than the server expects.
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
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
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
///    for a session JWT. Caches the token (via the `operator_token`
///    localStorage/secure-storage seam) so a page reload / app restart does
///    not force a fresh handshake for every call.
///  - [enroll]: the one-time device-key registration, done once per device
///    inside an operator-opened enrollment window (`openEnrollWindow`
///    fetches that window's nonce). A later UI task drives this; this
///    service only implements the wire calls.
///
/// The cache-validity check decodes the cached JWT's own `exp` claim (rather
/// than tracking a second expiry value alongside it), so the ONLY thing that
/// needs to survive a reload is the token string itself, the same single
/// value the `operator_token` seam already stores.
class OperatorSessionService {
  /// [dio] may be injected (tests) to supply a canned [HttpClientAdapter];
  /// its [BaseOptions.baseUrl] is set from [baseUrl] when both are provided,
  /// matching [SKCommsClient]'s constructor contract. [identity] defaults to
  /// the real platform [GuestIdentity] (WebCrypto device key). [tokenReader]
  /// / [tokenWriter] default to the `operator_token` module-level functions;
  /// tests inject an in-memory fake so the cache path can be exercised
  /// without depending on the web-only localStorage implementation.
  OperatorSessionService({
    String? baseUrl,
    Dio? dio,
    GuestIdentity? identity,
    String? Function()? tokenReader,
    void Function(String?)? tokenWriter,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? kDefaultDaemonUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 10),
                headers: {"Content-Type": "application/json"},
              ),
            ),
        _identity = identity ?? createGuestIdentity(),
        _readToken = tokenReader ?? op_token.operatorToken,
        _writeToken = tokenWriter ?? op_token.setOperatorToken {
    if (dio != null && baseUrl != null) {
      _dio.options.baseUrl = baseUrl;
    }
  }

  final Dio _dio;
  final GuestIdentity _identity;
  final String? Function() _readToken;
  final void Function(String?) _writeToken;

  /// Return a cached, unexpired session JWT if one is stored; otherwise run
  /// the full challenge-response handshake, cache the result, and return it.
  Future<String> ensureSession() async {
    final cached = _readToken();
    if (cached != null && cached.isNotEmpty && _isUnexpired(cached)) {
      return cached;
    }

    final kp = await _identity.ensure();
    final deviceFp = kp.fingerprint;

    final challengeResp =
        await _dio.get<Map<String, dynamic>>("/api/v1/auth/challenge");
    final nonce = (challengeResp.data?["nonce"] as String?) ?? "";

    final signed = canonicalJson({"device_fp": deviceFp, "nonce": nonce});
    final sig = await _identity.sign(signed);

    final sessionResp = await _dio.post<Map<String, dynamic>>(
      "/api/v1/auth/session",
      data: {"device_fp": deviceFp, "nonce": nonce, "sig": sig},
    );
    final token = (sessionResp.data?["session_token"] as String?) ?? "";

    _writeToken(token);
    return token;
  }

  /// Drop the cached session token, forcing the next [ensureSession] call to
  /// run a fresh challenge-response handshake. Used by the Dio interceptor
  /// (SKCommsClient) when a request comes back 401: the cached token is
  /// presumably stale or revoked, so it is discarded before retrying.
  void clearSession() {
    _writeToken(null);
  }

  /// True when [token] is a decodable JWT-shaped string whose `exp` claim is
  /// still comfortably in the future. A token with no readable `exp` (not a
  /// JWT, or malformed) is treated as expired, the safe default, it forces a
  /// fresh handshake rather than trusting an unverifiable cached value.
  bool _isUnexpired(String token) {
    final exp = _jwtExpClaim(token);
    if (exp == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
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

  /// Operator-side call (a later UI task) that opens a time-boxed enrollment
  /// window: `POST /api/v1/auth/enroll/open` (no body) -> `{window_nonce,
  /// exp}`. The returned `window_nonce` is what a NEW device signs via
  /// [enroll] to complete registration before the window's `exp`.
  Future<Map<String, dynamic>> openEnrollWindow() async {
    final resp =
        await _dio.post<Map<String, dynamic>>("/api/v1/auth/enroll/open");
    return resp.data ?? const {};
  }
}

// ── Riverpod provider ───────────────────────────────────────────────────────

/// OperatorSessionService bound to the runtime-configurable daemon URL, the
/// same host every other daemon-facing client ([SKCommsClient],
/// [ConsentService], ...) uses. Watching [daemonUrlProvider] means changing
/// the daemon URL in settings rebuilds this client so the handshake hits the
/// new host.
final operatorSessionServiceProvider =
    Provider<OperatorSessionService>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  return OperatorSessionService(baseUrl: baseUrl);
});
