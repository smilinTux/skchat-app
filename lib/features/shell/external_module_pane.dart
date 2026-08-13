import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/modules/external_modules.dart';
import '../../core/theme/theme.dart';
import '../../services/daemon_config.dart';
import '../../services/embed_token_service.dart';
// Reuse the exact conditional-import embed the Code pane uses: an iframe on
// web, a host-URL fallback on native. One URL in, one embed out.
import '../skcode/skcode_web_embed_stub.dart'
    if (dart.library.html) '../skcode/skcode_web_embed.dart';

/// Safety margin subtracted from a gated pane's cached embed-token expiry
/// before scheduling its proactive refresh: the pane re-mints 60s early so the
/// round-trip has margin before the proxy would reject the outgoing token.
const _kPaneRefreshSafetyMargin = Duration(seconds: 60);

/// The shortest real (non-fallback) refresh lead time this pane will act on.
/// A computed lead shorter than this (clock skew, a very short-lived token,
/// or an expiry already in the past) is too tight to trust, so [_refreshDelay]
/// falls back to [_kPaneRefreshFallback] instead.
const _kPaneMinRefreshLead = Duration(seconds: 30);

/// Fallback proactive-refresh delay used when a token's expiry is unknown or
/// too close to trust. Conservatively under the server's embed-token TTL
/// (1800s / 30 minutes as of this writing, but this floor does not depend on
/// that exact number): a pane refreshing every 20 minutes never rides a token
/// past expiry even if the server shortens the TTL somewhat.
const _kPaneRefreshFallback = Duration(minutes: 20);

/// The proactive-refresh delay for a gated pane's embed token, given its known
/// [expiry] (nullable) and the current instant [now].
///
/// Refreshes [_kPaneRefreshSafetyMargin] before the real expiry. Falls back to
/// [_kPaneRefreshFallback] when [expiry] is null (the mint response carried no
/// readable `expires_at`) or when the early-refresh instant is already less
/// than [_kPaneMinRefreshLead] away / in the past.
Duration _refreshDelay(DateTime? expiry, DateTime now) {
  if (expiry != null) {
    final delay = expiry.subtract(_kPaneRefreshSafetyMargin).difference(now);
    if (delay >= _kPaneMinRefreshLead) return delay;
  }
  return _kPaneRefreshFallback;
}

/// Host pane for a DISCOVERED external subapp module (card e378d895).
///
/// Resolves the manifest for [moduleId] from `externalModuleByIdProvider` and
/// renders its Grade B web surface embedded over the 443 funnel (same pattern
/// as `SkcodePane`). Grade A native panes are NOT built here (that is a later
/// phase); every discovered subapp is embedded.
///
/// EMBED AUTH (leak fix A1/A4). The `skdashboard` / `skos` panes ride GATED
/// same-origin proxies that require operator auth, but an iframe cannot set an
/// `Authorization` header. For those modules this pane first fetches a
/// short-lived, module-scoped, READ-ONLY embed token from the authenticated
/// backend (`embedTokenForModuleProvider`) and appends it to the iframe `src`
/// as `?embed_token=...`, so the pane loads for the authenticated user only.
/// skcode needs no token (public client shell). The iframe sandbox from the
/// containment work (opaque origin, no `allow-same-origin`) is unchanged.
///
/// It degrades honestly: while discovery (or the token fetch) is still resolving
/// it shows a spinner; if the id is unknown it shows a plain "not available"
/// message; if the token mint is off/failed the pane still loads (tokenless) and
/// shows the upstream's own gated response rather than crashing.
///
/// PROACTIVE REFRESH. A gated pane's embed token is short-lived (server TTL
/// 1800s at the time of writing, but this pane never hardcodes that number).
/// Rather than wait for the token to lapse mid-session and show the upstream's
/// "capauth authentication required" response inside the frame, the pane
/// schedules a single timer keyed to the token's REAL `expires_at` (read back
/// from `EmbedTokenService.currentExpiry`). On fire it drops the cached token
/// and invalidates the provider, forcing a fresh mint; the new token changes
/// the framed URL, and a `ValueKey` on that URL forces the embed to actually
/// reload rather than Flutter reusing the old platform view. This resets the
/// pane to the module's entry page every ~20-30 minutes, which is an
/// acceptable trade against ever hitting a stale-token auth wall mid-session.
class ExternalModulePane extends ConsumerStatefulWidget {
  const ExternalModulePane({super.key, required this.moduleId});

  final String moduleId;

  /// Resolve the manifest `entry.url` to an embeddable URL. Absolute URLs are
  /// used verbatim; a relative path is joined onto the daemon origin so the
  /// embed rides the same funnel the rest of the app uses.
  String _resolveUrl(String entryUrl, String daemonOrigin) {
    final trimmed = entryUrl.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final origin = daemonOrigin.replaceAll(RegExp(r'/+$'), '');
    final path = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return '$origin$path';
  }

