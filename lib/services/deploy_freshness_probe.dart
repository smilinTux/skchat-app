/// Platform seam for the deploy-freshness probe, the same shape as
/// `browser_notifier.dart` / `device_label.dart`: the real implementation
/// (`dart:html`) lives in `deploy_freshness_probe_web.dart`; every other
/// target (native, or `flutter test`'s VM) gets the always-inert stub in
/// `deploy_freshness_probe_stub.dart`.
library;

import "deploy_freshness_probe_stub.dart"
    if (dart.library.html) "deploy_freshness_probe_web.dart" as impl;

/// Fetch a fresh marker representing "whatever build the server is serving
/// right now", or null if the check failed for any reason (network, a proxy
/// that strips validators, an unexpected response). Never throws. See
/// `deploy_freshness_probe_web.dart` for what the marker actually is and why.
Future<String?> fetchServedBuildMarker() => impl.fetchServedBuildMarker();

/// Reload this tab. No-op off web, where there is no stale tab to save.
void reloadPage() => impl.reloadPage();
