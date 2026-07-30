// Export shim (reconciled spec 3.2 step 2).
//
// The Sovereign Glass color tokens MOVED into the `skchat_ui` workspace package
// (`packages/skchat_ui/lib/src/theme/sovereign_colors.dart`) so the extracted
// chats surface can render its real look without importing a shell/app package
// (import gate, spec 3.2 step 4). This file stays at its original path and
// re-exports the moved type so every existing importer keeps resolving
// unchanged. New code should import `package:skchat_ui/skchat_ui.dart`.
export 'package:skchat_ui/skchat_ui.dart' show SovereignColors;
