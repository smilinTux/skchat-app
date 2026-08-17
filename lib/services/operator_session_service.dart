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
/// every non-ASCII character to a `\uXXXX` sequence (an astral character,
/// e.g. an emoji, becomes a UTF-16 surrogate PAIR of two such escapes,
/// because `ensure_ascii` encodes through UTF-16, not UTF-32). Dart's
/// `jsonEncode` does NOT do this by default, it emits non-ASCII characters as
/// literal UTF-8 text. This function closes that gap itself (see
/// [_asciiEscape]) rather than relying on every caller's payload staying
/// ASCII-only forever: `label` (introduced for device enrollment) is
/// self-asserted free text and WILL contain non-ASCII values in practice
/// (accented names, CJK, emoji), and a byte mismatch here means the client
/// signs one string while the server verifies a different one, an
/// unrecoverable 401 with no way for the affected user to work around it.
String canonicalJson(Object? value) {
  final buf = StringBuffer();
  _writeCanonical(value, buf);
  return buf.toString();
}

/// Re-escape an already-`jsonEncode`d string literal (quotes and JSON's own
/// control-character escapes already applied) so every UTF-16 code unit
/// above `0x7F` is ALSO rendered as a lowercase `\uXXXX` sequence, matching
/// Python's `json.dumps(..., ensure_ascii=True)` byte-for-byte. Walking UTF-16
/// CODE UNITS (not Unicode scalar values / runes) is what reproduces Python
/// correctly for BOTH the BMP (one code unit per character) AND astral
/// characters (a surrogate pair, each half escaped on its own): Python's
/// `ensure_ascii` itself encodes an astral codepoint as that same UTF-16
/// surrogate pair: Python's json.dumps of a single emoji codepoint yields
/// TWO six-character escapes, one per surrogate half (backslash-u-d83d
/// followed by backslash-u-de00 for the grinning-face emoji), not one wider
/// escape. Safe to run on ANY `jsonEncode` output, not just strings:
/// numbers/booleans/null render as pure ASCII already, so this is a no-op
/// for them.
String _asciiEscape(String jsonEncoded) {
  final buf = StringBuffer();
  for (final unit in jsonEncoded.codeUnits) {
    if (unit > 0x7F) {
      buf
        ..write("\\u")
        ..write(unit.toRadixString(16).padLeft(4, "0"));
    } else {
      buf.writeCharCode(unit);
    }
  }
  return buf.toString();
}

void _writeCanonical(Object? value, StringBuffer buf) {
  if (value is Map) {
    buf.write("{");
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buf.write(",");
      buf.write(_asciiEscape(jsonEncode(keys[i])));
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
    // no extraneous whitespace and matches Python's json.dumps for these
    // types (lowercase true/false/null, no NaN/Infinity in our payloads);
    // _asciiEscape closes the remaining gap for non-ASCII string content.
    buf.write(_asciiEscape(jsonEncode(value)));
  }
}

