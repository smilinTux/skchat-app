/// Compile-time build stamp so a device can confirm exactly which build it is
/// running (past any service-worker / PWA cache). Injected via `--dart-define`
/// at build time; see `scripts/build-web-lumina.sh`. Falls back to a `dev`
/// marker for local runs that do not pass the defines.
library;

/// The pubspec version (e.g. `1.4.0+13`), passed at build time.
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.4.0+13',
);

/// A short build id: git short hash + build timestamp (e.g. `c300114-0806-0145`).
const String kBuildId = String.fromEnvironment(
  'BUILD_ID',
  defaultValue: 'dev',
);

/// One-line label for display in the UI.
String get appBuildLabel => 'v$kAppVersion  build $kBuildId';
