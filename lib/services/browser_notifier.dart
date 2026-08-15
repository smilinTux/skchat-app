/// Browser notifications for a backgrounded tab, and the policy for what a
/// notification is allowed to say.
///
/// Two tiers are in play and only the first two are built here:
///
///  1. Another view, same tab: no OS notification at all. The app is on
///     screen, so it shows its own badge and peek. Needs nothing from the
///     browser.
///  2. Another TAB, or a minimized window, with this tab still alive: the page
///     Notification API, below. No service worker, no push server.
///  3. Tab closed, browser quit, phone locked: needs Web Push, which needs a
///     service worker. NOT built, and not an oversight, see
///     `browser_notifier_web.dart` for why taking that on is its own decision.
library;

import "browser_notifier_stub.dart"
    if (dart.library.html) "browser_notifier_web.dart" as impl;

/// See the platform implementations. All of these are safe to call anywhere;
/// the native side answers honestly rather than throwing.
bool get documentHidden => impl.documentHidden;
bool get notificationsGranted => impl.notificationsGranted;
bool get notificationsSupported => impl.notificationsSupported;
Future<bool> requestNotificationPermission() =>
    impl.requestNotificationPermission();

void showBrowserNotification({
  required String title,
  required String body,
  required String tag,
  void Function()? onClick,
}) =>
    impl.showBrowserNotification(
        title: title, body: body, tag: tag, onClick: onClick);

/// What a chat notification should actually say.
///
/// Pure so the policy can be tested without a browser, and shared by BOTH
/// surfaces (the in-app peek and the OS notification) so the two can never
/// disagree about what is safe to show. A redaction rule that holds in one
/// place and not the other is the same as no rule.
///
/// [mayShowText] comes from the cast / screen-share detection in
/// `space_chat_session.dart`: when this screen is in front of people who do not
/// own it, the message body is replaced by the fact that a message exists.
({String title, String body}) chatNotificationContent({
  required String sender,
  required String text,
  required bool mayShowText,
  int otherUnread = 0,
}) {
  final who = sender.trim().isEmpty ? "Someone" : sender.trim();
  // The COUNT is safe to show either way: "3 new messages" reveals nothing
  // about their content, and dropping it while redacted would make a busy room
  // look like a quiet one.
  final more = otherUnread > 0
      ? (otherUnread == 1 ? " (+1 more)" : " (+$otherUnread more)")
      : "";
  if (!mayShowText) {
    return (title: "New message", body: "$who sent a message$more");
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return (title: who, body: "sent a message$more");
  }
  return (title: who, body: "$trimmed$more");
}
