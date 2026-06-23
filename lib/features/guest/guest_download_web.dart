import 'dart:html' as html;

/// Web: open the guest file URL in a new tab so the browser views/downloads it.
/// The URL is same-origin (`/api/v1/guest/file/<tid>`); the server gates access
/// to the bound group via the transfer->group allowlist.
void openGuestUrl(String href) {
  html.window.open(href, '_blank');
}
