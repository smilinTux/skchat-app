/// Non-web (native mobile/desktop) side of the media-actions web seam.
///
/// This is the stub half of the conditional import in `skos_files_screen.dart`
/// (`media_actions_stub.dart if (dart.library.html) media_actions_web.dart`).
/// On native there is no browser to trigger an anchor download into, so
/// [triggerBrowserDownload] is a no-op, the share path (`share_plus`) covers
/// "save / open in another app" on iOS/Android, which is the only place this
/// surface actually ships. Kept as an explicit no-op so the call site compiles
/// identically on every target with no `kIsWeb` branching at the call site.
void triggerBrowserDownload(String url, String filename) {
  // No-op on native: handled by Share.shareXFiles (see options sheet).
}