  /// Append a module-scoped embed token to the iframe URL as a query param,
  /// preserving any existing query string.
  String _appendEmbedToken(String url, String token) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}embed_token=${Uri.encodeQueryComponent(token)}';
  }

  @override
  ConsumerState<ExternalModulePane> createState() => _ExternalModulePaneState();
}

class _ExternalModulePaneState extends ConsumerState<ExternalModulePane> {
  Timer? _refreshTimer;

  @override
  void didUpdateWidget(covariant ExternalModulePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different module id invalidates any pending refresh scheduled for the
    // OLD module: the timer's clearCache/invalidate calls are keyed by
    // `widget.moduleId`, which the framework has already repointed to the new
    // widget by the time a stale timer would fire.
    if (oldWidget.moduleId != widget.moduleId) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Cancel any pending refresh timer and arm a new one from the CURRENT
  /// cached expiry for `widget.moduleId`. Called every time the gated-module
  /// token provider settles on a freshly minted token (see the `ref.listen`
  /// in [build]), including when a re-mint happens to return the same token
  /// string: rescheduling from a fresh `currentExpiry()` read each time is
  /// what keeps this from ever tightening into a refresh loop.
  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final expiry = ref.read(embedTokenServiceProvider).currentExpiry(
      widget.moduleId,
      mode: embedModeForModule(widget.moduleId),
    );
    _refreshTimer = Timer(_refreshDelay(expiry, DateTime.now()), () {
      if (!mounted) return;
      // Force a fresh mint on the next watch. `clearCache` + `invalidate`
      // never throw; if the ensuing mint itself fails the FutureProvider
      // settles to a null/error value exactly like the pane's initial fetch,
      // both already handled by `tokenAsync.when` below -- the pane simply
      // keeps showing its last frame.
      ref.read(embedTokenServiceProvider).clearCache(widget.moduleId);
      ref.invalidate(embedTokenForModuleProvider(widget.moduleId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final external = ref.watch(externalModulesProvider);
    final manifest = ref.watch(externalModuleByIdProvider(widget.moduleId));
    final subtle = Theme.of(context).textTheme.bodySmall?.color;

    if (manifest == null) {
      // Still loading discovery -> spinner; otherwise -> honest empty state.
      if (external.isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.widgets_outlined, size: 40),
              const SizedBox(height: 12),
              Text(
                'This module is not available on the current server.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    final origin = ref.watch(daemonUrlProvider);
    final url = widget._resolveUrl(manifest.externalEntryUrl ?? '', origin);

    // For a gated module (skdashboard / skos) fetch a scoped embed token first,
    // then frame `url?embed_token=...`. A null token (mint off / failed) loads
    // the pane tokenless. Non-gated modules frame the URL directly.
    final Widget embedArea;
    if (moduleRequiresEmbedToken(widget.moduleId)) {
      // Side-effect channel for the proactive refresh: arm (or re-arm) the
      // timer whenever the provider settles on an actual token, cancel it if
      // a later settle comes back tokenless (mint went from working to off/
      // failed -- nothing left to refresh).
      ref.listen<AsyncValue<String?>>(
        embedTokenForModuleProvider(widget.moduleId),
        (previous, next) {
          final token = next.asData?.value;
          if (token != null) {
            _scheduleRefresh();
          } else {
            _refreshTimer?.cancel();
          }
        },
      );

      final tokenAsync = ref.watch(embedTokenForModuleProvider(widget.moduleId));
      embedArea = tokenAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        // Any fetch error still frames the pane tokenless (honest degrade).
        error: (_, _) => skcodeEmbed(url),
        data: (token) {
          final framedUrl =
              token == null ? url : widget._appendEmbedToken(url, token);
          // A changed url (a fresh token after a proactive refresh) must
          // actually reload the frame rather than Flutter reusing the old
          // platform view in place: keying the subtree by the framed url
          // forces a full unmount/remount of the embed on every url change.
          return KeyedSubtree(
            key: ValueKey(framedUrl),
            child: skcodeEmbed(framedUrl),
          );
        },
      );
    } else {
      embedArea = skcodeEmbed(url);
    }

    final spacing = Theme.of(context).extension<SovereignSpacing>();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: spacing?.gutter ?? 16,
            vertical: spacing?.rowVPad ?? 10,
          ),
          child: Row(
            children: [
              Icon(manifest.icon, size: 20),
              const SizedBox(width: 8),
              Text(
                manifest.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  manifest.description ?? 'Embedded SKWorld subapp',
                  style: Theme.of(context)
                      .extension<SovereignTypeExtras>()
                      ?.micro
                      .copyWith(color: subtle),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: embedArea),
      ],
    );
  }
}
