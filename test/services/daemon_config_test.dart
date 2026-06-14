// Unit tests for daemon URL normalization + WS derivation (pure functions).
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/daemon_config.dart";

void main() {
  group("normalizeDaemonUrl", () {
    test("adds http:// scheme to a bare host:port", () {
      expect(normalizeDaemonUrl("localhost:9384"), "http://localhost:9384");
    });

    test("adds http:// scheme to a bare host", () {
      expect(normalizeDaemonUrl("noroc2027"), "http://noroc2027");
    });

    test("preserves an explicit https:// scheme", () {
      expect(
        normalizeDaemonUrl("https://host.tail204f0c.ts.net"),
        "https://host.tail204f0c.ts.net",
      );
    });

    test("strips a single trailing slash", () {
      expect(normalizeDaemonUrl("http://host:9384/"), "http://host:9384");
    });

    test("strips multiple trailing slashes", () {
      expect(normalizeDaemonUrl("http://host:9384///"), "http://host:9384");
    });

    test("trims surrounding whitespace", () {
      expect(normalizeDaemonUrl("  localhost:9384  "), "http://localhost:9384");
    });

    test("empty input falls back to the compile-time default", () {
      expect(normalizeDaemonUrl(""), kDefaultDaemonUrl);
      expect(normalizeDaemonUrl("   "), kDefaultDaemonUrl);
    });
  });

  group("daemonWsUrl", () {
    test("http:// -> ws://", () {
      expect(daemonWsUrl("http://host:9384"), "ws://host:9384");
    });

    test("https:// -> wss://", () {
      expect(daemonWsUrl("https://host.ts.net"), "wss://host.ts.net");
    });

    test("normalizes a bare host first, then derives ws://", () {
      // bare host -> http:// (via normalize) -> ws://
      expect(daemonWsUrl("localhost:9384"), "ws://localhost:9384");
    });

    test("strips trailing slash before deriving", () {
      expect(daemonWsUrl("https://host.ts.net/"), "wss://host.ts.net");
    });
  });
}
