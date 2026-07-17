import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../spaces/screen_share_helper.dart";

/// Same shape [resolveScreenShareSource] returns: `proceed: true` with a
/// `sourceId` (native desktop pick), `proceed: true` with a null `sourceId`
/// (web/mobile, nothing to resolve), or `proceed: false` (the user cancelled
/// the native picker, or no capture sources were found).
typedef ScreenShareSourceResolver = Future<({bool proceed, String? sourceId})>
    Function(BuildContext context);

/// DI seam around [resolveScreenShareSource] so every screen-share entry
/// point (the Spaces panel, the conference control bar, the 1:1 call control
/// bar) resolves a native-desktop capture source through the exact same
/// picker, and widget tests can substitute a fake resolver instead of
/// exercising the real `desktopCapturer` platform channel (unavailable in
/// `flutter test`). Production code never overrides this: the default IS
/// [resolveScreenShareSource], unchanged.
final screenShareSourceResolverProvider = Provider<ScreenShareSourceResolver>(
  (ref) => resolveScreenShareSource,
);
