/// Three density levels for the Sovereign Glass type + spacing system.
///
/// `compact` is the app default (Chef's "fonts are too big" fix, confirmed
/// explicitly). `comfortable` is BYTE-IDENTICAL to the pre-density scale, so
/// it is the exact revert path if a real phone ever needs it. `dense` is an
/// opt-in for desktop/rail layouts.
///
/// Per the density spec
/// (`~/clawd/skos/docs/specs/2026-08-11-skworld-density-and-type-scale.md`,
/// section 3.3): deliberately explicit per-role lookup tables, NOT a float
/// multiplier. A multiplier produces 12.42px garbage and makes the literal
/// ratchet guard (`test/font_literal_guard_test.dart`) unenforceable.
enum SovereignDensity { comfortable, compact, dense }

/// One role's resolved font size + line height at a given density.
class SovereignTypeSize {
  const SovereignTypeSize(this.fontSize, this.height);

  final double fontSize;
  final double height;
}

/// A role's three density-resolved sizes, looked up (never computed) per
/// [SovereignDensity].
class SovereignTypeScale {
  const SovereignTypeScale({
    required this.comfortable,
    required this.compact,
    required this.dense,
  });

  final SovereignTypeSize comfortable;
  final SovereignTypeSize compact;
  final SovereignTypeSize dense;

  SovereignTypeSize resolve(SovereignDensity density) {
    switch (density) {
      case SovereignDensity.comfortable:
        return comfortable;
      case SovereignDensity.compact:
        return compact;
      case SovereignDensity.dense:
        return dense;
    }
  }
}

/// Per-role type scale tables.
///
/// The `comfortable` and `compact` columns are the density spec's section
/// 3.2 table, verbatim. `comfortable` reproduces the pre-density
/// `sovereign_typography.dart` numbers exactly (see
/// `test/core/theme/sovereign_density_test.dart`,
/// "comfortable is byte-identical to the pre-density scale").
///
/// `dense` font sizes are also spec verbatim. Dense LINE HEIGHTS are not
/// given in the spec table (it only documents the comfortable -> compact
/// delta); each row below continues that same per-step delta into the dense
/// column, except where the spec states a rule directly (body text holds
/// 1.5 at every density "for chat readability"; badge is spec-floored at 10
/// for both compact and dense, so its height holds too). This is a
/// documented interpolation, not a spec number, and is called out in the
/// D-1 landing report for review.
class SovereignDensityScale {
  SovereignDensityScale._();

  static const displayLarge = SovereignTypeScale(
    comfortable: SovereignTypeSize(28, 1.2),
    compact: SovereignTypeSize(24, 1.15),
    dense: SovereignTypeSize(22, 1.10),
  );

  static const titleLarge = SovereignTypeScale(
    comfortable: SovereignTypeSize(20, 1.3),
    compact: SovereignTypeSize(18, 1.25),
    dense: SovereignTypeSize(16, 1.20),
  );

  static const titleMedium = SovereignTypeScale(
    comfortable: SovereignTypeSize(17, 1.3),
    compact: SovereignTypeSize(15, 1.3),
    dense: SovereignTypeSize(14, 1.3),
  );

  static const titleSmall = SovereignTypeScale(
    comfortable: SovereignTypeSize(15, 1.4),
    compact: SovereignTypeSize(14, 1.35),
    dense: SovereignTypeSize(13, 1.30),
  );

  // Body text keeps 1.5 for chat readability at every density (spec 3.2).
  static const bodyLarge = SovereignTypeScale(
    comfortable: SovereignTypeSize(15, 1.5),
    compact: SovereignTypeSize(14, 1.5),
    dense: SovereignTypeSize(13, 1.5),
  );

  static const bodyMedium = SovereignTypeScale(
    comfortable: SovereignTypeSize(14, 1.5),
    compact: SovereignTypeSize(13, 1.5),
    dense: SovereignTypeSize(12, 1.5),
  );

  static const bodySmall = SovereignTypeScale(
    comfortable: SovereignTypeSize(13, 1.5),
    compact: SovereignTypeSize(12, 1.45),
    dense: SovereignTypeSize(11, 1.40),
  );

  static const labelLarge = SovereignTypeScale(
    comfortable: SovereignTypeSize(14, 1.4),
    compact: SovereignTypeSize(13, 1.35),
    dense: SovereignTypeSize(12, 1.30),
  );

  static const labelMedium = SovereignTypeScale(
    comfortable: SovereignTypeSize(13, 1.4),
    compact: SovereignTypeSize(12, 1.3),
    dense: SovereignTypeSize(11, 1.2),
  );

  static const labelSmall = SovereignTypeScale(
    comfortable: SovereignTypeSize(12, 1.4),
    compact: SovereignTypeSize(11, 1.3),
    dense: SovereignTypeSize(10, 1.2),
  );

  static const mono = SovereignTypeScale(
    comfortable: SovereignTypeSize(13, 1.5),
    compact: SovereignTypeSize(12.5, 1.45),
    dense: SovereignTypeSize(12, 1.40),
  );

  // NEW roles (spec 3.2): no `comfortable` precedent exists because these
  // roles did not exist before this pass. The comfortable values below
  // continue the same "one step roomier than compact" relationship every
  // other role shows, so `comfortable` still reads as the spacious floor;
  // `compact`/`dense` are spec verbatim.
  static const micro = SovereignTypeScale(
    comfortable: SovereignTypeSize(12, 1.35),
    compact: SovereignTypeSize(11, 1.3),
    dense: SovereignTypeSize(10, 1.25),
  );

  static const badge = SovereignTypeScale(
    comfortable: SovereignTypeSize(11, 1.25),
    compact: SovereignTypeSize(10, 1.2),
    // Spec floors badge at 10 for BOTH compact and dense (below 10 fails
    // practical touch-first legibility), so dense holds compact's height too.
    dense: SovereignTypeSize(10, 1.2),
  );
}
