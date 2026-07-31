import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/daemon_config.dart';
import 'skcode_web_embed_stub.dart'
    if (dart.library.html) 'skcode_web_embed.dart';

/// The "Code" section of the SKWorld shell (reconciled spec R4.1/R4.7).
///
/// skcode is folded in at Grade B: this pane embeds skcode-hostd's web client
/// same-origin over the 443 funnel (`<origin>/skcode/app`, proxied to the
/// tailnet-only host so no browser call leaves 443). skcode-hostd is deny-all
/// until this device is paired, so the client renders but its session data
/// stays gated. That is shown as a hint, never a crash. Grade A (a native
/// `skcode_client` module consuming the WS stream) replaces the embed later.
class SkcodePane extends ConsumerWidget {
  const SkcodePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final origin = ref.watch(daemonUrlProvider).replaceAll(RegExp(r'/+$'), '');
    final url = '$origin/skcode/app';
    final subtle = Theme.of(context).textTheme.bodySmall?.color;
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
                  'read-only until this device is paired with the code host',
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
