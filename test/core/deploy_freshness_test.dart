import "package:flutter_test/flutter_test.dart";
import "package:skchat/core/deploy_freshness.dart";

void main() {
  group("resolveDeployFreshness", () {
    test("no baseline yet (first-ever check) never prompts", () {
      expect(
          resolveDeployFreshness(servedMarker: "abc123", baselineMarker: null),
          DeployFreshnessAction.none);
    });

    test("a failed or malformed fetch never prompts (fail silent)", () {
      expect(
          resolveDeployFreshness(servedMarker: null, baselineMarker: "abc123"),
          DeployFreshnessAction.none);
      expect(
          resolveDeployFreshness(servedMarker: "", baselineMarker: "abc123"),
          DeployFreshnessAction.none);
    });

    test("an empty baseline never prompts", () {
      expect(
          resolveDeployFreshness(servedMarker: "abc123", baselineMarker: ""),
          DeployFreshnessAction.none);
    });

    test("same marker as the baseline is not a change", () {
      expect(
          resolveDeployFreshness(
              servedMarker: "abc123", baselineMarker: "abc123"),
          DeployFreshnessAction.none);
    });

    test("a genuinely different marker prompts", () {
      expect(
          resolveDeployFreshness(
              servedMarker: "def456", baselineMarker: "abc123"),
          DeployFreshnessAction.prompt);
    });
  });

  group("DeployFreshnessTracker", () {
    test("a build with no dart-defines ('dev') never participates", () {
      // A local `flutter run` has no meaningful "deployed build" to compare
      // against; nagging a developer's own session would just be noise.
      final t = DeployFreshnessTracker(myBuildId: "dev");
      expect(t.onCheck("abc123"), DeployFreshnessAction.none);
      expect(t.onCheck("def456"), DeployFreshnessAction.none);
      expect(t.baseline, isNull);
    });

    test("an empty compiled-in build id also never participates", () {
      final t = DeployFreshnessTracker(myBuildId: "");
      expect(t.onCheck("abc123"), DeployFreshnessAction.none);
      expect(t.onCheck("def456"), DeployFreshnessAction.none);
    });

    test("the first successful check establishes the baseline, not a prompt",
        () {
      final t = DeployFreshnessTracker(myBuildId: "c300114-0806-0145");
      expect(t.onCheck("etag-1"), DeployFreshnessAction.none);
      expect(t.baseline, "etag-1");
    });

    test("a failed first check leaves the baseline unset, tried again later",
        () {
      final t = DeployFreshnessTracker(myBuildId: "c300114-0806-0145");
      expect(t.onCheck(null), DeployFreshnessAction.none);
      expect(t.baseline, isNull, reason: "nothing to baseline off a failure");
      expect(t.onCheck("etag-1"), DeployFreshnessAction.none,
          reason: "this one succeeds, so IT becomes the baseline");
      expect(t.baseline, "etag-1");
    });

    test("repeated checks against an unchanged server stay quiet", () {
      final t = DeployFreshnessTracker(myBuildId: "c300114-0806-0145")
        ..onCheck("etag-1");
      expect(t.onCheck("etag-1"), DeployFreshnessAction.none);
      expect(t.onCheck("etag-1"), DeployFreshnessAction.none);
    });

    test("a new deploy landing after the baseline prompts exactly once", () {
      final t = DeployFreshnessTracker(myBuildId: "c300114-0806-0145")
        ..onCheck("etag-1");
      expect(t.onCheck("etag-2"), DeployFreshnessAction.prompt);
      expect(t.hasPendingPrompt, isTrue);
      // The SAME deploy re-observed on the next visibilitychange must NOT
      // re-arm a second banner while the first is still outstanding.
      expect(t.onCheck("etag-2"), DeployFreshnessAction.none);
      expect(t.onCheck("etag-2"), DeployFreshnessAction.none);
    });

    test("a failed fetch while a prompt is outstanding does not clear it", () {
      final t = DeployFreshnessTracker(myBuildId: "c300114-0806-0145")
        ..onCheck("etag-1");
      t.onCheck("etag-2");
      expect(t.hasPendingPrompt, isTrue);
      expect(t.onCheck(null), DeployFreshnessAction.none);
      expect(t.hasPendingPrompt, isTrue,
          reason: "a probe failure must not silently dismiss a real prompt");
    });

    test("acknowledge promotes the pending marker to the new baseline", () {
      final t = DeployFreshnessTracker(myBuildId: "c300114-0806-0145")
        ..onCheck("etag-1");
      t.onCheck("etag-2");
      t.acknowledge();
      expect(t.hasPendingPrompt, isFalse);
      expect(t.baseline, "etag-2");
      // The deploy that was just acknowledged must not prompt again...
      expect(t.onCheck("etag-2"), DeployFreshnessAction.none);
      // ...but a genuinely NEWER one, after this, still does.
      expect(t.onCheck("etag-3"), DeployFreshnessAction.prompt);
    });

    test("acknowledge without a pending prompt is a harmless no-op", () {
      final t = DeployFreshnessTracker(myBuildId: "c300114-0806-0145")
        ..onCheck("etag-1");
      t.acknowledge();
      expect(t.baseline, "etag-1");
    });

    test(
        "myBuildId is never compared to the served marker directly "
        "(a coincidental string match must not suppress a real prompt)", () {
      final t = DeployFreshnessTracker(myBuildId: "etag-2")
        ..onCheck("etag-1");
      expect(t.onCheck("etag-2"), DeployFreshnessAction.prompt);
    });
  });
}
