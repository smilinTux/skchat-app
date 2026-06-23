import 'guest_download_stub.dart'
    if (dart.library.html) 'guest_download_web.dart' as impl;

/// Opens/downloads a guest file URL on the current platform (web: a new tab /
/// browser download; non-web: no-op — guest access is web-only).
class GuestDownload {
  static void open(String href) => impl.openGuestUrl(href);
}
