import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/build_info.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../../core/providers/theme_provider.dart';
import '../../services/backend_config.dart';
import '../../services/daemon_config.dart';
import '../../services/self_identity.dart';
import '../../services/self_identity_provider.dart';
import '../../services/skcomms_client.dart';
import '../../services/skcomms_sync.dart';
import '../identity/widgets/trust_badge.dart';
import 'widgets/capabilities_section.dart';
import 'widgets/operator_enrollment_section.dart';

// ── Local identity provider ────────────────────────────────────────────────
// Identity is fetched from the SKComms daemon at /api/v1/identity.
// Exposed as a Notifier so it can be updated at runtime.

class LocalIdentity {
  const LocalIdentity({
    this.displayName = 'You',
    this.fingerprint = '',
    this.pgpKeyId = '',
    this.pgpKeySize = 4096,
    this.daemonUrl = 'localhost:9384',
  });

  final String displayName;
  final String fingerprint;
  final String pgpKeyId;
  final int pgpKeySize;
  final String daemonUrl;

  LocalIdentity copyWith({
    String? displayName,
    String? fingerprint,
    String? pgpKeyId,
    int? pgpKeySize,
    String? daemonUrl,
  }) {
    return LocalIdentity(
      displayName: displayName ?? this.displayName,
      fingerprint: fingerprint ?? this.fingerprint,
      pgpKeyId: pgpKeyId ?? this.pgpKeyId,
      pgpKeySize: pgpKeySize ?? this.pgpKeySize,
      daemonUrl: daemonUrl ?? this.daemonUrl,
    );
  }
}

class LocalIdentityNotifier extends Notifier<LocalIdentity> {
  @override
  LocalIdentity build() {
    // Start with a placeholder, then fetch from daemon.
    Future.microtask(_fetchFromDaemon);
    return const LocalIdentity(
      displayName: 'Sovereign Node',
      daemonUrl: 'localhost:9384',
    );
  }

  /// Fetch identity from the SKComms daemon's /api/v1/identity endpoint.
  Future<void> _fetchFromDaemon() async {
    final client = ref.read(skcommsClientProvider);
    try {
      final alive = await client.isAlive();
      if (!alive) return;

      final info = await client.getIdentity();
      state = state.copyWith(
        displayName: info.name ?? state.displayName,
        fingerprint: info.fingerprint,
        pgpKeyId: info.fingerprint.length >= 8
            ? info.fingerprint.substring(info.fingerprint.length - 8)
            : info.fingerprint,
      );
    } catch (_) {
      // Daemon offline, keep placeholder.
    }
  }

  void update(LocalIdentity identity) => state = identity;

  /// Re-fetch identity from the daemon.
  Future<void> refresh() async => _fetchFromDaemon();
}

final localIdentityProvider =
    NotifierProvider<LocalIdentityNotifier, LocalIdentity>(
  LocalIdentityNotifier.new,
);

// ── Transport health provider ─────────────────────────────────────────────

final transportHealthProvider =
    Provider<List<({String name, bool active})>>((ref) {
  final daemon = ref.watch(skcommsSyncProvider);
  final info = daemon.transportInfo;
  if (info == null) return [];

  final transports = <({String name, bool active})>[];
  final raw = info['transports'];
  if (raw is Map) {
    for (final entry in raw.entries) {
      final active = (entry.value as Map?)?['available'] as bool? ?? false;
      transports.add((name: entry.key as String, active: active));
    }
  } else if (raw is List) {
    for (final t in raw) {
      if (t is Map) {
        transports.add((
          name: t['transport'] as String? ?? 'unknown',
          active: t['available'] as bool? ?? false,
        ));
      }
    }
  }
  if (transports.isEmpty && daemon.status == DaemonStatus.online) {
    transports.add((name: 'file', active: true));
  }
  return transports;
});

// ── Profile screen ─────────────────────────────────────────────────────────

