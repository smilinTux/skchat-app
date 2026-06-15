import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:skchat/core/chat_text.dart";

void main() {
  group("displayTextFor", () {
    test("returns null for null / empty / whitespace", () {
      expect(displayTextFor(null), isNull);
      expect(displayTextFor(""), isNull);
      expect(displayTextFor("   "), isNull);
      expect(displayTextFor("\n\t  "), isNull);
    });

    test("returns trimmed text for ordinary messages", () {
      expect(displayTextFor("hello"), "hello");
      expect(displayTextFor("  hey there  "), "hey there");
    });

    test("collapses a 'Chat context (recent):' system message", () {
      expect(
        displayTextFor("Chat context (recent):\nfoo\nbar"),
        isNull,
      );
    });

    test("unwraps a JSON envelope to its inner content", () {
      final env = jsonEncode({
        "id": "abc123",
        "sender": "capauth:lumina@skworld.io",
        "recipient": "capauth:architect@skworld.io",
        "content": "hello from inside the envelope",
      });
      expect(displayTextFor(env), "hello from inside the envelope");
    });

    test("envelope whose inner content is a context message collapses", () {
      final env = jsonEncode({
        "id": "x",
        "sender": "capauth:lumina@skworld.io",
        "recipient": "capauth:architect@skworld.io",
        "content": "Chat context (recent):\nstuff",
      });
      expect(displayTextFor(env), isNull);
    });

    test("envelope with empty inner content collapses", () {
      final env = jsonEncode({
        "id": "x",
        "sender": "capauth:lumina@skworld.io",
        "recipient": "capauth:architect@skworld.io",
        "content": "",
      });
      expect(displayTextFor(env), isNull);
    });

    test("a JSON-looking object without routing fields is shown as-is", () {
      const notEnvelope = '{"foo":"bar"}';
      expect(displayTextFor(notEnvelope), notEnvelope);
    });

    test("malformed JSON that mentions sender/recipient is shown as-is", () {
      // Not valid JSON, so it falls through and is shown (trimmed) as-is.
      const broken = '{"sender": "a", "recipient":}';
      expect(displayTextFor(broken), broken);
    });
  });

  group("normalizePeerKey", () {
    test("the four lumina forms collapse to one key", () {
      const expected = "lumina";
      expect(normalizePeerKey("Lumina"), expected);
      expect(normalizePeerKey("lumina"), expected);
      expect(normalizePeerKey("lumina@skworld.io"), expected);
      expect(normalizePeerKey("capauth:lumina@skworld.io"), expected);
    });

    test("strips multi-segment scheme prefixes", () {
      expect(normalizePeerKey("did:capauth:lumina@skworld.io"), "lumina");
    });

    test("lowercases and trims display names", () {
      expect(normalizePeerKey("  Lumina  "), "lumina");
    });

    test("distinct peers stay distinct", () {
      expect(
        normalizePeerKey("capauth:architect@skworld.io"),
        isNot(normalizePeerKey("capauth:lumina@skworld.io")),
      );
      expect(normalizePeerKey("jarvis@skworld.io"), "jarvis");
    });

    test("empty input stays empty", () {
      expect(normalizePeerKey(""), "");
      expect(normalizePeerKey("   "), "");
    });
  });
}
