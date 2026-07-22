// Unit tests for the native (dart.library.io) in-memory seams backing
// operator_token.dart and operator_session_store.dart. On the flutter-test
// VM target, `dart.library.io` is the branch that resolves, so importing the
// public seam files here exercises operator_token_io.dart and
// operator_session_store_io.dart directly.
//
// Both seams are module-level in-memory globals (no reset hook), so each
// test clears its own value at the end to avoid leaking state into whatever
// test runs next.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/operator_session_store.dart";
import "package:skchat/services/operator_token.dart";

void main() {
  group("operator_token (native in-memory seam)", () {
    test("set then read round-trips the value", () {
      setOperatorToken("abc");
      expect(operatorToken(), "abc");
      setOperatorToken(null); // clear for the next test
    });

    test("setting an empty string clears it back to null", () {
      setOperatorToken("abc");
      setOperatorToken("");
      expect(operatorToken(), isNull);
    });

    test("setting null clears it back to null", () {
      setOperatorToken("abc");
      setOperatorToken(null);
      expect(operatorToken(), isNull);
    });
  });

  group("operator_session_store (native in-memory seam)", () {
    test("set then read round-trips the value", () {
      setOperatorSessionToken("session-abc");
      expect(operatorSessionToken(), "session-abc");
      setOperatorSessionToken(null); // clear for the next test
    });

    test("setting an empty string clears it back to null", () {
      setOperatorSessionToken("session-abc");
      setOperatorSessionToken("");
      expect(operatorSessionToken(), isNull);
    });

    test("setting null clears it back to null", () {
      setOperatorSessionToken("session-abc");
      setOperatorSessionToken(null);
      expect(operatorSessionToken(), isNull);
    });
  });
}