/// Me / Profile / Settings screen.
/// Identity card with soul color + fingerprint, daemon health,
/// transport status, appearance settings, encryption keys, QR code login.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // THIS device's own identity + trust, never the operator's to a guest
    // (see SelfIdentity / selfIdentityProvider docs). Async: an operator
    // check + (for guests) a per-device identity load happen before this
    // resolves, so the header/trust tile render a compact placeholder until
    // it does.
    final selfAsync = ref.watch(selfIdentityProvider);
    final daemon = ref.watch(skcommsSyncProvider);
    final daemonUrl = ref.watch(daemonUrlProvider);
    final backendCfg = ref.watch(backendConfigProvider);
    final transports = ref.watch(transportHealthProvider);
    final themeMode = ref.watch(themeProvider);
    final soulColor = SovereignColors.fromFingerprint(
      selfAsync.valueOrNull?.fingerprint ?? '',
    );
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Me', style: tt.displayLarge?.copyWith(fontSize: 24)),
            Text(
              appBuildLabel,
              style: tt.bodySmall?.copyWith(
                fontSize: 11,
                color: tt.bodySmall?.color?.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_rounded),
            tooltip: 'QR Login',
            onPressed: () => context.push('/login/qr'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          // ── Identity card ────────────────────────────────────────────
          selfAsync.when(
            data: (me) => _IdentityHeader(me: me, soulColor: soulColor),
            loading: () => const _IdentityHeaderPlaceholder(),
            error: (_, _) => const _IdentityHeaderPlaceholder(),
          ),
          const SizedBox(height: 20),

          // ── Daemon & network health ──────────────────────────────────
          _SectionLabel(label: 'Network'),
          _DaemonStatusCard(daemon: daemon, transports: transports),
          const SizedBox(height: 20),

          // ── Services & transports (capability discovery) ─────────────
          // Fetched from {daemonBase}/api/v1/capabilities. Renders nothing
          // when the endpoint is missing/unreachable, so this only enriches
          // the daemon-online + transport summary above.
          const CapabilitiesSection(),

          // ── Encryption ──────────────────────────────────────────────
          _SectionLabel(label: 'Encryption'),
          selfAsync.maybeWhen(
            data: (me) => _EncryptionCard(me: me),
            orElse: () => const _EncryptionCardPlaceholder(),
          ),
          const SizedBox(height: 20),

          // ── Operator session ─────────────────────────────────────────
          // Enrolls THIS device's key so the app can obtain an operator
          // session for operator-gated daemon routes. Web-first (the
          // device key is only a real WebCrypto key on the web build).
          _SectionLabel(label: 'Operator'),
          const OperatorEnrollmentSection(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                key: const Key('linked-devices-entry'),
                leading: const Icon(Icons.devices_other_rounded),
                title: const Text('Linked Devices'),
                subtitle:
                    const Text('Manage every device linked to this operator'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(AppRoutes.linkedDevices),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Device recovery ──────────────────────────────────────────
          // Back up / restore THIS device's operator key as a 24-word BIP39
          // phrase. Native-only: the browser build cannot export its
          // (non-extractable) WebCrypto key, so the rows are hidden on web.
          if (!kIsWeb) ...[
            _SectionLabel(label: 'Device recovery'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.vpn_key_outlined),
                      title: const Text('Back up recovery phrase'),
                      subtitle: const Text('Reveal 24 words to restore later'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push(AppRoutes.recoveryPhrase),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.restore_rounded),
                      title: const Text('Restore from phrase'),
                      subtitle: const Text('Re-key this device from 24 words'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push(AppRoutes.restoreFromPhrase),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // ── Appearance ──────────────────────────────────────────────
          _SectionLabel(label: 'Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.dark_mode_rounded),
                    title: const Text('Dark mode'),
                    trailing: Switch(
                      value: themeMode == ThemeMode.dark,
                      onChanged: (v) {
                        if (v) {
                          ref.read(themeProvider.notifier).setDark();
                        } else {
                          ref.read(themeProvider.notifier).setLight();
                        }
                      },
                      activeColor: soulColor,
                    ),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('Soul color'),
                    subtitle: Text(
                      'Derived from fingerprint',
                      style: tt.labelSmall?.copyWith(
                        color: SovereignColors.textTertiary,
                      ),
                    ),
                    trailing: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: soulColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: soulColor.withValues(alpha: 0.4),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Quick actions ────────────────────────────────────────────
          _SectionLabel(label: 'Quick actions'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.widgets_outlined),
                    title: const Text('Modules'),
                    subtitle: const Text('Enable + place sub-apps'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push(AppRoutes.modules),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.dashboard_outlined),
                    title: const Text('Coordination Board'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push(AppRoutes.coord),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.how_to_reg_outlined),
                    title: const Text('Join requests'),
                    subtitle: const Text('Review + counter-sign peers (Mode C)'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push(AppRoutes.modeCReview),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.qr_code_scanner_rounded),
                    title: const Text('QR Login / Pair Device'),
                    subtitle: const Text('Show or scan a QR code'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push('/login/qr'),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.hub_outlined),
                    title: const Text('Instance'),
                    subtitle: Text(
                      _instanceLabel(backendCfg),
                      style: tt.labelSmall?.copyWith(
                        color: SovereignColors.textTertiary,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _showInstancePicker(context, ref, backendCfg),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.dns_rounded),
                    title: const Text('Server URL'),
                    subtitle: Text(
                      daemonUrl,
                      style: tt.labelSmall?.copyWith(
                        color: SovereignColors.textTertiary,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        _showServerUrlSetting(context, ref, daemonUrl),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.storage_outlined),
                    title: const Text('SKComms Daemon'),
                    subtitle: Text(
                      daemonUrl,
                      style: tt.labelSmall?.copyWith(
                        color: SovereignColors.textTertiary,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _showDaemonSettings(context, ref, daemonUrl),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── About ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('About SKChat'),
                subtitle: const Text('Sovereign P2P messaging'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {},
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Prominent, discoverable "Server URL" setting. This is a second, more
  /// visible entry point to the exact same apply the buried instance-picker
  /// "Custom host" field already performs (see [_showInstancePicker]): it
  /// repoints the SKComms daemon URL *and* the Spaces/LiveKit/skcapstone
  /// backends, then re-fetches identity from the new host. It does not
  /// replace the instance picker or the standalone daemon-only setting.
  void _showServerUrlSetting(
    BuildContext context,
    WidgetRef ref,
    String currentUrl,
  ) {
    final controller = TextEditingController(text: currentUrl);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('Server URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The server this app connects to (chat, calls, spaces). '
              'No app rebuild needed.',
              style: TextStyle(
                fontSize: 12,
                color: SovereignColors.textTertiary,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('server-url-field'),
              controller: controller,
              autofocus: true,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 14,
                color: SovereignColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'https://host.tailnet.ts.net',
                hintStyle:
                    const TextStyle(color: SovereignColors.textTertiary),
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
                filled: true,
                fillColor: SovereignColors.surfaceGlass,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: SovereignColors.textTertiary),
            ),
          ),
          FilledButton(
            onPressed: () {
              final host = controller.text.trim();
              if (host.isNotEmpty) {
                // Same apply as the instance-picker's custom-host field:
                // repoint the daemon, derive the rest, re-fetch identity.
                ref.read(daemonUrlProvider.notifier).setUrl(host);
                ref.read(backendConfigProvider.notifier).setCustomHost(host);
                ref.read(localIdentityProvider.notifier).refresh();
              }
              Navigator.of(ctx).pop();
            },
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.soulLumina,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDaemonSettings(
    BuildContext context,
    WidgetRef ref,
    String currentUrl,
  ) {
    final controller = TextEditingController(text: currentUrl);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SKComms Daemon URL',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'On native this is your local daemon. In a browser, point this at '
              'a network-reachable daemon (e.g. a tailnet host) with CORS '
              'enabled, localhost is this device, which has no daemon.',
              style: TextStyle(
                fontSize: 12,
                color: SovereignColors.textTertiary,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 14,
                color: SovereignColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'localhost:9384',
                hintStyle:
                    const TextStyle(color: SovereignColors.textTertiary),
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
                filled: true,
                fillColor: SovereignColors.surfaceGlass,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                // Persist + rebuild every daemon-facing client.
                ref
                    .read(daemonUrlProvider.notifier)
                    .setUrl(controller.text.trim());
                // Re-fetch identity from the (possibly new) daemon.
                ref.read(localIdentityProvider.notifier).refresh();
                Navigator.of(ctx).pop();
              },
              style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.soulLumina,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Save'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                // Reset to the compile-time default.
                ref.read(daemonUrlProvider.notifier).setUrl('');
                ref.read(localIdentityProvider.notifier).refresh();
                Navigator.of(ctx).pop();
              },
              child: const Text(
                'Reset to default',
                style: TextStyle(color: SovereignColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Short label for the currently-selected backend instance.
  String _instanceLabel(BackendConfig cfg) {
    final preset = presetById(cfg.instanceId);
    if (preset != null) return preset.label;
    if (cfg.instanceId == 'default') return 'Build default';
    return 'Custom · ${cfg.skchatWebuiUrl}';
  }

  /// Instance picker, selecting a preset repoints ALL backends (the SKComms
  /// daemon URL *and* the Spaces/LiveKit/skcapstone base URLs) live and
  /// persists them. A custom field repoints them to an arbitrary host.
  void _showInstancePicker(
    BuildContext context,
    WidgetRef ref,
    BackendConfig cfg,
  ) {
    final customController =
        TextEditingController(text: cfg.skchatWebuiUrl);

    void applyPreset(BackendPreset preset) {
      // 1. Repoint the SKComms daemon URL.
      ref.read(daemonUrlProvider.notifier).setUrl(preset.daemonUrl);
      // 2. Repoint Spaces/LiveKit/skcapstone backends.
      ref.read(backendConfigProvider.notifier).applyPreset(preset);
      // 3. Re-fetch identity from the (new) daemon.
      ref.read(localIdentityProvider.notifier).refresh();
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Instance',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Switch which sovereign node this app federates with. A preset '
              'repoints every backend at once, the SKComms daemon, the SK '
              'Spaces / LiveKit web-UI, the LiveKit SFU, and skcapstone.',
              style: TextStyle(
                fontSize: 12,
                color: SovereignColors.textTertiary,
              ),
            ),
            const SizedBox(height: 16),
            for (final preset in kBackendPresets)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  preset.id == cfg.instanceId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: preset.id == cfg.instanceId
                      ? SovereignColors.soulLumina
                      : SovereignColors.textTertiary,
                ),
                title: Text(
                  preset.label,
                  style: const TextStyle(
                    color: SovereignColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  preset.config.skchatWebuiUrl,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: SovereignColors.textTertiary,
                  ),
                ),
                onTap: () {
                  applyPreset(preset);
                  Navigator.of(ctx).pop();
                },
              ),
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
              controller: customController,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 14,
                color: SovereignColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'https://host.tailnet.ts.net',
                hintStyle:
                    const TextStyle(color: SovereignColors.textTertiary),
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
                filled: true,
                fillColor: SovereignColors.surfaceGlass,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final host = customController.text.trim();
                if (host.isNotEmpty) {
                  // Point the daemon at the same host, then derive the rest.
                  ref.read(daemonUrlProvider.notifier).setUrl(host);
                  ref
                      .read(backendConfigProvider.notifier)
                      .setCustomHost(host);
                  ref.read(localIdentityProvider.notifier).refresh();
                }
                Navigator.of(ctx).pop();
              },
              style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.soulLumina,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Use custom host'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                // Reset every backend to its compile-time default.
                ref.read(daemonUrlProvider.notifier).setUrl('');
                ref.read(backendConfigProvider.notifier).reset();
                ref.read(localIdentityProvider.notifier).refresh();
                Navigator.of(ctx).pop();
              },
              child: const Text(
                'Reset to build defaults',
                style: TextStyle(color: SovereignColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Identity header ────────────────────────────────────────────────────────

/// Compact placeholder shown while [selfIdentityProvider] resolves (an
/// operator-session check, and for guests a per-device identity load).
class _IdentityHeaderPlaceholder extends StatelessWidget {
  const _IdentityHeaderPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GlassCard(
        child: SizedBox(
          height: 64,
          child: Center(
            child: Text(
              'Loading identity...',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: SovereignColors.textTertiary,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.me, required this.soulColor});

  /// THIS device's own identity + trust tier (never the operator's, unless
  /// this device IS the enrolled operator).
  final SelfIdentity me;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GlassCard(
        child: Column(
          children: [
            // Soul-color gradient bar
            Container(
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(
                  colors: [
                    soulColor.withValues(alpha: 0.8),
                    soulColor.withValues(alpha: 0.2),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                SoulAvatar(
                  soulColor: soulColor,
                  initials: me.displayName.isNotEmpty
                      ? me.displayName[0].toUpperCase()
                      : 'S',
                  isOnline: true,
                  size: 64,
                  ringWidth: 3,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        me.displayName,
                        style: tt.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          // Encryption is orthogonal to trust tier, this
                          // stays regardless of whether `me` is the
                          // operator or a red guest.
                          const EncryptBadge(size: 12),
                          const SizedBox(width: 4),
                          Text(
                            me.isOperator
                                ? 'CapAuth Identity'
                                : 'Self-Asserted Identity',
                            style: tt.labelSmall?.copyWith(
                              color: me.isOperator
                                  ? SovereignColors.accentEncrypt
                                  : SovereignColors.accentWarning,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (me.fingerprint.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(
                height: 1,
                color: SovereignColors.surfaceGlassBorder,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.fingerprint_rounded,
                    size: 14,
                    color: SovereignColors.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Fingerprint',
                    style: tt.labelSmall?.copyWith(
                      color: SovereignColors.textTertiary,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(text: me.fingerprint),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Fingerprint copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    child: const Icon(
                      Icons.copy_rounded,
                      size: 14,
                      color: SovereignColors.textTertiary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _formatFingerprint(me.fingerprint),
                style: tt.labelSmall?.copyWith(
                  fontFamily: 'JetBrainsMono',
                  color: soulColor.withValues(alpha: 0.9),
                  fontSize: 11,
                  letterSpacing: 1.0,
                ),
              ),
            ],
            if (me.degraded) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: SovereignColors.accentWarning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'This identity is temporary and will not survive a '
                      'reload (storage is blocked in this browser).',
                      style: tt.labelSmall?.copyWith(
                        color: SovereignColors.accentWarning,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatFingerprint(String fp) {
    if (fp.length < 8) return fp;
    final clean = fp.replaceAll(' ', '').toUpperCase();
    final groups = <String>[];
    for (int i = 0; i < clean.length; i += 4) {
      groups.add(clean.substring(i, (i + 4).clamp(0, clean.length)));
    }
    return groups.join(' ');
  }
}

// ── Daemon status card ─────────────────────────────────────────────────────

class _DaemonStatusCard extends StatelessWidget {
  const _DaemonStatusCard({
    required this.daemon,
    required this.transports,
  });

  final DaemonState daemon;
  final List<({String name, bool active})> transports;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final (statusLabel, statusColor, statusIcon) = switch (daemon.status) {
      DaemonStatus.online => (
          'Online',
          SovereignColors.accentEncrypt,
          Icons.circle,
        ),
      DaemonStatus.offline => (
          'Offline',
          SovereignColors.accentDanger,
          Icons.circle,
        ),
      DaemonStatus.error => (
          'Error',
          SovereignColors.accentWarning,
          Icons.warning_rounded,
        ),
      DaemonStatus.connecting => (
          'Connecting',
          SovereignColors.textTertiary,
          Icons.circle,
        ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GlassCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(statusIcon, size: 10, color: statusColor),
                const SizedBox(width: 8),
                Text(
                  'SKComms Daemon · $statusLabel',
                  style: tt.titleSmall?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (daemon.lastPollAt != null)
                  Text(
                    _lastPollText(daemon.lastPollAt!),
                    style: tt.labelSmall?.copyWith(
                      color: SovereignColors.textTertiary,
                    ),
                  ),
              ],
            ),
            if (daemon.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                daemon.errorMessage!,
                style: tt.bodySmall?.copyWith(
                  color: SovereignColors.accentWarning,
                ),
              ),
            ],
            if (transports.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: transports
                    .map((t) => _TransportChip(name: t.name, active: t.active))
                    .toList(),
              ),
            ] else if (daemon.status == DaemonStatus.online) ...[
              const SizedBox(height: 8),
              Text(
                'Encrypted P2P transport active',
                style: tt.bodySmall?.copyWith(
                  color: SovereignColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _lastPollText(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 10) return 'just now';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
    return '${diff.inMinutes}m ago';
  }
}

class _TransportChip extends StatelessWidget {
  const _TransportChip({required this.name, required this.active});

  final String name;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color =
        active ? SovereignColors.accentEncrypt : SovereignColors.textTertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            active
                ? Icons.check_circle_outline
                : Icons.radio_button_unchecked,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            name,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Encryption card ────────────────────────────────────────────────────────

/// Compact placeholder shown while [selfIdentityProvider] resolves (or
/// errors), matching [_IdentityHeaderPlaceholder]. The Trust Level tile
/// depends on `me.isOperator`, so it has nothing to render until that
/// resolves.
class _EncryptionCardPlaceholder extends StatelessWidget {
  const _EncryptionCardPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GlassCard(
        child: SizedBox(
          height: 64,
          child: Center(
            child: Text(
              'Loading trust status...',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: SovereignColors.textTertiary,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EncryptionCard extends StatelessWidget {
  const _EncryptionCard({required this.me});

  /// THIS device's own identity + trust tier. The PGP Key tile only makes
  /// sense for the operator (green), a red guest has no operator key and
  /// must never be shown one, so it (and key rotation, which acts on that
  /// same key) is gated behind [SelfIdentity.isOperator].
  final SelfIdentity me;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final trustSubtitle = me.isOperator
        ? 'Full trust, self-sovereign'
        : 'Self-asserted identity, not sovereign-verified';
    final trustLabel = me.isOperator ? 'Sovereign' : 'Untrusted';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            if (me.isOperator) ...[
              ListTile(
                leading: const Icon(
                  Icons.key_rounded,
                  color: SovereignColors.accentEncrypt,
                ),
                title: const Text('PGP Key'),
                subtitle: Text(
                  'RSA ${me.pgpKeySize}-bit · ID: ${me.pgpKeyId}',
                  style: tt.labelSmall?.copyWith(
                    fontFamily: 'JetBrainsMono',
                    color: SovereignColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
                trailing: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color:
                        SovereignColors.accentEncrypt.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Active',
                    style: tt.labelSmall?.copyWith(
                      color: SovereignColors.accentEncrypt,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1, indent: 56),
            ],
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Trust Level'),
              subtitle: Text(trustSubtitle),
              trailing: TrustBadge(tier: me.tier, label: trustLabel),
              onTap: () {},
            ),
            if (me.isOperator) ...[
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.rotate_right_rounded),
                title: const Text('Rotate Keys'),
                subtitle: const Text('Generate new PGP keypair'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Key rotation, coming soon'),
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Section label ──────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: SovereignColors.textTertiary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
