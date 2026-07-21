// Model-contract test for GuestKeypair.degraded. This file intentionally
// imports ONLY guest_identity.dart (not guest_identity_web.dart, which pulls
// in dart:js_interop / package:web and requires a browser runtime), so it is
// VM-safe and runs under the normal `flutter test` runner.
//
// The full ensure()-throws fallback path inside _WebGuestIdentity lives in
// guest_identity_web.dart and can only run under a browser (dart:html /
// crypto.subtle). That path is covered by
// test/services/guest_identity_web_browser_test.dart, tagged
// @Tags(["browser"]) and run separately with `--platform chrome` (see that
// file's header for the exact manual command).
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_identity.dart";

void main() {
  test("GuestKeypair carries a degraded flag defaulting false", () {
    const k = GuestKeypair(publicKeyB64: "a", fingerprint: "b");
    expect(k.degraded, isFalse);
    const d = GuestKeypair(publicKeyB64: "a", fingerprint: "b", degraded: true);
    expect(d.degraded, isTrue);
  });
}