/// Trim and truncate a device label to at most 64 chars, matching the
/// server's `label.strip()[:64]` (`operator_auth_routes.py:enroll`), so this
/// client signs exactly the value the server will verify against. Returns
/// null for an empty or whitespace-only [raw], the caller's signal to omit
/// the `label` field entirely rather than sign an empty string, the server
/// only adds `label` to its own signed claims when the body's label, after
/// `.strip()`, is non-empty.
String? _normalizeSignedLabel(String? raw) {
  final trimmed = raw?.trim() ?? "";
  if (trimmed.isEmpty) return null;
  if (trimmed.length <= 64) return trimmed;
  // A plain `substring(0, 64)` slices UTF-16 CODE UNITS, not characters: an
  // astral character (e.g. an emoji) is TWO code units, and a cut that lands
  // between them leaves a lone high surrogate in the stored label. That
  // value still signs and verifies fine (the signature covers whatever bytes
  // it covers) and persists to disk fine, but the server's device-list
  // response is a Starlette `JSONResponse`, which renders with
  // `ensure_ascii=False` and `.encode("utf-8")` and RAISES
  // `UnicodeEncodeError` on a lone surrogate, taking down `GET
  // /api/v1/operator/devices` for every device, not just this one. Back the
  // cut off by one code unit so the whole trailing character is dropped
  // instead of half of it.
  var cut = 64;
  final unitAtCut = trimmed.codeUnitAt(cut - 1);
  final splitsHighSurrogate = unitAtCut >= 0xD800 && unitAtCut <= 0xDBFF;
  if (splitsHighSurrogate) cut -= 1;
  return trimmed.substring(0, cut);
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

/// The issuer policies the server may echo in the session response
/// (`issuer_policy`), driving which credential the client attaches. Any value
/// outside this set is normalized to `hs256`, the safe default (attach the
/// proven HS256 session), so a server typo can never silently disable auth.
const _kValidIssuerPolicies = {"hs256", "prefer-audience", "audience-only"};

const _kDefaultIssuerPolicy = "hs256";

String _normalizeIssuerPolicy(Object? value) =>
    (value is String && _kValidIssuerPolicies.contains(value))
        ? value
        : _kDefaultIssuerPolicy;

/// The full operator credential bundle a session handshake yields (CR-3.4 PR4).
///
/// [sessionToken] is the HS256 session JWT (always present, the historical
/// credential and the automatic fallback). [audienceToken] is the parallel
/// capauth audience token minted for `operator:<device_fp>` when the server has
/// `SKCHAT_OPERATOR_AUDIENCE_ISSUE` on (else null). [issuerPolicy] is the
/// server-echoed preference (`hs256` default / `prefer-audience` /
/// `audience-only`) so the client's choice is server-driven and reversible with
/// no app rebuild.
class OperatorCredentials {
  const OperatorCredentials({
    required this.sessionToken,
    this.audienceToken,
    this.audienceExpiresAt,
    this.issuerPolicy = _kDefaultIssuerPolicy,
  });

  final String sessionToken;
  final String? audienceToken;
  final String? audienceExpiresAt;
  final String issuerPolicy;
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

  /// Set (only while a handshake is running) so concurrent [ensureSession] /
  /// [ensureCredentials] calls await the SAME in-flight future instead of each
  /// starting their own handshake.
  Future<OperatorCredentials>? _inFlightHandshake;

  /// Count of times the interceptor fell back from the audience token to the
  /// HS256 session after a 401/403 (CR-3.4 PR4). Surfaced read-only via
  /// [audienceFallbackCount] for the operator status UI and the Phase 3 soak
  /// gate ("fallback counter stays zero across seat devices"). A pure counter:
  /// the structured log line the interceptor emits carries the detail.
  int _audienceFallbackCount = 0;

  /// How many audience->HS256 fallbacks this service has recorded. Zero on a
  /// healthy `prefer-audience` seat.
  int get audienceFallbackCount => _audienceFallbackCount;

  /// Record one audience->HS256 fallback. Called by the operator-auth
  /// interceptor when an audience-credential request 401/403s and it retries
  /// with the HS256 session.
  void recordAudienceFallback() {
    _audienceFallbackCount += 1;
  }

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
  ///    immediately without hitting the network again. A successful call,
  ///    [clearSession], or a successful [enroll], resets the negative cache.
  Future<String> ensureSession() async =>
      (await ensureCredentials()).sessionToken;

  /// The full [OperatorCredentials] bundle (HS256 session + optional audience
  /// token + server-echoed issuer policy). Returns a cached, unexpired bundle
  /// if one is stored; otherwise runs the challenge-response handshake, caches
  /// the result, and returns it. Cache validity keys off the HS256 session
  /// token's own `exp` (the audience token shares its 12h TTL), so the same
  /// single stored value survives a reload. The two perf guards ([ensureSession]
  /// doc) sit in front of the handshake unchanged.
  Future<OperatorCredentials> ensureCredentials() async {
    final cached = _parseStored(_readToken());
    if (cached != null && _isUnexpired(cached.sessionToken)) {
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
      final creds = await handshake;
      _negativeCacheUntil = null;
      _negativeCacheError = null;
      return creds;
    } catch (e) {
      _negativeCacheUntil = _now().add(_kNegativeCacheWindow);
      _negativeCacheError = e;
      rethrow;
    } finally {
      _inFlightHandshake = null;
    }
  }

  /// Parse the stored credential slot, which is EITHER a bare HS256 JWT (the
  /// pre-PR4 and hs256-path shape, kept byte-identical so nothing about the
  /// live seat changes) OR a JSON envelope carrying the audience token + issuer
  /// policy (written only once the server actually issues an audience token).
  /// Returns null for an empty or malformed slot, which forces a fresh
  /// handshake.
  OperatorCredentials? _parseStored(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.trimLeft().startsWith("{")) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final session = decoded["session_token"];
          if (session is String && session.isNotEmpty) {
            final audience = decoded["audience_token"];
            final audienceExp = decoded["audience_expires_at"];
            return OperatorCredentials(
              sessionToken: session,
              audienceToken: (audience is String && audience.isNotEmpty)
                  ? audience
                  : null,
              audienceExpiresAt: audienceExp is String ? audienceExp : null,
              issuerPolicy: _normalizeIssuerPolicy(decoded["issuer_policy"]),
            );
          }
        }
      } catch (_) {
        // Malformed envelope: treat as no cache (re-handshake), never trust it.
      }
      return null;
    }
    // Legacy / hs256-path bare JWT.
    return OperatorCredentials(sessionToken: raw);
  }

  /// Serialize an [OperatorCredentials] bundle for the storage slot. With NO
  /// audience token (the hs256 path) this is the bare session JWT, byte-for-byte
  /// what the pre-PR4 code stored; existing readers and tests are unaffected.
  /// With an audience token it is a compact JSON envelope.
  String _serializeCredentials(OperatorCredentials creds) {
    final audience = creds.audienceToken;
    if (audience == null || audience.isEmpty) {
      return creds.sessionToken;
    }
    return jsonEncode({
      "session_token": creds.sessionToken,
      "audience_token": audience,
      if (creds.audienceExpiresAt != null)
        "audience_expires_at": creds.audienceExpiresAt,
      "issuer_policy": creds.issuerPolicy,
    });
  }

  /// The actual challenge-response wire exchange, factored out of
  /// [ensureSession] so the negative-cache / in-flight bookkeeping there
  /// stays focused on caching concerns, not the handshake mechanics.
  Future<OperatorCredentials> _runHandshake() async {
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
    final data = sessionResp.data;
    final token = data?["session_token"] as String?;
    if (token == null || token.isEmpty) {
      // Same reasoning: an empty token must not be cached or handed to the
      // interceptor as a real Bearer value.
      throw StateError(
        "operator auth session response missing required field "
        "'session_token'",
      );
    }

    // CR-3.4 PR4: the response ADDITIONALLY carries a parallel capauth audience
    // token and the server's issuer policy when parallel issuance is on. All
    // three are optional and additive; a pre-PR4 server (or the flag off) omits
    // them and the bundle degrades to the pure HS256 credential.
    final audience = data?["audience_token"] as String?;
    final creds = OperatorCredentials(
      sessionToken: token,
      audienceToken: (audience != null && audience.isNotEmpty) ? audience : null,
      audienceExpiresAt: data?["audience_expires_at"] as String?,
      issuerPolicy: _normalizeIssuerPolicy(data?["issuer_policy"]),
    );

    _writeToken(_serializeCredentials(creds));
    return creds;
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
    _resetNegativeCache();
  }

  /// Drop any armed negative cache, so the next [ensureSession] call runs a
  /// fresh handshake instead of rethrowing a remembered failure. Shared by
  /// [clearSession] and a successful [enroll]: a device that just enrolled
  /// invalidates every "device not enrolled" failure the negative cache may
  /// have recorded before enrollment (the day-to-day request path, which is
  /// the reason the negative cache exists at all, is untouched by this,
  /// only these two explicit call sites reach it).
  void _resetNegativeCache() {
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
    final cached = _parseStored(_readToken());
    return cached != null && _isUnexpired(cached.sessionToken);
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
  /// `{device_pubkey, nonce: windowNonce}` (or, when [label] is given, the
  /// canonical `{device_pubkey, label, nonce}`) with this device's key and
  /// POST it to bind the key server-side. The server's returned `device_fp`
  /// is expected to equal [GuestIdentity]'s own `fingerprint` derivation
  /// (both sides fingerprint the same SPKI base64 string identically).
  ///
  /// [label] is an optional, self-asserted name for this device (e.g. "Linux
  /// (chef-laptop)"). When present it is signed ALONGSIDE the pubkey and
  /// nonce (`operator_auth_routes.py:enroll`'s R2 behavior), so a proxy
  /// cannot rewrite what a device calls itself without invalidating the
  /// signature. Trimmed and truncated to 64 chars before signing, matching
  /// the server's own `label.strip()[:64]`, the exact value it verifies
  /// against; a whitespace-only or empty [label] is treated as absent. When
  /// [label] is omitted (or empty), the signed payload stays the original
  /// two-field shape, the server's documented backwards-compatible path for
  /// a client that sends no label at all, so this call keeps working
  /// unchanged for any caller that does not pass one.
  ///
  /// [capauthChallengeB64] is [openEnrollWindow]'s `capauth_challenge`
  /// field, verbatim, when it was present in that response (`inc-c72a9120`
  /// part 3): base64 of the exact bytes capauth's `enroll_device` requires a
  /// signature over for a `verified` enrollment
  /// (`operator_grants.verified_enrollment_challenge`, server-side). This
  /// method never re-derives those bytes itself, only signs whatever the
  /// server handed back, see [_signCapauthChallenge] for why. When present
  /// and signable, the resulting signature is sent as `capauth_proof`. When
  /// absent, empty, or unusable (not valid base64, or the decoded bytes are
  /// not valid UTF-8), enrollment proceeds with NO `capauth_proof` field
  /// rather than failing: the server's own documented behavior for a missing
  /// proof is a graceful `tofu`-tier fallback, not a hard refusal, so this
  /// client must not turn a best-effort proof into a blocking requirement.
  ///
  /// A successful enroll invalidates any negative cache armed by earlier
  /// pre-enrollment [ensureSession] failures (every gated request runs
  /// [ensureSession] via the Dio interceptor, so an unenrolled device racks
  /// up failed handshakes before the user ever links it). Without resetting
  /// the cache here, the [ensureSession] call that follows enrollment in the
  /// UI's link flow would rethrow that stale failure instead of running a
  /// fresh handshake against the now-enrolled device, even though enrollment
  /// itself just succeeded.
  Future<void> enroll(
    String windowNonce, {
    String? label,
    String? capauthChallengeB64,
  }) async {
    final kp = await _identity.ensure();
    final signedLabel = _normalizeSignedLabel(label);
    final claims = <String, Object?>{
      "device_pubkey": kp.publicKeyB64,
      "nonce": windowNonce,
      if (signedLabel != null) "label": signedLabel,
    };
    final signed = canonicalJson(claims);
    final sig = await _identity.sign(signed);
    final capauthProof =
        (capauthChallengeB64 != null && capauthChallengeB64.isNotEmpty)
        ? await _signCapauthChallenge(capauthChallengeB64)
        : null;
    await _dio.post<Map<String, dynamic>>(
      "/api/v1/auth/enroll",
      data: {
        "device_pubkey": kp.publicKeyB64,
        "window_nonce": windowNonce,
        "sig": sig,
        if (signedLabel != null) "label": signedLabel,
        if (capauthProof != null) "capauth_proof": capauthProof,
      },
    );
    _resetNegativeCache();
  }

  /// Sign the SERVER-derived capauth enrollment challenge
  /// ([openEnrollWindow]'s `capauth_challenge`, base64 of capauth's own
  /// domain-separated bytes). Returns null (never throws) on any malformed
  /// input, so [enroll] degrades to an un-proofed enrollment instead of
  /// blocking the whole flow on a bad or absent challenge.
  ///
  /// Signs the DECODED bytes, never the base64 TEXT: capauth verifies the
  /// signature against the raw challenge bytes it built server-side
  /// (`verified_challenge()`: a domain literal + capauth's 40-char-uppercase
  /// fingerprint + the canonicalized subject, colon-joined, UTF-8 encoded),
  /// so signing the base64 string instead would be a real signature over the
  /// WRONG bytes. capauth rejects that exactly like a missing proof (a quiet
  /// tier downgrade, not a loud error), which is precisely the trap called
  /// out in the incident: re-deriving OR mis-signing the challenge fails
  /// silently, so this deliberately signs only what the server handed back.
  ///
  /// [GuestIdentity.sign] takes a [String] and UTF-8-encodes it internally
  /// (see e.g. `guest_identity_io.dart`'s `sign()`); the round trip through
  /// [utf8.decode] here is lossless because the server always builds the
  /// challenge as `f"...".encode("utf-8")`, i.e. the decoded bytes are valid
  /// UTF-8 text by construction, and `utf8.encode(utf8.decode(bytes)) ==
  /// bytes` for any valid UTF-8 input. [utf8.decode]'s default strict mode
  /// (no `allowMalformed`) throws on anything else, caught below and treated
  /// as "no usable challenge" rather than guessing at a repair.
  Future<String?> _signCapauthChallenge(String challengeB64) async {
    try {
      final bytes = base64.decode(challengeB64);
      final text = utf8.decode(bytes);
      return await _identity.sign(text);
    } catch (_) {
      return null;
    }
  }

  /// Operator-side call that opens a time-boxed enrollment window: `POST
  /// /api/v1/auth/enroll/open` -> `{window_nonce, exp}`. The returned
  /// `window_nonce` is what a NEW device signs via [enroll] to complete
  /// registration before the window's `exp`.
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
  ///
  /// The body now carries this device's own `device_pubkey`
  /// (`inc-c72a9120` part 3), the SAME pubkey [enroll] will send in its own
  /// request (both read [_identity], whose `ensure()` caches, so the two
  /// calls always see byte-identical key material, never independently
  /// re-derived or re-encoded copies -- that matters because the server
  /// fingerprints the raw string exactly as presented, and a variant would
  /// yield a challenge whose signature [enroll]'s later request rejects).
  /// A server that recognizes this field hands back an ADDITIONAL
  /// `capauth_challenge` (base64 of the exact bytes a `verified` enrollment
  /// must sign, derived server-side -- see [enroll]'s doc for why that
  /// derivation deliberately does not happen here). This is purely additive:
  /// a server that ignores or doesn't understand `device_pubkey` still
  /// returns the original two-key `{window_nonce, exp}` response, and
  /// [enroll] degrades gracefully to an un-proofed enrollment when
  /// `capauth_challenge` is absent.
  Future<Map<String, dynamic>> openEnrollWindow() async {
    final tok = _readOperatorToken();
    final headers = <String, dynamic>{};
    if (tok != null && tok.isNotEmpty) {
      headers["X-Operator-Token"] = tok;
    }
    final kp = await _identity.ensure();
    final resp = await _dio.post<Map<String, dynamic>>(
      "/api/v1/auth/enroll/open",
      data: {"device_pubkey": kp.publicKeyB64},
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
