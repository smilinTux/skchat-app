import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Runtime-settable configuration for the *non-daemon* backends:
///   - the SKChat web-UI (Spaces API + LiveKit token mint),
///   - the LiveKit SFU WebSocket URL,
///   - the LiveKit web-UI token endpoint, and
///   - the skcapstone daemon + dashboard.
///
/// Mirrors the pattern of [DaemonConfigNotifier] in `daemon_config.dart`:
/// a [Notifier] holding the live config, persisted in the shared `settings`
/// Hive box, exposed through a [NotifierProvider]. The service providers
/// (`spacesServiceProvider`, `liveKitCallServiceProvider`,
/// `skCapstoneClientProvider`) *watch* this so a single user setting repoints
/// every non-daemon backend live, surviving app restarts / web reloads.
///
/// The defaults are seeded from the same compile-time `String.fromEnvironment`
/// values the services used before, so existing builds are unaffected until the
/// user picks an instance in the Profile screen.

// ── Compile-time default seeds (unchanged build-time behaviour) ──────────────

/// SKChat web-UI base URL — serves `/spaces` + `/livekit/token`.
const kDefaultSkchatWebuiUrl = String.fromEnvironment(
  'SKCHAT_WEBUI_URL',
  defaultValue: 'https://noroc2027.tail204f0c.ts.net',
);

/// LiveKit web-UI token-mint base URL.
const kDefaultLivekitWebuiUrl = String.fromEnvironment(
  'LIVEKIT_WEBUI_URL',
  defaultValue: 'http://localhost:7779',
);

/// LiveKit SFU WebSocket URL.
const kDefaultLivekitUrl = String.fromEnvironment(
  'LIVEKIT_URL',
  defaultValue: 'wss://localhost:8443',
);

/// skcapstone daemon REST base URL (port 7777).
const kDefaultSkcapstoneUrl = String.fromEnvironment(
  'SKCAPSTONE_URL',
  defaultValue: 'http://localhost:7777',
);

/// skcapstone dashboard base URL (port 7778).
const kDefaultSkcapstoneDashboardUrl = String.fromEnvironment(
  'SKCAPSTONE_DASHBOARD_URL',
  defaultValue: 'http://localhost:7778',
);

// ── Hive persistence keys (shared `settings` box) ────────────────────────────

const _kSettingsBox = 'settings';
const _kSkchatWebuiKey = 'backend_skchat_webui_url';
const _kLivekitWebuiKey = 'backend_livekit_webui_url';
const _kLivekitUrlKey = 'backend_livekit_url';
const _kSkcapstoneKey = 'backend_skcapstone_url';
const _kSkcapstoneDashKey = 'backend_skcapstone_dashboard_url';
const _kInstanceIdKey = 'backend_instance_id';

