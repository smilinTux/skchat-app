import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/modules/external_modules.dart';
import 'skcomms_client.dart';

/// A safety margin subtracted from a cached embed token's `expires_at` before it
/// is treated as still valid, so a token about to expire is re-minted proactively
/// rather than handed to an iframe moments before the proxy would reject it.
const _kEmbedTokenSafetyMargin = Duration(seconds: 15);

/// A minted embed token plus the instant it expires.
///
/// [expiresAt] is null when the mint response carried no readable expiry: an
/// unknown-expiry token is treated as NON-reusable (re-minted every call), the
/// conservative default, rather than cached indefinitely.
class _CachedEmbedToken {
  const _CachedEmbedToken(this.token, this.expiresAt);

  final String token;
  final DateTime? expiresAt;
}

/// Mints and caches short-lived, module-scoped, READ-ONLY embed tokens from the
/// skchat backend `POST /api/v1/embed-token` endpoint.
///
/// Why this exists: the shell's Grade B panes (`skdashboard`, `skos`) are
/// iframes. Once their reverse proxies are gated (leak fix A1/A4) an iframe
/// cannot present an `Authorization` header, so it would 401. The AUTHENTICATED
/// app mints an embed token here and the pane appends it to the iframe `src` as
/// `?embed_token=...`; the proxy accepts that (scoped to the exact module,
/// read-only) for the token's short life, then a path-scoped cookie the proxy
/// sets carries it for the pane's subresource loads.
///
/// The mint call rides the app's existing authenticated [SKCommsClient]: the
/// operator-session Bearer is attached by that client's Dio interceptor, so the
/// request carries the SAME credential the app already sends to the dataplane.
///
/// SHIP-DARK / graceful degradation: the backend guards this route behind the
/// `SKCHAT_EMBED_TOKENS` flag, OFF by default, so the endpoint 404s. On a 404, a
/// network error, a 401, or a malformed body, [mint] returns null and never
/// throws. A pane simply loads tokenless (and shows the upstream's own
/// gated response) until the server enables minting, exactly the prior behavior.
///
/// The cache is keyed by module: [mint] returns the cached token until it is
/// within [_kEmbedTokenSafetyMargin] of its `expires_at`, then re-mints.
class EmbedTokenService {
  /// [client] is the authenticated daemon client whose Dio interceptor attaches
  /// the operator-session Bearer. [now] defaults to [DateTime.now] and is only
  /// overridden by tests to drive the cache-expiry boundary deterministically.
  EmbedTokenService({required SKCommsClient client, DateTime Function()? now})
    : _client = client,
      _now = now ?? DateTime.now;

  final SKCommsClient _client;
  final DateTime Function() _now;

  final Map<String, _CachedEmbedToken> _cache = {};

  /// Return a cached, unexpired embed token for [module] (at the requested
  /// [mode]) if one is held; otherwise call the backend mint endpoint, cache the
  /// result with its `expires_at`, and return it. Returns null (never throws) on
  /// ANY failure so the caller degrades to loading the pane tokenless.
  ///
  /// [mode] is `ro` (read-only, default) or `rw` (read + write). The cache is
  /// keyed by `module:mode` so a ro token is never reused where a rw one was
  /// requested (or vice versa).
  Future<String?> mint(String module, {String mode = 'ro'}) async {
    final key = '$module:$mode';
    final cached = _cache[key];
    if (cached != null && _isFresh(cached)) {
      return cached.token;
    }

    final Map<String, dynamic>? data;
    try {
      data = await _client.mintEmbedToken(module, mode: mode);
    } catch (_) {
      // Defensive: mintEmbedToken already swallows transport errors, but a
      // caller must never see an exception cross this boundary.
      return null;
    }
    if (data == null) return null;

    final token = data['token'];
    if (token is! String || token.isEmpty) return null;

    _cache[key] = _CachedEmbedToken(token, _parseExpiry(data['expires_at']));
    return token;
  }

  /// True when [cached] is still comfortably before its expiry. An unknown
  /// (null) expiry is treated as stale so the token is re-minted rather than
  /// reused past a moment the proxy may already reject.
  bool _isFresh(_CachedEmbedToken cached) {
    final exp = cached.expiresAt;
    if (exp == null) return false;
    return _now().isBefore(exp.subtract(_kEmbedTokenSafetyMargin));
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

/// EmbedTokenService bound to the app's authenticated [SKCommsClient] (which
/// itself follows the runtime-configurable daemon URL). A single instance holds
/// the per-module token cache for the life of the provider.
final embedTokenServiceProvider = Provider<EmbedTokenService>((ref) {
  final client = ref.watch(skcommsClientProvider);
  return EmbedTokenService(client: client);
});

/// Async holder for the embed token of a specific gated [module]. Riverpod
/// caches the future so a pane does not re-mint on every rebuild (which would
/// flicker the iframe). Resolves to null when the backend mint flag is off or
/// the mint fails, in which case the pane loads tokenless and shows the
/// upstream's own gated response.
///
/// The requested mode is resolved from the module: a trusted admin surface
/// ([kEmbedRwModuleIds], e.g. `skdashboard`) requests `rw` so its in-pane Save
/// actions work; every other gated module requests `ro`. The server is still the
/// gate, so a `rw` request the server declines simply degrades to tokenless.
final embedTokenForModuleProvider =
    FutureProvider.family<String?, String>((ref, module) async {
  final service = ref.watch(embedTokenServiceProvider);
  return service.mint(module, mode: embedModeForModule(module));
});
