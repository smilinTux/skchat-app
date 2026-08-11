import 'package:flutter/material.dart';
import 'sovereign_colors.dart';
import 'sovereign_density.dart';

/// Sovereign Glass typography, Inter Variable + JetBrains Mono for code.
///
/// Sizes, weights, and line heights are density-resolved
/// ([SovereignDensity]); see [SovereignDensityScale] for the per-role
/// tables. `comfortable` is BYTE-IDENTICAL to the pre-density PRD v1.0.0
/// numbers (the exact revert path); `compact` is the app default. PRD.md's
/// Typography section carries the amended, density-aware table alongside
/// this file, per the density spec's "documented contract" rule (this pass
/// changes numbers the PRD claims the theme "matches exactly").
class SovereignTypography {
  SovereignTypography._();

  static const String _fontFamily = 'Inter';
  static const String _monoFamily = 'JetBrainsMono';

  static TextTheme buildTextTheme({
    bool dark = true,
    SovereignDensity density = SovereignDensity.compact,
  }) {
    final baseColor = dark
        ? SovereignColors.textPrimary
        : const Color(0xFF1A1A2E);
    final mutedColor = dark
        ? SovereignColors.textSecondary
        : const Color(0xFF606080);
    final dimColor = dark
        ? SovereignColors.textTertiary
        : const Color(0xFF909090);

    final display = SovereignDensityScale.displayLarge.resolve(density);
    final tLarge = SovereignDensityScale.titleLarge.resolve(density);
    final tMedium = SovereignDensityScale.titleMedium.resolve(density);
    final tSmall = SovereignDensityScale.titleSmall.resolve(density);
    final bLarge = SovereignDensityScale.bodyLarge.resolve(density);
    final bMedium = SovereignDensityScale.bodyMedium.resolve(density);
    final bSmall = SovereignDensityScale.bodySmall.resolve(density);
    final lLarge = SovereignDensityScale.labelLarge.resolve(density);
    final lMedium = SovereignDensityScale.labelMedium.resolve(density);
    final lSmall = SovereignDensityScale.labelSmall.resolve(density);

    return TextTheme(
      // display
      displayLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: display.fontSize,
        fontWeight: FontWeight.w700,
        height: display.height,
        color: baseColor,
        letterSpacing: -0.5,
      ),
      // heading
      titleLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: tLarge.fontSize,
        fontWeight: FontWeight.w600,
        height: tLarge.height,
        color: baseColor,
        letterSpacing: -0.3,
      ),
      titleMedium: TextStyle(
        fontFamily: _fontFamily,
        fontSize: tMedium.fontSize,
        fontWeight: FontWeight.w600,
        height: tMedium.height,
        color: baseColor,
      ),
      titleSmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: tSmall.fontSize,
        fontWeight: FontWeight.w500,
        height: tSmall.height,
        color: baseColor,
      ),
      // body
      bodyLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: bLarge.fontSize,
        fontWeight: FontWeight.w400,
        height: bLarge.height,
        color: baseColor,
      ),
      bodyMedium: TextStyle(
        fontFamily: _fontFamily,
        fontSize: bMedium.fontSize,
        fontWeight: FontWeight.w400,
        height: bMedium.height,
        color: baseColor,
      ),
      bodySmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: bSmall.fontSize,
        fontWeight: FontWeight.w400,
        height: bSmall.height,
        color: mutedColor,
      ),
      // caption / label
      labelSmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: lSmall.fontSize,
        fontWeight: FontWeight.w400,
        height: lSmall.height,
        color: dimColor,
        letterSpacing: 0.1,
      ),
      labelMedium: TextStyle(
        fontFamily: _fontFamily,
        fontSize: lMedium.fontSize,
        fontWeight: FontWeight.w500,
        height: lMedium.height,
        color: mutedColor,
      ),
      labelLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: lLarge.fontSize,
        fontWeight: FontWeight.w600,
        height: lLarge.height,
        color: baseColor,
      ),
    );
  }

  /// Mono style used for fingerprints and code blocks. Density-resolved
  /// default size/height; pass [fontSize] to override the size explicitly
  /// (the height still follows density, since it is a line-height, not a
  /// literal the font-literal ratchet guard tracks).
  static TextStyle mono({
    double? fontSize,
    Color? color,
    SovereignDensity density = SovereignDensity.compact,
  }) {
    final scale = SovereignDensityScale.mono.resolve(density);
    return TextStyle(
      fontFamily: _monoFamily,
      fontSize: fontSize ?? scale.fontSize,
      fontWeight: FontWeight.w400,
      height: scale.height,
      color: color,
    );
  }

  /// `micro`, the meta workhorse: timestamps, badge-adjacent rows, event
  /// meta. NEW role (density spec 3.2): 11px at the default (compact)
  /// density, sanctioning the pre-existing `fontSize: 11` literals so the
  /// burn-down (D-2) has somewhere legal to land them.
  static TextStyle micro({
    bool dark = true,
    SovereignDensity density = SovereignDensity.compact,
  }) {
    final scale = SovereignDensityScale.micro.resolve(density);
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: scale.fontSize,
      fontWeight: FontWeight.w400,
      height: scale.height,
      color: dark ? SovereignColors.textTertiary : const Color(0xFF909090),
    );
  }

  /// `badge`, count/status badges. NEW role (density spec 3.2): 10px at the
  /// default (compact) density, floored there at every density (below 10
  /// fails practical touch-first legibility on a phone held at arm's
  /// length).
  static TextStyle badge({
    bool dark = true,
    SovereignDensity density = SovereignDensity.compact,
  }) {
    final scale = SovereignDensityScale.badge.resolve(density);
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: scale.fontSize,
      fontWeight: FontWeight.w500,
      height: scale.height,
      color: dark ? SovereignColors.textPrimary : const Color(0xFF1A1A2E),
    );
  }
}

/// Theme-extension home for the two NEW density-resolved roles ([micro],
/// [badge]) that do not fit Flutter's fixed [TextTheme] shape. Attached to
/// `ThemeData.extensions` alongside [SovereignSpacing] by [SovereignTheme],
/// so call sites read `Theme.of(context).extension<SovereignTypeExtras>()`
/// exactly like any other theme role, rather than calling
/// [SovereignTypography.micro]/[SovereignTypography.badge] directly with an
/// explicit density (widgets never read density directly).
@immutable
class SovereignTypeExtras extends ThemeExtension<SovereignTypeExtras> {
  const SovereignTypeExtras({required this.micro, required this.badge});

  final TextStyle micro;
  final TextStyle badge;

  factory SovereignTypeExtras.build({
    required bool dark,
    required SovereignDensity density,
  }) {
    return SovereignTypeExtras(
      micro: SovereignTypography.micro(dark: dark, density: density),
      badge: SovereignTypography.badge(dark: dark, density: density),
    );
  }

  @override
  SovereignTypeExtras copyWith({TextStyle? micro, TextStyle? badge}) {
    return SovereignTypeExtras(
      micro: micro ?? this.micro,
      badge: badge ?? this.badge,
    );
  }

  @override
  SovereignTypeExtras lerp(
    ThemeExtension<SovereignTypeExtras>? other,
    double t,
  ) {
    if (other is! SovereignTypeExtras) return this;
    return SovereignTypeExtras(
      micro: TextStyle.lerp(micro, other.micro, t) ?? micro,
      badge: TextStyle.lerp(badge, other.badge, t) ?? badge,
    );
  }
}
