// Truth-table unit tests for the pure first-run onboarding gate used by the
// app router. Covers the two bug fixes it drives:
//   1. Guest deep-links (/g/, /join, /conf) must NEVER be bounced, even on a
//      neutral (unconfigured) build.
//   2. A first-run user is sent to /onboarding; a returning user proceeds; and
//      the wizard never redirects onto itself (no loop).
import "package:flutter_test/flutter_test.dart";
import "package:skchat/core/router/app_router.dart";

void main() {
  group("startupRedirect - guest deep-links are never bounced", () {
    test("neutral + /g/<token> -> null", () {
      expect(
        startupRedirect(
          currentLocation: "/g/abc123",
          onboardingComplete: false,
        ),
        isNull,
      );
    });

    test("neutral + /join?room=... -> null (matchedLocation is /join)", () {
      expect(
        startupRedirect(currentLocation: "/join", onboardingComplete: false),
        isNull,
      );
    });

    test("neutral + /conf -> null", () {
      expect(
        startupRedirect(currentLocation: "/conf", onboardingComplete: false),
        isNull,
      );
    });

    test("guest links pass even once onboarding is complete", () {
      expect(
        startupRedirect(currentLocation: "/g/xyz", onboardingComplete: true),
        isNull,
      );
    });
  });

  group("startupRedirect - first-run gate", () {
    test("/chats + onboarding incomplete -> /onboarding", () {
      expect(
        startupRedirect(currentLocation: "/chats", onboardingComplete: false),
        AppRoutes.onboarding,
      );
    });

    test("/chats + onboarding complete -> null (normal shell)", () {
      expect(
        startupRedirect(currentLocation: "/chats", onboardingComplete: true),
        isNull,
      );
    });

    test("already at /onboarding -> null (no redirect loop)", () {
      expect(
        startupRedirect(
          currentLocation: AppRoutes.onboarding,
          onboardingComplete: false,
        ),
        isNull,
      );
    });

    test("a deep shell route (/profile) still gates a first-run user", () {
      expect(
        startupRedirect(currentLocation: "/profile", onboardingComplete: false),
        AppRoutes.onboarding,
      );
    });
  });

  group("isGuestDeepLink", () {
    test("matches the exact guest prefixes and their children", () {
      expect(isGuestDeepLink("/g/token"), isTrue);
      expect(isGuestDeepLink("/join"), isTrue);
      expect(isGuestDeepLink("/conf"), isTrue);
      expect(isGuestDeepLink("/chats"), isFalse);
      expect(isGuestDeepLink("/onboarding"), isFalse);
      // A non-guest route that merely starts with a similar letter must not
      // match (guarding against an over-broad prefix like "/j").
      expect(isGuestDeepLink("/journal"), isFalse);
    });
  });
}
