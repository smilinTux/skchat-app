import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/deploy_freshness_probe.dart";

void main() {
  group("the native/VM stub answers honestly instead of throwing", () {
    // Under `flutter test` the stub is what loads (no dart:html in the VM),
    // same as browser_notifier's seam. The whole point of the seam is that
    // callers never branch on platform, so these must be callable, not
    // explode.
    test("fetching a served marker resolves null rather than hanging", () async {
      expect(await fetchServedBuildMarker(), isNull);
    });

    test("reloading is a no-op, not a crash", () {
      expect(() => reloadPage(), returnsNormally);
    });
  });
}
