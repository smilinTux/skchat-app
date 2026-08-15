/// Web half of the browser-notification seam (see `browser_notifier.dart`).
///
/// Deliberately the PAGE Notification API and nothing else: no service worker,
/// no push subscription, no VAPID keys, no server. That buys "tell me when I
/// am on another tab", which is the common case, without reintroducing a
/// service worker.
///
/// Not reintroducing one is a decision, not an oversight. `web/index.html`
/// actively unregisters every service worker and purges Cache Storage on load,
/// because a stale worker repeatedly served old builds to devices that had
/// loaded an earlier PWA version. Web Push REQUIRES a service worker, so
/// notifications that survive the tab being closed would mean taking that
/// hazard back on, which is its own decision with its own versioning story.
///
/// The consequence, stated plainly rather than discovered later: this works
/// only while the tab is still ALIVE. A backgrounded desktop tab keeps running
/// and this fires. A phone browser freezes background tabs within seconds (and
/// the room's WebRTC connection drops with them), so on mobile this is close to
/// useless. Mobile background notification is the tier that needs Web Push.
library;

import "dart:html" as html;


/// Whether the page is currently backgrounded, i.e. the user is looking at
/// something else. The gate for notifying at all: a visible tab shows its own
/// in-app UI, and doubling that with an OS toast is noise.
bool get documentHidden => html.document.hidden ?? false;

/// True once the user has actually granted permission. Distinct from
/// [notificationsSupported]: "default" (never asked) and "denied" both mean we
/// must not notify, but only one of them is worth asking about.
bool get notificationsGranted =>
    html.Notification.permission == "granted";

/// Whether the API exists at all and has not been denied outright. Safari
/// historically lacked it, and a denied permission is permanent until the user
/// changes it in site settings, so both are "do not bother the user".
bool get notificationsSupported {
  try {
    return html.Notification.supported &&
        html.Notification.permission != "denied";
  } on Object {
    return false;
  }
}

/// Ask for permission, returning whether it ended up granted.
///
/// Browsers require this to be called from a user gesture and will otherwise
/// reject (Chrome) or silently ignore it, which is why callers hang this off
/// an explicit action rather than firing it on page load.
Future<bool> requestNotificationPermission() async {
  if (!notificationsSupported) return false;
  try {
    final result = await html.Notification.requestPermission();
    return result == "granted";
  } on Object {
    return false;
  }
}

/// Post a notification.
///
/// [tag] collapses: posting again with the same tag REPLACES the previous
/// notification instead of stacking a new one. Without it, a chatty room would
/// bury the desktop in toasts, one per message. One live notification per
/// conversation is the behavior every mature chat client converged on.
void showBrowserNotification({
  required String title,
  required String body,
  required String tag,
  void Function()? onClick,
}) {
  if (!notificationsGranted) return;
  try {
    final n = html.Notification(title, body: body, tag: tag);
    if (onClick != null) {
      n.onClick.listen((_) {
        // No explicit window focus call here: dart:html puts focus() on
        // Element, not on Window, so html.window.focus() does not compile.
        // It is not needed anyway. Clicking a notification created by a page
        // is what browsers already treat as the signal to surface that page,
        // so the tab comes forward without us asking.
        onClick();
        n.close();
      });
    }
  } on Object {
    // Construction can throw on a browser that reports support but refuses the
    // call (some embedded webviews). A missing notification must never take
    // the room down with it.
  }
}
