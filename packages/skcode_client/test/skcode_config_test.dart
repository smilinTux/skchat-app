import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

void main() {
  group("skcodeWsUri", () {
    test("builds wss://<origin>/skcode/api/v1/sessions/<sid>/stream?token=<wire>",
        () {
      final uri = skcodeWsUri("https://daemon.local", "s-123", "TOK");
      expect(uri.toString(),
          "wss://daemon.local/skcode/api/v1/sessions/s-123/stream?token=TOK");
    });

    test("maps http -> ws and strips a trailing slash", () {
      final uri = skcodeWsUri("http://localhost:9384/", "s1", "T");
      expect(uri.toString(),
          "ws://localhost:9384/skcode/api/v1/sessions/s1/stream?token=T");
    });

    test("encodes the token as a safe query component", () {
      final uri = skcodeWsUri("https://daemon.local", "s1", "a b/c");
      // `Uri.encodeQueryComponent` uses `+` for space (standard
      // application/x-www-form-urlencoded), which a standard query-string
      // decoder (FastAPI/Starlette on the daemon side) decodes back to a
      // literal space identically to `%20`.
      expect(uri.query, "token=a+b%2Fc");
    });
  });

  group("kSkcodeAudience", () {
    test("matches the manifest auth.audience for the skcode module", () {
      expect(kSkcodeAudience, "skcode");
    });
  });
}
