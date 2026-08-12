import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

/// Card C-12 AC3: "all four breakpoint tiers implemented, driven by
/// LayoutBuilder on the pane's own width, not screen width." This is the
/// pure classification the layout builder consults; a dedicated boundary
/// test here is cheaper and more precise than re-deriving the same edges
/// from widget-level measurements everywhere else.
void main() {
  test("pane width >= 1500 is the wide (four-column) tier", () {
    expect(skcodePaneTierForWidth(1500), SkcodePaneTier.wide);
    expect(skcodePaneTierForWidth(1800), SkcodePaneTier.wide);
  });

  test("just under 1500 is the three-column tier, not wide", () {
    expect(skcodePaneTierForWidth(1499.999), SkcodePaneTier.threeColumn);
  });

  test("1200 to 1499 is the three-column tier", () {
    expect(skcodePaneTierForWidth(1200), SkcodePaneTier.threeColumn);
    expect(skcodePaneTierForWidth(1350), SkcodePaneTier.threeColumn);
    expect(skcodePaneTierForWidth(1499), SkcodePaneTier.threeColumn);
  });

  test("just under 1200 is the two-column tier, not three-column", () {
    expect(skcodePaneTierForWidth(1199.999), SkcodePaneTier.twoColumn);
  });

  test("900 to 1199 is the two-column tier", () {
    expect(skcodePaneTierForWidth(900), SkcodePaneTier.twoColumn);
    expect(skcodePaneTierForWidth(1050), SkcodePaneTier.twoColumn);
    expect(skcodePaneTierForWidth(1199), SkcodePaneTier.twoColumn);
  });

  test("just under 900 is the phone tier, not two-column", () {
    expect(skcodePaneTierForWidth(899.999), SkcodePaneTier.phone);
  });

  test("below 900 (and non-positive widths) is the phone tier", () {
    expect(skcodePaneTierForWidth(899), SkcodePaneTier.phone);
    expect(skcodePaneTierForWidth(600), SkcodePaneTier.phone);
    expect(skcodePaneTierForWidth(0), SkcodePaneTier.phone);
  });

  test(
    "the four-column tier's fixed column widths guarantee the transcript's "
    "540px floor by construction at the tier's own boundary width",
    () {
      final fixedTotal =
          kSkcodeRailColumnWidth + kSkcodeChatColumnWidth + kSkcodeArtifactColumnWidth;
      expect(kSkcodeWideBreakpoint - fixedTotal, greaterThanOrEqualTo(kSkcodeTranscriptMinWidth));
    },
  );
}
