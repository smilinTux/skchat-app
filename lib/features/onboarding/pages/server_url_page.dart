import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/sovereign_colors.dart';
import '../../../core/theme/glass_widgets.dart';
import '../../../services/backend_config.dart';
import '../../../services/daemon_config.dart';
import '../../profile/profile_screen.dart' show localIdentityProvider;

/// Onboarding step 2: pick the sovereign instance / server this device talks
/// to.
///
/// Reuses the EXACT same applies as the Profile screen's instance picker and
/// "Server URL" setting, no new wiring: choosing a preset repoints every
/// backend atomically ([BackendConfigNotifier.applyPreset] + the daemon URL);
/// a custom host derives the whole stack from one URL
/// ([BackendConfigNotifier.setCustomHost]). Both persist through Hive, so the
/// choice survives restarts and, via the router's refreshListenable, clears
/// the first-run gate. The Continue button unlocks once a non-empty SKChat
/// web-UI URL is configured.
class ServerUrlPage extends ConsumerStatefulWidget {
  const ServerUrlPage({super.key, this.onNext});

  final VoidCallback? onNext;

  @override
  ConsumerState<ServerUrlPage> createState() => _ServerUrlPageState();
}

class _ServerUrlPageState extends ConsumerState<ServerUrlPage> {
  late final TextEditingController _customController;

  @override
  void initState() {
    super.initState();
    _customController = TextEditingController();
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _applyPreset(BackendPreset preset) {
    ref.read(daemonUrlProvider.notifier).setUrl(preset.daemonUrl);
    ref.read(backendConfigProvider.notifier).applyPreset(preset);
    ref.read(localIdentityProvider.notifier).refresh();
  }

  void _applyCustomHost() {
    final host = _customController.text.trim();
    if (host.isEmpty) return;
    // Same apply as the Profile "Server URL" setting: repoint the daemon,
    // derive the rest, re-fetch identity from the new host.
    ref.read(daemonUrlProvider.notifier).setUrl(host);
    ref.read(backendConfigProvider.notifier).setCustomHost(host);
    ref.read(localIdentityProvider.notifier).refresh();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(backendConfigProvider);
    final configured = cfg.skchatWebuiUrl.trim().isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            const Text(
              'Choose Your Server',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: SovereignColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pick a sovereign instance, or point this app at your own '
              'host. You can change it any time in Settings.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: SovereignColors.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            Expanded(
              child: ListView(
                children: [
                  for (final preset in kBackendPresets) ...[
                    _PresetCard(
                      label: preset.label,
                      host: preset.daemonUrl,
                      selected: preset.id == cfg.instanceId,
                      onTap: () => _applyPreset(preset),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'Custom host',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: SovereignColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('onboarding-custom-host-field'),
                    controller: _customController,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 14,
                      color: SovereignColors.textPrimary,
                    ),
                    onSubmitted: (_) => _applyCustomHost(),
                    decoration: InputDecoration(
                      hintText: 'https://host.tailnet.ts.net',
                      hintStyle:
                          const TextStyle(color: SovereignColors.textTertiary),
                      filled: true,
                      fillColor: SovereignColors.surfaceGlass,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: SovereignColors.surfaceGlassBorder,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: SovereignColors.soulLumina,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const Key('onboarding-use-custom-host'),
                      onPressed: _applyCustomHost,
                      child: const Text('Use this server'),
                    ),
                  ),
                ],
              ),
            ),
            if (configured) ...[
              GlassCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle,
                      size: 18,
                      color: SovereignColors.accentEncrypt,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        cfg.skchatWebuiUrl,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12,
                          color: SovereignColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton(
              onPressed: configured ? widget.onNext : null,
              style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.soulLumina,
                foregroundColor: Colors.black,
                disabledBackgroundColor: SovereignColors.surfaceGlass,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Continue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.label,
    required this.host,
    required this.selected,
    this.onTap,
  });

  final String label;
  final String host;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      opacity: selected ? 0.12 : 0.06,
      borderOpacity: selected ? 0.25 : 0.08,
      onTap: onTap,
      child: Row(
        children: [
          const Icon(
            Icons.dns_rounded,
            size: 22,
            color: SovereignColors.soulLumina,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: SovereignColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  host,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: SovereignColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (selected)
            const Icon(
              Icons.check_circle,
              color: SovereignColors.accentEncrypt,
              size: 20,
            ),
        ],
      ),
    );
  }
}
