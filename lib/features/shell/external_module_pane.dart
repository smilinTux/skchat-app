import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/modules/external_modules.dart';
import '../../services/daemon_config.dart';
// Reuse the exact conditional-import embed the Code pane uses: an iframe on
// web, a host-URL fallback on native. One URL in, one embed out.
import '../skcode/skcode_web_embed_stub.dart'
    if (dart.library.html) '../skcode/skcode_web_embed.dart';

/// Host pane for a DISCOVERED external subapp module (card e378d895).
///
/// Resolves the manifest for [moduleId] from [externalModuleByIdProvider] and
/// renders its Grade B web surface embedded over the 443 funnel (same pattern
/// as [SkcodePane]). Grade A native panes are NOT built here (that is a later
/// phase); every discovered subapp is embedded.
///
/// It degrades honestly: while discovery is still resolving it shows a spinner,
/// and if the id is unknown (discovery off, failed, or a stale deep link) it
/// shows a plain "not available" message rather than crashing.
class ExternalModulePane extends ConsumerWidget {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final external = ref.watch(externalModulesProvider);
    final manifest = ref.watch(externalModuleByIdProvider(moduleId));
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
    final url = _resolveUrl(manifest.externalEntryUrl ?? '', origin);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                  style: TextStyle(fontSize: 12, color: subtle),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: skcodeEmbed(url)),
      ],
    );
  }
}
