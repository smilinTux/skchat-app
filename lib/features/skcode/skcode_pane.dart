import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/audience_token_service.dart';
import '../../services/daemon_config.dart';
import 'skcode_web_embed_stub.dart'
    if (dart.library.html) 'skcode_web_embed.dart';

/// The capauth audience the hostd client's read routes and WS tail are scoped
/// to (matches skcode-hostd's `SKCODE_AUDIENCE` / module manifest `audience`).
const String kSkcodeAudience = 'skcode';

/// The "Code" section of the SKWorld shell (reconciled spec R4.1/R4.7).
///
/// skcode is folded in at Grade B: this pane embeds skcode-hostd's web client
/// same-origin over the 443 funnel (`<origin>/skcode/app`, proxied to the
/// tailnet-only host so no browser call leaves 443). Grade A (a native
/// `skcode_client` module consuming the WS stream) replaces the embed later.
///
/// AUTH (audience token). Once hostd's verifier is enabled (`SKCODE_REAL_
/// VERIFIER`) its read routes and WS tail reject any call without a capauth
/// wire token scoped to audience `skcode`. The iframe cannot set an
/// `Authorization` header itself, so this pane mints that token from the
/// authenticated backend (`POST /api/v1/audience-token`, ridden by the
/// operator-session Bearer) via [audienceTokenForAudienceProvider] and appends
/// it to the client URL as `?token=<wire>`. The hostd client reads it from its
/// own URL and attaches it as `Authorization: Bearer` on HTTP and `?token=` on
/// the WS tail.
///
/// It degrades honestly: while the token mint is resolving the header shows but
/// the embed area holds a spinner; if minting is off (`SKCHAT_AUDIENCE_MINT`
/// unset) or fails, the token is null and the client loads tokenless, showing
/// hostd's own gated empty state rather than crashing.
class SkcodePane extends ConsumerWidget {
  const SkcodePane({super.key});

  /// Append the audience wire token to the hostd client URL as a query param,
  /// preserving any existing query string. The hostd client reads `?token=`
  /// from its own URL and forwards it as `Authorization: Bearer` (HTTP) and
  /// `?token=` (WS).
  String _appendToken(String url, String token) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}token=${Uri.encodeQueryComponent(token)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final origin = ref.watch(daemonUrlProvider).replaceAll(RegExp(r'/+$'), '');
    final baseUrl = '$origin/skcode/app';
    final subtle = Theme.of(context).textTheme.bodySmall?.color;

    // Mint (or reuse the cached) audience=skcode wire token, then frame
    // `baseUrl?token=...`. A null token (mint off / failed) frames the URL
    // tokenless so hostd shows its own gated response.
    final tokenAsync = ref.watch(audienceTokenForAudienceProvider(kSkcodeAudience));
    final Widget embedArea = tokenAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      // A mint error still frames the pane tokenless (honest degrade).
      error: (_, _) => skcodeEmbed(baseUrl),
      data: (token) => skcodeEmbed(
        token == null ? baseUrl : _appendToken(baseUrl, token),
      ),
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.terminal_rounded, size: 20),
              const SizedBox(width: 8),
              const Text('Code', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'start, watch, and steer agent sessions',
                  style: TextStyle(fontSize: 12, color: subtle),
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
