import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/space_share.dart";

void main() {
  group("spaceJoinUrl", () {
    test("joins a clean origin and spaceId", () {
      expect(
        spaceJoinUrl("https://noroc2027.tail204f0c.ts.net", "s1"),
        "https://noroc2027.tail204f0c.ts.net/space/s1",
      );
    });

    test("strips a trailing slash on the base", () {
      expect(
        spaceJoinUrl("https://noroc2027.tail204f0c.ts.net/", "s1"),
        "https://noroc2027.tail204f0c.ts.net/space/s1",
      );
    });

    test("strips multiple trailing slashes", () {
      expect(
        spaceJoinUrl("https://noroc2027.tail204f0c.ts.net//", "s1"),
        "https://noroc2027.tail204f0c.ts.net/space/s1",
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
