import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/browser_notifier.dart";

void main() {
  group("chatNotificationContent", () {
    test("shows the message when nothing is mirroring the screen", () {
      final c = chatNotificationContent(
          sender: "casey", text: "starting in 5", mayShowText: true);
      expect(c.title, "casey");
      expect(c.body, "starting in 5");
    });

    test("redacts to sender-only when the screen is being shown to a room", () {
      // Chef: "if you are broadcasting on a tv, you may not want the group
      // messages being displayed to everyone."
      final c = chatNotificationContent(
          sender: "casey", text: "the surprise is a cake", mayShowText: false);
      expect(c.body, contains("casey"));
      expect(c.body, isNot(contains("cake")),
          reason: "the whole point: no message text on a screen a room sees");
      expect(c.title, isNot(contains("cake")));
    });

    test("the redacted form leaks nothing through the title either", () {
      // The title is the larger, more readable half of an OS notification, so
      // it is the more dangerous place to put a name, let alone content.
      final c = chatNotificationContent(
          sender: "dr-hendricks", text: "biopsy results", mayShowText: false);
      expect(c.title, "New message");
      expect("${c.title} ${c.body}", isNot(contains("biopsy")));
    });

    test("the unread count survives redaction", () {
      // A count reveals no content, and dropping it while redacted would make
      // a busy room look like a quiet one.
      final c = chatNotificationContent(
          sender: "casey", text: "secret", mayShowText: false, otherUnread: 3);
      expect(c.body, contains("3"));
      expect(c.body, isNot(contains("secret")));
    });

    test("pluralises the count", () {
      final one = chatNotificationContent(
          sender: "a", text: "x", mayShowText: true, otherUnread: 1);
      final many = chatNotificationContent(
          sender: "a", text: "x", mayShowText: true, otherUnread: 4);
      expect(one.body, contains("+1 more"));
      expect(many.body, contains("+4 more"));
    });

    test("no count means no parenthetical at all", () {
      final c = chatNotificationContent(
          sender: "casey", text: "hi", mayShowText: true);
      expect(c.body, "hi");
    });

    test("an empty sender degrades to something readable", () {
      final c =
          chatNotificationContent(sender: "   ", text: "hi", mayShowText: false);
      expect(c.body, startsWith("Someone"));
    });

    test("an empty message still reads as a message, not as blank", () {
      final c =
          chatNotificationContent(sender: "casey", text: "  ", mayShowText: true);
      expect(c.title, "casey");
      expect(c.body, contains("sent a message"));
    });
  });

  group("the native stub answers honestly instead of throwing", () {
    // Every caller asks these on all platforms. Under `flutter test` the stub
    // is what loads, and it must be callable rather than exploding, since the
    // whole point of the seam is that the caller does not branch on platform.
    test("a native build is never a hidden browser tab", () {
      expect(documentHidden, isFalse);
    });

    test("and reports no notification support, so callers fall through", () {
      expect(notificationsSupported, isFalse);
      expect(notificationsGranted, isFalse);
    });

    test("requesting permission resolves false rather than hanging", () async {
      expect(await requestNotificationPermission(), isFalse);
    });

    test("showing one is a no-op, not a crash", () {
      expect(
          () => showBrowserNotification(
              title: "t", body: "b", tag: "space-s1"),
          returnsNormally);
    });
  });
}
