import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:share_plus/share_plus.dart";

/// Native OS share invocation (iMessage / Telegram / email / etc via the
/// share sheet), DI seam mirroring [screenShareSourceResolverProvider] (see
/// `call_shared/screen_share_source.dart`): every entry point resolves the
/// native share through the exact same function, and a widget test can
/// substitute a fake invoker instead of exercising the real share_plus
/// platform channel (unavailable in `flutter test`). Production code never
/// overrides this: the default IS [Share.share], unchanged.
typedef NativeShareInvoker = Future<void> Function(
  String text, {
  String? subject,
});

Future<void> _defaultNativeShare(String text, {String? subject}) =>
    Share.share(text, subject: subject);

final nativeShareInvokerProvider = Provider<NativeShareInvoker>(
  (ref) => _defaultNativeShare,
);

/// The public join URL for an SK Space: `{serverBase}/app/#/spaces/{spaceId}`.
///
/// [serverBase] is the app's SKChat web-UI base (see
/// `BackendConfig.skchatWebuiUrl` / `spacesServiceProvider`), the same origin
/// the Spaces API and LiveKit token mint are served from. Any trailing
/// slash(es) on the base are stripped so the join path always joins cleanly.
///
/// This used to point at `/space/{id}`, which is a DIFFERENT client: the
/// server serves the legacy standalone `space.html` there, and that page has
/// no Watch Together in it at all. A guest handed that link joined the right
/// room and then sat looking at an app with no video in it, which is exactly
/// what happened on Chef's watch party. The Space lives in the Flutter app,
/// mounted by the server at `/app/` (`<base href="/app/">`), and the app has
/// no `usePathUrlStrategy` call anywhere, so Flutter web is on its default
/// HASH strategy: `/app/spaces/{id}` serves index.html through the SPA
/// catch-all and then boots the router with an empty route, landing the guest
/// on the home screen. The `#` is load-bearing, not cosmetic.
String spaceJoinUrl(String serverBase, String spaceId) {
  var base = serverBase.trim();
  while (base.endsWith("/")) {
    base = base.substring(0, base.length - 1);
  }
  return "$base/app/#/spaces/$spaceId";
}

/// The share message text for a Space invite.
String spaceShareText(String title, String url) =>
    'Join my Space "$title": $url';
