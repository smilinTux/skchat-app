import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/theme.dart';

void main() {
  group('SovereignDensity.comfortable is byte-identical to the pre-density scale', () {
    // The exact numbers `sovereign_typography.dart` hardcoded before this
    // pass (card D-1). `comfortable` exists so this table is the app's
    // exact revert path; if any of these regress, the revert path is
    // broken.
    final textTheme = SovereignTypography.buildTextTheme(
      dark: true,
      density: SovereignDensity.comfortable,
    );

    test('displayLarge: 28sp w700 height 1.2', () {
      expect(textTheme.displayLarge?.fontSize, 28);
      expect(textTheme.displayLarge?.fontWeight, FontWeight.w700);
      expect(textTheme.displayLarge?.height, 1.2);
      expect(textTheme.displayLarge?.letterSpacing, -0.5);
    });

    test('titleLarge: 20sp w600 height 1.3', () {
      expect(textTheme.titleLarge?.fontSize, 20);
      expect(textTheme.titleLarge?.fontWeight, FontWeight.w600);
      expect(textTheme.titleLarge?.height, 1.3);
      expect(textTheme.titleLarge?.letterSpacing, -0.3);
    });

    test('titleMedium: 17sp w600 height 1.3', () {
      expect(textTheme.titleMedium?.fontSize, 17);
      expect(textTheme.titleMedium?.fontWeight, FontWeight.w600);
      expect(textTheme.titleMedium?.height, 1.3);
    });

    test('titleSmall: 15sp w500 height 1.4', () {
      expect(textTheme.titleSmall?.fontSize, 15);
      expect(textTheme.titleSmall?.fontWeight, FontWeight.w500);
      expect(textTheme.titleSmall?.height, 1.4);
    });

    test('bodyLarge: 15sp w400 height 1.5', () {
      expect(textTheme.bodyLarge?.fontSize, 15);
      expect(textTheme.bodyLarge?.fontWeight, FontWeight.w400);
      expect(textTheme.bodyLarge?.height, 1.5);
    });

    test('bodyMedium: 14sp w400 height 1.5', () {
      expect(textTheme.bodyMedium?.fontSize, 14);
      expect(textTheme.bodyMedium?.fontWeight, FontWeight.w400);
      expect(textTheme.bodyMedium?.height, 1.5);
    });

    test('bodySmall: 13sp w400 height 1.5', () {
      expect(textTheme.bodySmall?.fontSize, 13);
      expect(textTheme.bodySmall?.fontWeight, FontWeight.w400);
      expect(textTheme.bodySmall?.height, 1.5);
    });

    test('labelSmall (caption): 12sp w400 height 1.4', () {
      expect(textTheme.labelSmall?.fontSize, 12);
      expect(textTheme.labelSmall?.fontWeight, FontWeight.w400);
      expect(textTheme.labelSmall?.height, 1.4);
      expect(textTheme.labelSmall?.letterSpacing, 0.1);
    });

    test('labelMedium: 13sp w500 height 1.4', () {
      expect(textTheme.labelMedium?.fontSize, 13);
      expect(textTheme.labelMedium?.fontWeight, FontWeight.w500);
      expect(textTheme.labelMedium?.height, 1.4);
    });

    test('labelLarge: 14sp w600 height 1.4', () {
      expect(textTheme.labelLarge?.fontSize, 14);
      expect(textTheme.labelLarge?.fontWeight, FontWeight.w600);
      expect(textTheme.labelLarge?.height, 1.4);
    });

    test('mono default: 13sp height 1.5', () {
      final mono = SovereignTypography.mono(density: SovereignDensity.comfortable);
      expect(mono.fontSize, 13);
      expect(mono.height, 1.5);
    });

    test('mono explicit fontSize override still wins over density default',
        () {
      final mono = SovereignTypography.mono(
        fontSize: 18,
        density: SovereignDensity.comfortable,
      );
      expect(mono.fontSize, 18);
    });
  });

  group('SovereignDensity.compact is the app default', () {
    final textTheme = SovereignTypography.buildTextTheme(); // no args

    test('buildTextTheme() defaults to compact, not comfortable', () {
      expect(textTheme.displayLarge?.fontSize, 24);
      expect(textTheme.bodyMedium?.fontSize, 13);
    });

    test('SovereignTheme.dark()/light() default to compact', () {
      final dark = SovereignTheme.dark();
      expect(dark.textTheme.displayLarge?.fontSize, 24);
      final light = SovereignTheme.light();
      expect(light.textTheme.displayLarge?.fontSize, 24);
    });
  });

  group('NEW roles: micro and badge', () {
    test('micro is 11 at compact, 12 at comfortable, 10 at dense', () {
      expect(
        SovereignTypography.micro(density: SovereignDensity.compact).fontSize,
        11,
      );
      expect(
        SovereignTypography.micro(density: SovereignDensity.comfortable)
            .fontSize,
        12,
      );
      expect(
        SovereignTypography.micro(density: SovereignDensity.dense).fontSize,
        10,
      );
    });

    test('badge is 10 at compact AND dense (floored), 11 at comfortable', () {
      expect(
        SovereignTypography.badge(density: SovereignDensity.compact).fontSize,
        10,
      );
      expect(
        SovereignTypography.badge(density: SovereignDensity.dense).fontSize,
        10,
      );
      expect(
        SovereignTypography.badge(density: SovereignDensity.comfortable)
            .fontSize,
        11,
      );
    });

    test('badge never renders below the 10px legibility floor', () {
      for (final d in SovereignDensity.values) {
        expect(SovereignTypography.badge(density: d).fontSize, greaterThanOrEqualTo(10));
        expect(SovereignTypography.micro(density: d).fontSize, greaterThanOrEqualTo(10));
      }
    });

    test('SovereignTheme attaches SovereignTypeExtras with micro + badge',
        () {
      final theme = SovereignTheme.dark(density: SovereignDensity.compact);
      final extras = theme.extension<SovereignTypeExtras>();
      expect(extras, isNotNull);
      expect(extras!.micro.fontSize, 11);
      expect(extras.badge.fontSize, 10);
    });
  });

  group('SovereignSpacing density resolution', () {
    test('comfortable does not override listTileMinHeight (Material default)',
        () {
      final spacing = SovereignSpacing.forDensity(SovereignDensity.comfortable);
      expect(spacing.listTileMinHeight, isNull);
      expect(spacing.listTileContentPaddingV, 4); // pre-density hardcoded value
      expect(spacing.cardPad, 16); // pre-density GlassCard default
    });

    test('compact tightens rowVPad, cardPad, gutter, sectionGap', () {
      final comfortable =
          SovereignSpacing.forDensity(SovereignDensity.comfortable);
      final compact = SovereignSpacing.forDensity(SovereignDensity.compact);
      final dense = SovereignSpacing.forDensity(SovereignDensity.dense);

      expect(compact.rowVPad, lessThan(comfortable.rowVPad));
      expect(compact.cardPad, lessThan(comfortable.cardPad));
      expect(compact.gutter, lessThanOrEqualTo(comfortable.gutter));
      expect(compact.sectionGap, lessThan(comfortable.sectionGap));

      expect(dense.rowVPad, lessThanOrEqualTo(compact.rowVPad));
      expect(dense.cardPad, lessThanOrEqualTo(compact.cardPad));
      expect(dense.sectionGap, lessThanOrEqualTo(compact.sectionGap));
    });

    test('SovereignTheme threads density into listTileTheme', () {
      final comfortable = SovereignTheme.dark(density: SovereignDensity.comfortable);
      final compact = SovereignTheme.dark(density: SovereignDensity.compact);
      final dense = SovereignTheme.dark(density: SovereignDensity.dense);

      expect(comfortable.listTileTheme.minTileHeight, isNull);
      expect(compact.listTileTheme.minTileHeight, 44);
      expect(dense.listTileTheme.minTileHeight, 40);

      expect(
        comfortable.listTileTheme.contentPadding,
        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      );
      expect(
        compact.listTileTheme.contentPadding,
        const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      );
    });

    test('SovereignTheme wires visualDensity per density', () {
      expect(
        SovereignTheme.dark(density: SovereignDensity.comfortable)
            .visualDensity,
        VisualDensity.standard,
      );
      expect(
        SovereignTheme.dark(density: SovereignDensity.compact).visualDensity,
        const VisualDensity(horizontal: -1, vertical: -1),
      );
      expect(
        SovereignTheme.dark(density: SovereignDensity.dense).visualDensity,
        const VisualDensity(horizontal: -2, vertical: -2),
      );
    });
  });
}
