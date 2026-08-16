import "package:flutter/foundation.dart"
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import "package:flutter/material.dart";
import "package:flutter_webrtc/flutter_webrtc.dart"
    show DesktopCapturerSource, SourceType, ThumbnailSize, desktopCapturer;
import "package:livekit_client/livekit_client.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/livekit_call_service.dart";

/// The room-graph resolvers (`resolveScreenShares`, `resolveCameraShares`,
/// `resolveStageVideos`, `resolveTileVideoTrack` and the `ScreenShare` /
/// `StageVideo` shapes) moved to `call_shared/video/track_resolution.dart`,
/// because the CALLS feature needs them too and a call screen must not import
/// out of the SPACES feature to get them.
///
/// This re-export is not a leftover, it is the point of doing the move this
/// way: every Spaces call site and every existing resolver test keeps working
/// untouched, so the move can be proven behaviour-neutral by the tests that
/// were already green. Spaces call sites can be repointed at the real home
/// when Spaces adopts the shared grid; nothing here depends on that happening.
export "../call_shared/video/track_resolution.dart";

/// True on native desktop (Linux / macOS / Windows), where flutter_webrtc
/// requires an explicit capture `sourceId` from `desktopCapturer.getSources()`
/// before `getDisplayMedia` can resolve a source. Always false on web (the
/// browser owns its own picker) and on mobile.
bool get isDesktopScreenShare => !kIsWeb && lkPlatformIsDesktop();

/// Testable seam behind [isMobileWeb]. Mobile browsers (iOS Safari, Android
/// Chrome) have no `getDisplayMedia`, so screen-share origination is not
/// just unsupported by our app, it is impossible on that platform.
/// livekit_client's own `lkPlatformIsWebMobile()` guard (video.dart) throws
/// a raw, unfriendly exception the moment a share is attempted there; the
/// Go live affordance must detect this case first and never reach that
/// guard.
///
/// `kIsWeb` is a compile-time constant (always `false` on the `flutter
/// test` VM, since tests never run inside a browser) and
/// `defaultTargetPlatform` reflects the host OS running the test, not an
/// arbitrary platform under test. Neither is fakeable in a plain unit test,
/// so this function accepts both as optional overrides and falls back to
/// the real values when omitted, which is what [isMobileWeb] does.
bool isMobileWebPlatform({bool? isWeb, TargetPlatform? platform}) {
  final web = isWeb ?? kIsWeb;
  final target = platform ?? defaultTargetPlatform;
  return web &&
      (target == TargetPlatform.iOS || target == TargetPlatform.android);
}

/// True ONLY for Flutter web running inside a phone browser (iOS Safari,
/// Android Chrome). Always false on desktop web and on every native target,
/// including native mobile: native mobile screen share is a separate,
/// not-yet-built feature (contrast [isDesktopScreenShare] above, which
/// covers the native-desktop case).
///
/// Go live / screen-share entry points (Spaces control bar, conference
/// control bar, 1:1 call control bar) check this before attempting a share
/// so a mobile-web user sees a friendly message instead of the raw LiveKit
/// exception.
bool get isMobileWeb => isMobileWebPlatform();

/// Resolve the capture source id to pass into
/// [LiveKitCallService.setScreenShareEnabled] before starting a share.
///
/// On web this is a no-op: returns `(proceed: true, sourceId: null)`
/// immediately, since the browser supplies its own `getDisplayMedia` picker.
///
/// On native desktop it enumerates sources ONCE via
/// `desktopCapturer.getSources()` with a negligible 1x1 thumbnail size (no
/// live thumbnail refresh) and shows a lightweight text-list picker. It
/// returns `(proceed: true, sourceId: <picked id>)` for a chosen source, or
/// `(proceed: false, sourceId: null)` if the user cancelled the dialog or no
/// sources were found. A cancelled pick means the caller MUST NOT start the
/// share (no error, just a silent no-op).
///
/// This intentionally avoids flutter_webrtc's bundled `ScreenSelectDialog`,
/// which runs a `Timer.periodic` re-grabbing live thumbnails of every window
/// and screen every few seconds. On Linux/X11 with an integrated GPU that
/// repeated compositor grab can be heavy enough to crash the whole desktop
/// session, so this picker enumerates sources exactly once and never
/// refreshes thumbnails.
Future<({bool proceed, String? sourceId})> resolveScreenShareSource(
  BuildContext context,
) async {
  if (!isDesktopScreenShare) {
    return (proceed: true, sourceId: null);
  }
  final sources = await desktopCapturer.getSources(
    types: [SourceType.Screen, SourceType.Window],
    thumbnailSize: ThumbnailSize(1, 1),
  );
  if (sources.isEmpty) {
    return (proceed: false, sourceId: null);
  }
  final screens = sources.where((s) => s.type == SourceType.Screen).toList();
  final windows = sources.where((s) => s.type == SourceType.Window).toList();
  if (!context.mounted) {
    return (proceed: false, sourceId: null);
  }
  final source = await showDialog<DesktopCapturerSource>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      backgroundColor: SovereignColors.surfaceCard,
      title: const Text(
        "Choose what to share",
        style: TextStyle(color: SovereignColors.textPrimary),
      ),
      children: [
        for (final s in screens)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(s),
            child: Text(
              s.name.isNotEmpty ? s.name : "Screen",
              style: const TextStyle(color: SovereignColors.textPrimary),
            ),
          ),
        for (final s in windows)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(s),
            child: Text(
              s.name.isNotEmpty ? s.name : "Window",
              style: const TextStyle(color: SovereignColors.textPrimary),
            ),
          ),
      ],
    ),
  );
  if (source == null) {
    return (proceed: false, sourceId: null);
  }
  return (proceed: true, sourceId: source.id);
}
