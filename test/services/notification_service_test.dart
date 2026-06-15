// Unit tests for the host-notification suppression guard.
//
// These run on a Linux test host, which is treated as a desktop "host" — so
// suppression defaults ON and the show* methods must short-circuit BEFORE
// touching any platform channel (which is unavailable in the test harness).
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/notification_service.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("NotificationService.suppressHostNotifications", () {
    // Restore the static flag after each test so cases stay isolated.
    late bool original;
    setUp(() => original = NotificationService.suppressHostNotifications);
    tearDown(() => NotificationService.suppressHostNotifications = original);

    test("defaults to true on a desktop host (Linux/macOS/Windows)", () {
      final isDesktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
      expect(NotificationService.suppressHostNotifications, isDesktop);
    });

    test("showMessageNotification is a no-op when suppressed (no platform channel)",
        () async {
      NotificationService.suppressHostNotifications = true;
      // Must complete without throwing — i.e. it never reaches the plugin,
      // which would fail with a MissingPluginException in the test harness.
      await NotificationService.instance.showMessageNotification(
        senderName: "Lumina",
        content: "hello",
        peerId: "peer-1",
      );
    });

    test("showSigningRequest is a no-op when suppressed (no platform channel)",
        () async {
      NotificationService.suppressHostNotifications = true;
      await NotificationService.instance.showSigningRequest(
        documentTitle: "Contract",
        senderName: "Lumina",
      );
    });
  });
}
