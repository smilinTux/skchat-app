import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/space_share.dart";

void main() {
  group("spaceJoinUrl", () {
    test("points at the Flutter app, not the legacy space.html page", () {
      // `/space/{id}` is a different client entirely: the server serves the
      // standalone legacy page there and it has no Watch Together in it, so a
      // guest handed that link joined the right room and saw an app with no
      // video. The Space lives in the Flutter app under /app/.
      expect(
        spaceJoinUrl("https://noroc2027.tail204f0c.ts.net", "s1"),
        "https://noroc2027.tail204f0c.ts.net/app/#/spaces/s1",
      );
    });

    test("keeps the # : the app is on Flutter's default hash strategy", () {
      // Nothing in the app calls usePathUrlStrategy, so /app/spaces/{id}
      // serves index.html through the SPA catch-all and then boots the router
      // with an empty route, landing the guest on the home screen instead of
      // in the Space. Pin it: adding path strategy later must break this test
      // rather than silently break every shared link.
      final url = spaceJoinUrl("https://x.test", "s1");
      expect(url.contains("/app/#/"), isTrue);
      expect(url.endsWith("/spaces/s1"), isTrue);
    });

    test("strips a trailing slash on the base", () {
      expect(
        spaceJoinUrl("https://noroc2027.tail204f0c.ts.net/", "s1"),
        "https://noroc2027.tail204f0c.ts.net/app/#/spaces/s1",
      );
    });

    test("strips multiple trailing slashes", () {
      expect(
        spaceJoinUrl("https://noroc2027.tail204f0c.ts.net//", "s1"),
        "https://noroc2027.tail204f0c.ts.net/app/#/spaces/s1",
      );
    });
  });

  group("spaceShareText", () {
    test("formats title and url with no em/en dashes", () {
      final text = spaceShareText(
        "SKWorld Town Hall",
        "https://noroc2027.tail204f0c.ts.net/space/s1",
      );
      expect(
        text,
        'Join my Space "SKWorld Town Hall": '
        "https://noroc2027.tail204f0c.ts.net/space/s1",
      );
      expect(text.contains("—"), isFalse); // em dash
      expect(text.contains("–"), isFalse); // en dash
    });
  });
}