/// Strip a trailing slash so paths can be appended cleanly.
String _stripTrailingSlash(String s) {
  var out = s.trim();
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

// ── Config value object ──────────────────────────────────────────────────────

/// Immutable snapshot of all non-daemon backend base URLs plus the id of the
/// preset that produced them (or `'custom'`).
class BackendConfig {
  const BackendConfig({
    required this.skchatWebuiUrl,
    required this.livekitWebuiUrl,
    required this.livekitUrl,
    required this.skcapstoneUrl,
    required this.skcapstoneDashboardUrl,
    this.instanceId = 'custom',
  });

  /// SKChat web-UI base (Spaces API + LiveKit token mint).
  final String skchatWebuiUrl;

  /// LiveKit web-UI token-mint base.
  final String livekitWebuiUrl;

  /// LiveKit SFU WebSocket URL.
  final String livekitUrl;

  /// skcapstone daemon REST base.
  final String skcapstoneUrl;

  /// skcapstone dashboard base.
  final String skcapstoneDashboardUrl;

  /// Id of the matching [BackendPreset], or `'custom'`.
  final String instanceId;

  /// The compile-time default config (current build-time behaviour).
  static const BackendConfig defaults = BackendConfig(
    skchatWebuiUrl: kDefaultSkchatWebuiUrl,
    livekitWebuiUrl: kDefaultLivekitWebuiUrl,
    livekitUrl: kDefaultLivekitUrl,
    skcapstoneUrl: kDefaultSkcapstoneUrl,
    skcapstoneDashboardUrl: kDefaultSkcapstoneDashboardUrl,
    instanceId: 'default',
  );

  BackendConfig copyWith({
    String? skchatWebuiUrl,
    String? livekitWebuiUrl,
    String? livekitUrl,
    String? skcapstoneUrl,
    String? skcapstoneDashboardUrl,
    String? instanceId,
  }) {
    return BackendConfig(
      skchatWebuiUrl: skchatWebuiUrl ?? this.skchatWebuiUrl,
      livekitWebuiUrl: livekitWebuiUrl ?? this.livekitWebuiUrl,
      livekitUrl: livekitUrl ?? this.livekitUrl,
      skcapstoneUrl: skcapstoneUrl ?? this.skcapstoneUrl,
      skcapstoneDashboardUrl:
          skcapstoneDashboardUrl ?? this.skcapstoneDashboardUrl,
      instanceId: instanceId ?? this.instanceId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BackendConfig &&
      other.skchatWebuiUrl == skchatWebuiUrl &&
      other.livekitWebuiUrl == livekitWebuiUrl &&
      other.livekitUrl == livekitUrl &&
      other.skcapstoneUrl == skcapstoneUrl &&
      other.skcapstoneDashboardUrl == skcapstoneDashboardUrl &&
      other.instanceId == instanceId;

  @override
  int get hashCode => Object.hash(
        skchatWebuiUrl,
        livekitWebuiUrl,
        livekitUrl,
        skcapstoneUrl,
        skcapstoneDashboardUrl,
        instanceId,
      );
}

// ── Presets (federation instances) ───────────────────────────────────────────

/// A named instance preset that repoints *every* backend — including the
/// SKComms daemon URL (applied via `daemon_config.dart`) — to one host.
class BackendPreset {
  const BackendPreset({
    required this.id,
    required this.label,
    required this.daemonUrl,
    required this.config,
  });

  /// Stable id stored in Hive (e.g. `lumina`, `jarvis`).
  final String id;

  /// Human-facing label for the picker.
  final String label;

  /// SKComms daemon URL for this instance (fed to `daemonUrlProvider`).
  final String daemonUrl;

  /// All non-daemon backend URLs for this instance.
  final BackendConfig config;
}

/// Built-in federation instances.
///
/// `lumina` is the current tailnet default (`noroc2027` @ 192.168.0.158).
/// `jarvis` is the laptop host (`cbrd21-laptop12thgenintelcore` @
/// 192.168.0.41) — its MagicDNS name on the `tail204f0c` tailnet.
const List<BackendPreset> kBackendPresets = [
  BackendPreset(
    id: 'lumina',
    label: 'lumina @ .158',
    daemonUrl: 'https://noroc2027.tail204f0c.ts.net',
    config: BackendConfig(
      instanceId: 'lumina',
      skchatWebuiUrl: 'https://noroc2027.tail204f0c.ts.net',
      livekitWebuiUrl: 'https://noroc2027.tail204f0c.ts.net',
      livekitUrl: 'wss://noroc2027.tail204f0c.ts.net:8443',
      skcapstoneUrl: 'http://noroc2027.tail204f0c.ts.net:7777',
      skcapstoneDashboardUrl: 'http://noroc2027.tail204f0c.ts.net:7778',
    ),
  ),
  BackendPreset(
    id: 'jarvis',
    label: 'jarvis @ .41',
    daemonUrl: 'https://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net',
    config: BackendConfig(
      instanceId: 'jarvis',
      skchatWebuiUrl:
          'https://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net',
      livekitWebuiUrl:
          'https://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net',
      livekitUrl:
          'wss://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net:8443',
      skcapstoneUrl:
          'http://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net:7777',
      skcapstoneDashboardUrl:
          'http://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net:7778',
    ),
  ),
];

/// Look up a preset by id, or null if it is `custom`/unknown.
BackendPreset? presetById(String id) {
  for (final p in kBackendPresets) {
    if (p.id == id) return p;
  }
  return null;
}

// ── Notifier ─────────────────────────────────────────────────────────────────

/// Reactive holder for the non-daemon backend config.
///
/// Seeds from the compile-time defaults, then asynchronously loads any
/// persisted override from the shared `settings` Hive box.
class BackendConfigNotifier extends Notifier<BackendConfig> {
  @override
  BackendConfig build() {
    _loadPersisted();
    return BackendConfig.defaults;
  }

  Future<void> _loadPersisted() async {
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      final loaded = BackendConfig(
        instanceId: box.get(_kInstanceIdKey) ?? state.instanceId,
        skchatWebuiUrl: box.get(_kSkchatWebuiKey) ?? state.skchatWebuiUrl,
        livekitWebuiUrl: box.get(_kLivekitWebuiKey) ?? state.livekitWebuiUrl,
        livekitUrl: box.get(_kLivekitUrlKey) ?? state.livekitUrl,
        skcapstoneUrl: box.get(_kSkcapstoneKey) ?? state.skcapstoneUrl,
        skcapstoneDashboardUrl:
            box.get(_kSkcapstoneDashKey) ?? state.skcapstoneDashboardUrl,
      );
      if (loaded != state) state = loaded;
    } catch (_) {
      // Hive unavailable — keep the compile-time defaults.
    }
  }

  Future<void> _persist(BackendConfig c) async {
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      await box.put(_kInstanceIdKey, c.instanceId);
      await box.put(_kSkchatWebuiKey, c.skchatWebuiUrl);
      await box.put(_kLivekitWebuiKey, c.livekitWebuiUrl);
      await box.put(_kLivekitUrlKey, c.livekitUrl);
      await box.put(_kSkcapstoneKey, c.skcapstoneUrl);
      await box.put(_kSkcapstoneDashKey, c.skcapstoneDashboardUrl);
    } catch (_) {
      // Best-effort persistence; in-memory state already updated.
    }
  }

  /// Apply a [BackendPreset] (repoints all non-daemon backends) and persist.
  ///
  /// NOTE: the SKComms daemon URL must be repointed separately by the caller
  /// via `daemonUrlProvider` — the picker UI does both atomically.
  Future<void> applyPreset(BackendPreset preset) => setConfig(preset.config);

  /// Replace the whole config and persist it.
  Future<void> setConfig(BackendConfig config) async {
    final normalized = BackendConfig(
      instanceId: config.instanceId,
      skchatWebuiUrl: _stripTrailingSlash(config.skchatWebuiUrl),
      livekitWebuiUrl: _stripTrailingSlash(config.livekitWebuiUrl),
      livekitUrl: _stripTrailingSlash(config.livekitUrl),
      skcapstoneUrl: _stripTrailingSlash(config.skcapstoneUrl),
      skcapstoneDashboardUrl: _stripTrailingSlash(config.skcapstoneDashboardUrl),
    );
    state = normalized;
    await _persist(normalized);
  }

  /// Set a single custom SKChat web-UI host while marking the instance custom.
  ///
  /// Derives the LiveKit/skcapstone URLs from the same host so a bare host
  /// entry repoints the whole stack. Pass a full `scheme://host[:port]`.
  Future<void> setCustomHost(String rawBase) async {
    final base = _stripTrailingSlash(rawBase);
    // Derive ws scheme + host for the SFU.
    String wsBase;
    String host;
    if (base.startsWith('https://')) {
      host = base.substring('https://'.length);
      wsBase = 'wss://$host';
    } else if (base.startsWith('http://')) {
      host = base.substring('http://'.length);
      wsBase = 'ws://$host';
    } else {
      host = base;
      wsBase = 'wss://$host';
    }
    // Strip any port the user typed off the host for the port-specific URLs.
    final hostNoPort = host.contains(':') ? host.split(':').first : host;
    await setConfig(
      BackendConfig(
        instanceId: 'custom',
        skchatWebuiUrl: base,
        livekitWebuiUrl: base,
        livekitUrl: '$wsBase:8443',
        skcapstoneUrl: 'http://$hostNoPort:7777',
        skcapstoneDashboardUrl: 'http://$hostNoPort:7778',
      ),
    );
  }

  /// Reset to the compile-time defaults and clear persisted overrides.
  Future<void> reset() async {
    state = BackendConfig.defaults;
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      await box.delete(_kInstanceIdKey);
      await box.delete(_kSkchatWebuiKey);
      await box.delete(_kLivekitWebuiKey);
      await box.delete(_kLivekitUrlKey);
      await box.delete(_kSkcapstoneKey);
      await box.delete(_kSkcapstoneDashKey);
    } catch (_) {
      // Best-effort.
    }
  }
}

/// Live backend config. Watch this to rebuild backend clients on change.
final backendConfigProvider =
    NotifierProvider<BackendConfigNotifier, BackendConfig>(
  BackendConfigNotifier.new,
);
