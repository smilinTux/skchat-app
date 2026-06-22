import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Compile-time default for the SKComms daemon base URL.
///
/// Override at build time with:
///   flutter build web --release \
///     --dart-define=SKCOMMS_URL=https://daemon-host.tail-net.ts.net
///
/// For a NATIVE app on a machine that runs the daemon locally, the default
/// `http://localhost:9384` is correct.  For a WEB build served to a browser
/// on a *different* device (e.g. over the tailnet), `localhost` resolves to
/// the user's own device — which has no daemon — so the URL MUST point at a
/// network-reachable daemon (a tailnet host) with CORS enabled.
const kDefaultDaemonUrl = String.fromEnvironment(
  'SKCOMMS_URL',
  defaultValue: 'http://localhost:9384',
);

/// Hive box + key used to persist a user-supplied daemon URL override.
const _kSettingsBox = 'settings';
const _kDaemonUrlKey = 'skcomms_daemon_url';

/// Initial daemon URL before any persisted override is loaded.
///
/// Precedence: explicit build-time `SKCOMMS_URL` → on web, the SAME host the
/// app was served from (so LAN IP / tailnet IP / MagicDNS all work without
/// reconfiguration) → compile-time default (`localhost`) for native.
String initialDaemonUrl() {
  if (const bool.hasEnvironment('SKCOMMS_URL')) return kDefaultDaemonUrl;
  if (kIsWeb) {
    // Same-origin: call the exact origin the app was served from. The webui
    // reverse-proxies /api/v1 (+ /daemon, /access) to the daemon, so this
    // works on localhost, LAN, tailnet, and the https funnel with no
    // mixed-content and no daemon-port exposure. (Native keeps localhost:9384.)
    final origin = Uri.base.origin;
    if (origin.isNotEmpty && origin != 'null') return origin;
  }
  return kDefaultDaemonUrl;
}

/// Normalize a user-entered daemon URL.
///
/// Accepts bare `host:port`, `host`, or a full `http(s)://...` URL and returns
/// a canonical `scheme://host[:port]` string with no trailing slash.
String normalizeDaemonUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return kDefaultDaemonUrl;
  // Add a scheme if the user typed a bare host[:port].
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    s = 'http://$s';
  }
  // Strip any trailing slash so we can append `/api/...` paths cleanly.
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  // Heal a base that already carries the API prefix: clients append
  // `/api/v1/...`, so a base ending in `/api` would double to `/api/api/v1`
  // (404). This self-corrects stale persisted values from older builds.
  if (s.endsWith('/api')) {
    s = s.substring(0, s.length - 4);
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
  }
  return s;
}

/// Derive the WebSocket signaling base URL from an HTTP daemon URL.
///
/// `http://host:9384`  → `ws://host:9384`
/// `https://host.ts.net` → `wss://host.ts.net`
String daemonWsUrl(String httpUrl) {
  final u = normalizeDaemonUrl(httpUrl);
  if (u.startsWith('https://')) return 'wss://${u.substring('https://'.length)}';
  if (u.startsWith('http://')) return 'ws://${u.substring('http://'.length)}';
  return u;
}

/// Reactive holder for the SKComms daemon base URL.
///
/// All daemon-facing clients (SKCommsClient, CapAuthService, WebRTC signaling)
/// read this so a single user setting repoints the entire app.  The value is
/// persisted in Hive and survives app restarts / web reloads.
class DaemonConfigNotifier extends Notifier<String> {
  @override
  String build() {
    // Synchronously seed from the host-relative/compile-time default;
    // asynchronously load any persisted override.  Hive may not be open yet.
    _loadPersisted();
    return initialDaemonUrl();
  }

  Future<void> _loadPersisted() async {
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      final saved = box.get(_kDaemonUrlKey);
      if (saved != null && saved.trim().isNotEmpty) {
        final normalized = normalizeDaemonUrl(saved);
        if (normalized != state) state = normalized;
      }
    } catch (_) {
      // Hive unavailable — keep the compile-time default.
    }
  }

  /// Update the daemon URL and persist it.  Pass an empty string to reset to
  /// the compile-time default.
  Future<void> setUrl(String raw) async {
    final normalized = normalizeDaemonUrl(raw);
    state = normalized;
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      if (raw.trim().isEmpty) {
        await box.delete(_kDaemonUrlKey);
      } else {
        await box.put(_kDaemonUrlKey, normalized);
      }
    } catch (_) {
      // Best-effort persistence; in-memory state already updated.
    }
  }
}

/// The current HTTP base URL of the SKComms daemon (e.g. `http://localhost:9384`
/// or a tailnet URL).  Watch this to rebuild dependents when it changes.
final daemonUrlProvider =
    NotifierProvider<DaemonConfigNotifier, String>(DaemonConfigNotifier.new);

/// The WebSocket signaling base URL, derived from [daemonUrlProvider].
final daemonWsUrlProvider = Provider<String>((ref) {
  return daemonWsUrl(ref.watch(daemonUrlProvider));
});
