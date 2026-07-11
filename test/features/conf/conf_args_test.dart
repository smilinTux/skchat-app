// Unit tests for ConfArgs.fromParams: the native conf hand-off deep link
// (coord 59184ca7). A guest/sovereign/conf token mint on the backend redirects
// to /app/#/conf?room=...&token=...&url=...&identity=...; GoRouter parses those
// query params into a ConfArgs that connects via connectWithToken.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/conf/conf_screen.dart";

void main() {
  group("ConfArgs.fromParams", () {
    test("pre-minted guest/sovereign join carries token + url + identity", () {
      final args = ConfArgs.fromParams({
        "room": "conf-townhall",
        "token": "jwt-guest",
        "url": "wss://lk.test/ws",
        "identity": "guest:deadbeef",
        "display": "Alice",
      });
      expect(args, isNotNull);
      expect(args!.room, "conf-townhall");
      expect(args.preMintedToken, "jwt-guest");
      expect(args.wsUrl, "wss://lk.test/ws");
      expect(args.identity, "guest:deadbeef");
      expect(args.name, "Alice");
      expect(args.hasPreMintedToken, isTrue);
      // A guest join is not the host.
      expect(args.wantsHost, isFalse);
    });

    test("bare room landing has no pre-minted token (app mints)", () {
      final args = ConfArgs.fromParams({"room": "conf-standup"});
      expect(args, isNotNull);
      expect(args!.room, "conf-standup");
      expect(args.hasPreMintedToken, isFalse);
      expect(args.preMintedToken, isNull);
      expect(args.wsUrl, isNull);
      // Defaults to a guest join with an empty (to-be-resolved) identity.
      expect(args.role, "guest");
      expect(args.identity, "");
    });

    test("accepts lk_token / lk_url / space_id aliases", () {
      final args = ConfArgs.fromParams({
        "space_id": "conf-x",
        "lk_token": "jwt",
        "lk_url": "wss://lk/ws",
      });
      expect(args!.room, "conf-x");
      expect(args.preMintedToken, "jwt");
      expect(args.wsUrl, "wss://lk/ws");
      expect(args.hasPreMintedToken, isTrue);
    });

    test("honours an explicit host role", () {
      final args = ConfArgs.fromParams({"room": "r", "role": "host"});
      expect(args!.wantsHost, isTrue);
    });

    test("returns null when no room is present", () {
      expect(ConfArgs.fromParams({"token": "jwt"}), isNull);
      expect(ConfArgs.fromParams(const {}), isNull);
    });

    test("token without url is not a pre-minted join", () {
      final args = ConfArgs.fromParams({"room": "r", "token": "jwt"});
      expect(args, isNotNull);
      expect(args!.hasPreMintedToken, isFalse);
    });
  });
}
