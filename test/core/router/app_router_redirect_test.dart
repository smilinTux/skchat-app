// Unit tests for the pure backend-setup redirect guard used by the app
// router: an unconfigured (neutral) build must route to the Profile server
// picker instead of letting any client hit an empty base URL.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/core/router/app_router.dart";

void main() {
  test("unconfigured backend redirects to the profile picker", () {
    expect(backendSetupRedirect(webuiUrl: "", currentLocation: "/chats"),
        "/profile");
  });
  test("profile route is allowed through even when unconfigured (no loop)",
      () {
    expect(backendSetupRedirect(webuiUrl: "", currentLocation: "/profile"),
        isNull);
  });
  test("configured backend proceeds (no redirect)", () {
    expect(
        backendSetupRedirect(
            webuiUrl: "https://x.example", currentLocation: "/chats"),
        isNull);
  });
}
