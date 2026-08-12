import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'sovereign_density.dart';

/// Canonical 4-pt spacing ladder (density spec section 4). Density-
/// INDEPENDENT raw steps for ad hoc use. Prefer the density-resolved
/// SEMANTIC tokens on [SovereignSpacing] below for anything that should
/// shrink with density; these are the values that actually create felt
/// density.
class SovereignSpacingLadder {
  SovereignSpacingLadder._();

  static const double s2 = 2;
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
}

/// Density-resolved semantic spacing tokens (density spec section 4).
///
/// Threaded into `ThemeData.extensions` so widgets read
/// `Theme.of(context).extension<SovereignSpacing>()` instead of taking a
/// density parameter directly; density is a theme concern, not a widget
/// concern (widgets never read density directly, they read theme roles and
/// spacing tokens).
///
/// Touch target floor: 48x48dp is held at EVERY density (PRD accessibility
/// contract). Density shrinks the visual row, never the tap area:
/// `MaterialTapTargetSize.padded` stays Flutter's default at every density
/// (not overridden here), and this is a review rule for any custom
/// InkWell/GestureDetector row, not something these tokens enforce.
@immutable
class SovereignSpacing extends ThemeExtension<SovereignSpacing> {
  const SovereignSpacing({
    required this.density,
    required this.rowVPad,
    required this.cardPad,
    required this.gutter,
    required this.sectionGap,
    required this.listTileContentPaddingV,
    required this.listTileMinHeight,
    required this.navCellVPad,
    required this.avatarList,
    required this.iconNav,
  });

  final SovereignDensity density;

  /// List rows, transcript rows.
  final double rowVPad;

  /// GlassCard default padding.
  final double cardPad;

  /// Screen edge padding.
  final double gutter;

  /// Between sections.
  final double sectionGap;

  /// ListTileThemeData.contentPadding vertical.
  final double listTileContentPaddingV;

  /// ListTileThemeData.minTileHeight. `null` at comfortable, so Material's
  /// own default height applies unmodified (byte-identical revert path).
  final double? listTileMinHeight;

  /// Bottom nav cells.
  final double navCellVPad;

  /// List row avatars.
  final double avatarList;

  /// Nav icons, held at 24 on touch (comfortable + compact); only dense
  /// (a desktop/rail-oriented density) steps it down.
  final double iconNav;

  factory SovereignSpacing.forDensity(SovereignDensity density) {
    switch (density) {
      case SovereignDensity.comfortable:
        return const SovereignSpacing(
          density: SovereignDensity.comfortable,
          rowVPad: 8,
          cardPad: 16,
          gutter: 16,
          sectionGap: 24,
          listTileContentPaddingV: 4,
          listTileMinHeight: null,
          navCellVPad: 10,
          avatarList: 40,
          iconNav: 24,
        );
      case SovereignDensity.compact:
        return const SovereignSpacing(
          density: SovereignDensity.compact,
          rowVPad: 6,
          cardPad: 12,
          gutter: 12,
          sectionGap: 16,
          listTileContentPaddingV: 2,
          listTileMinHeight: 44,
          navCellVPad: 8,
          avatarList: 36,
          iconNav: 24,
        );
      case SovereignDensity.dense:
        return const SovereignSpacing(
          density: SovereignDensity.dense,
          rowVPad: 4,
          cardPad: 10,
          gutter: 12,
          sectionGap: 12,
          listTileContentPaddingV: 0,
          listTileMinHeight: 40,
          navCellVPad: 8,
          avatarList: 32,
          iconNav: 22,
        );
    }
  }

  @override
  SovereignSpacing copyWith({
    SovereignDensity? density,
    double? rowVPad,
    double? cardPad,
    double? gutter,
    double? sectionGap,
    double? listTileContentPaddingV,
    double? listTileMinHeight,
    double? navCellVPad,
    double? avatarList,
    double? iconNav,
  }) {
    return SovereignSpacing(
      density: density ?? this.density,
      rowVPad: rowVPad ?? this.rowVPad,
      cardPad: cardPad ?? this.cardPad,
      gutter: gutter ?? this.gutter,
      sectionGap: sectionGap ?? this.sectionGap,
      listTileContentPaddingV:
          listTileContentPaddingV ?? this.listTileContentPaddingV,
      listTileMinHeight: listTileMinHeight ?? this.listTileMinHeight,
      navCellVPad: navCellVPad ?? this.navCellVPad,
      avatarList: avatarList ?? this.avatarList,
      iconNav: iconNav ?? this.iconNav,
    );
  }

  @override
  SovereignSpacing lerp(ThemeExtension<SovereignSpacing>? other, double t) {
    if (other is! SovereignSpacing) return this;
    return SovereignSpacing(
      density: t < 0.5 ? density : other.density,
      rowVPad: lerpDouble(rowVPad, other.rowVPad, t)!,
      cardPad: lerpDouble(cardPad, other.cardPad, t)!,
      gutter: lerpDouble(gutter, other.gutter, t)!,
      sectionGap: lerpDouble(sectionGap, other.sectionGap, t)!,
      listTileContentPaddingV: lerpDouble(
        listTileContentPaddingV,
        other.listTileContentPaddingV,
        t,
      )!,
      listTileMinHeight: lerpDouble(
        listTileMinHeight ?? 56,
        other.listTileMinHeight ?? 56,
        t,
      ),
      navCellVPad: lerpDouble(navCellVPad, other.navCellVPad, t)!,
      avatarList: lerpDouble(avatarList, other.avatarList, t)!,
      iconNav: lerpDouble(iconNav, other.iconNav, t)!,
    );
  }
}
