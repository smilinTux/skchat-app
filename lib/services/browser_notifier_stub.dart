/// Non-web half of the browser-notification seam (see `browser_notifier.dart`).
///
/// Native builds have a real OS notification path of their own and no notion
/// of a "hidden tab", so every entry point here is an honest no-op rather than
/// a throw: the caller asks "is this surface backgrounded, and can I notify?"
/// on every platform and gets "no" here, which is true.
library;

/// Always false: a native app is never a background browser tab.
bool get documentHidden => false;

/// Always false: nothing to grant.
bool get notificationsGranted => false;

/// Never available, so callers fall through to their in-app path.
bool get notificationsSupported => false;

Future<bool> requestNotificationPermission() async => false;

void showBrowserNotification({
  required String title,
  required String body,
  required String tag,
  void Function()? onClick,
}) {}
