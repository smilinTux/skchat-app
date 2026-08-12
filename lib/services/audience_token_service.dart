import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'skcomms_client.dart';

/// A safety margin subtracted from a cached audience token's `expires_at`
/// before it is treated as still valid, so a token that is about to expire is
/// re-minted proactively rather than being handed to the module moments before
/// the dataplane would reject it for clock skew.
const _kAudienceTokenSafetyMargin = Duration(seconds: 30);

/// A minted audience token plus the instant it expires.
///
/// [expiresAt] is null when the mint response carried no readable expiry: an
/// unknown-expiry token is treated as NON-reusable (re-minted every call), the
/// conservative default, rather than cached indefinitely.
class _CachedAudienceToken {
  const _CachedAudienceToken(this.token, this.expiresAt);

  final String token;
  final DateTime? expiresAt;
}

/// Mints and caches short-lived, audience-scoped bearer tokens from the skchat
/// backend `POST /api/v1/audience-token` endpoint, completing the audience
/// token chain (capauth mints -> backend serves -> shell holds -> dataplane
/// accepts).
///
/// The mint call rides the app's existing authenticated [SKCommsClient]: the
/// operator-session Bearer is attached by that client's Dio interceptor, so the
/// request carries the SAME credential the app already sends to the dataplane.
///
/// SHIP-DARK / graceful degradation: the backend guards this route behind the
/// `SKCHAT_AUDIENCE_MINT` flag, which is OFF by default, so the endpoint 404s.
/// On a 404 (endpoint inert), a network error, a 401, or a malformed body,
/// [mint] returns null and never throws. A mounted module simply runs tokenless
/// until the server enables minting, exactly the prior stubbed behavior.
///
/// The cache is keyed by audience: [mint] returns the cached token until it is
/// within [_kAudienceTokenSafetyMargin] of its `expires_at`, then re-mints.
class AudienceTokenService {
  /// [client] is the authenticated daemon client whose Dio interceptor attaches
  /// the operator-session Bearer. [now] defaults to [DateTime.now] and is only
  /// overridden by tests to drive the cache-expiry boundary deterministically.
  AudienceTokenService({required SKCommsClient client, DateTime Function()? now})
    : _client = client,
      _now = now ?? DateTime.now;

  final SKCommsClient _client;
  final DateTime Function() _now;

  final Map<String, _CachedAudienceToken> _cache = {};

  /// Return a cached, unexpired audience token for [audience] if one is held;
  /// otherwise call the backend mint endpoint, cache the result with its
  /// `expires_at`, and return it. Returns null (never throws) on ANY failure so
  /// the caller degrades to running tokenless.
  Future<String?> mint(String audience) async {
    final cached = _cache[audience];
    if (cached != null && _isFresh(cached)) {
      return cached.token;
    }

    final Map<String, dynamic>? data;
    try {
      data = await _client.mintAudienceToken(audience);
    } catch (_) {
      // Defensive: mintAudienceToken already swallows transport errors, but a
      // token() caller must never see an exception cross this boundary.
      return null;
    }
    if (data == null) return null;

    final token = data['token'];
    if (token is! String || token.isEmpty) return null;

    _cache[audience] = _CachedAudienceToken(token, _parseExpiry(data['expires_at']));
    return token;
  }

  /// Drop the cached token for [audience], if one is held.
  ///
  /// [mint]'s clock-freshness check cannot detect every way a token goes bad:
  /// a token can be unexpired and still get rejected server-side because it
  /// was revoked, the verifier restarted, or a PDP policy changed. An HTTP
  /// 401 or a WS 1008 close is the server telling the caller its cache is
  /// wrong, something the 30s expiry margin alone can never see. Callers on
  /// that path MUST call [invalidate] before the next [mint], or [mint] just
  /// hands back the identical stale (but still clock-fresh) token and the
  /// retry fails identically.
  ///
  /// A no-op when nothing is cached for [audience] (never throws).
  void invalidate(String audience) {
    _cache.remove(audience);
  }

  /// True when [cached] is still comfortably before its expiry. An unknown
  /// (null) expiry is treated as stale so the token is re-minted rather than
  /// reused past a moment the dataplane may already reject.
  bool _isFresh(_CachedAudienceToken cached) {
    final exp = cached.expiresAt;
    if (exp == null) return false;
    return _now().isBefore(exp.subtract(_kAudienceTokenSafetyMargin));
  }

  /// Parse the wire `expires_at` into a [DateTime], tolerating either a unix
  /// epoch-seconds number (or numeric string) or an ISO-8601 timestamp. Returns
  /// null on anything unparseable, which downgrades the token to non-reusable.
  DateTime? _parseExpiry(Object? raw) {
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        (raw * 1000).round(),
        isUtc: true,
      );
    }
    if (raw is String && raw.isNotEmpty) {
      final asEpoch = int.tryParse(raw);
      if (asEpoch != null) {
        return DateTime.fromMillisecondsSinceEpoch(asEpoch * 1000, isUtc: true);
      }
      return DateTime.tryParse(raw);
    }
    return null;
  }
}

/// AudienceTokenService bound to the app's authenticated [SKCommsClient] (which
/// itself follows the runtime-configurable daemon URL). A single instance holds
/// the per-audience token cache for the life of the provider, so it survives
/// the frequent rebuilds of the transient [AppAuthContext] the module host
/// constructs on each frame.
final audienceTokenServiceProvider = Provider<AudienceTokenService>((ref) {
  final client = ref.watch(skcommsClientProvider);
  return AudienceTokenService(client: client);
});

/// Async holder for the audience token of a specific [audience]. Riverpod caches
/// the future so a pane does not re-mint on every rebuild (which would flicker
/// the iframe it feeds). Resolves to null when the backend mint flag is off
/// (`SKCHAT_AUDIENCE_MINT`), the mint 401s, or the network fails, in which case
/// the caller loads tokenless and the upstream returns its own gated response.
///
/// This is the direct analog of `embedTokenForModuleProvider`: the skcode pane
/// watches it for audience `skcode` and appends the returned wire token to the
/// hostd client iframe URL as `?token=...`.
final audienceTokenForAudienceProvider =
    FutureProvider.family<String?, String>((ref, audience) async {
  final service = ref.watch(audienceTokenServiceProvider);
  return service.mint(audience);
});
