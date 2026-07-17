import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/screen_share_helper.dart";

// Z1: mobile-web screen-share origination is impossible (no getDisplayMedia
// on iOS Safari / mobile Chrome), so the Go live affordance must detect it
// and short-circuit to a friendly message instead of ever reaching
// livekit_client's own lkPlatformIsWebMobile() guard, which throws a raw,
// unfriendly exception. isMobileWebPlatform is the testable seam behind the
// isMobileWeb getter: `kIsWeb` is a compile-time constant (always false on
// the `flutter test` VM) and `defaultTargetPlatform` is not independently
// fakeable per case here, so the function takes both as optional overrides
// and falls back to the real values when omitted.
void main() {
  group("isMobileWebPlatform", () {
    test("true on mobile web: web + iOS", () {
      expect(
        isMobileWebPlatform(isWeb: true, platform: TargetPlatform.iOS),
        isTrue,
      );
    });

    test("true on mobile web: web + Android", () {
      expect(
        isMobileWebPlatform(isWeb: true, platform: TargetPlatform.android),
        isTrue,
      );
    });

    test("false on desktop web: web + desktop platform", () {
      expect(
        isMobileWebPlatform(isWeb: true, platform: TargetPlatform.linux),
        isFalse,
      );
      expect(
        isMobileWebPlatform(isWeb: true, platform: TargetPlatform.macOS),
        isFalse,
      );
      expect(
        isMobileWebPlatform(isWeb: true, platform: TargetPlatform.windows),
        isFalse,
      );
    });

    test("false on native, even on a phone platform (not web)", () {
      expect(
        isMobileWebPlatform(isWeb: false, platform: TargetPlatform.iOS),
        isFalse,
      );
      expect(
        isMobileWebPlatform(isWeb: false, platform: TargetPlatform.android),
        isFalse,
      );
    });

    test("false on native desktop", () {
      expect(
        isMobileWebPlatform(isWeb: false, platform: TargetPlatform.linux),
        isFalse,
      );
    });
  });

  group("isMobileWeb getter", () {
    test("resolves against the real kIsWeb / defaultTargetPlatform on the "
        "test VM (never web here, so always false)", () {
      // The flutter test VM is never `kIsWeb`, so the production getter
      // must be false regardless of defaultTargetPlatform. This guards
      // against a regression where the getter stops consulting kIsWeb.
      expect(isMobileWeb, isFalse);
    });
  });
}
