/// The Code pane's responsive breakpoint ladder (card C-12, spec section 7
/// rev 2 / 7.2): "Breakpoints are measured with a LayoutBuilder on the
/// pane's OWN width, never screen width, so the numbers hold when the shell
/// rail steals about 80px."
///
/// Every caller of [skcodePaneTierForWidth] MUST source [width] from a
/// [LayoutBuilder]'s own `constraints.maxWidth` (the pane's own box), never
/// `MediaQuery.sizeOf(context).width` (the whole screen/window). The two
/// diverge by roughly the shell's own rail width once the module is mounted
/// inside the app shell, which is exactly the drift this rule exists to
/// prevent (spec 7.2: "pane >= 1500 plus the shell rail's ~80px means the
/// WINDOW needs roughly 1580+").
enum SkcodePaneTier {
  /// pane width >= [kSkcodeWideBreakpoint]: rail | project chat | transcript
  /// | artifact, four honest columns (spec section 7, "WIDE").
  wide,

  /// [kSkcodeThreeColumnBreakpoint] <= pane width < [kSkcodeWideBreakpoint]:
  /// chat collapses FIRST into the artifact pane's Chat tab (spec section 7,
  /// "Three-column").
  threeColumn,

  /// [kSkcodeTwoColumnBreakpoint] <= pane width < [kSkcodeThreeColumnBreakpoint]:
  /// rail + transcript; the artifact pane (still carrying the Chat tab)
  /// becomes a toggled overlay docked right (spec section 7, "Two-column").
  twoColumn,

  /// pane width < [kSkcodeTwoColumnBreakpoint]: the rail IS the `/code`
  /// landing screen; a tapped session pushes full screen (spec section 7,
  /// "Phone"). Unchanged from card C-4/C-5/C-6's existing behavior.
  phone,
}

/// Four-column tier floor (spec section 7: "Four-column (pane width >=
/// 1500)"). Fixed column widths below (280 + 320 + 360 = 960) mean the
/// transcript's flexible remainder is guaranteed `>= 1500 - 960 == 540` at
/// this floor, matching spec's "transcript flex, never below ~540" WITHOUT
/// needing any extra runtime clamping: the arithmetic holds by construction
/// as long as this constant and the three fixed widths below never drift out
/// of sync. `skcode_responsive_body_test.dart` asserts the measured
/// transcript width at exactly this floor to keep that invariant honest.
const kSkcodeWideBreakpoint = 1500.0;

/// Three-column tier floor (spec section 7: "Three-column (1200 to 1499)").
const kSkcodeThreeColumnBreakpoint = 1200.0;

/// Two-column tier floor (spec section 7: "Two-column (900 to 1199)").
const kSkcodeTwoColumnBreakpoint = 900.0;

/// The four-column tier's fixed rail width (spec section 7).
const kSkcodeRailColumnWidth = 280.0;

/// The four-column tier's fixed project-chat column width (spec section 7).
const kSkcodeChatColumnWidth = 320.0;

/// The four-column (and three-column, spec section 7: "the first tab of the
/// artifact pane") tier's fixed artifact-pane width (spec section 7).
const kSkcodeArtifactColumnWidth = 360.0;

/// The transcript's floor at the four-column tier (spec section 7:
/// "transcript flex, never below ~540"). See [kSkcodeWideBreakpoint]'s doc
/// comment for why this holds by construction rather than by clamping.
const kSkcodeTranscriptMinWidth = 540.0;

/// Pure classification, no widget/BuildContext dependency (unit-testable on
/// its own, card C-12 AC3: "all four breakpoint tiers implemented, driven by
/// LayoutBuilder on the pane's own width").
SkcodePaneTier skcodePaneTierForWidth(double width) {
  if (width >= kSkcodeWideBreakpoint) return SkcodePaneTier.wide;
  if (width >= kSkcodeThreeColumnBreakpoint) return SkcodePaneTier.threeColumn;
  if (width >= kSkcodeTwoColumnBreakpoint) return SkcodePaneTier.twoColumn;
  return SkcodePaneTier.phone;
}
