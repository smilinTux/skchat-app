import 'package:flutter/material.dart';
import 'package:skchat/core/theme/sovereign_colors.dart';
import 'package:skchat/services/self_identity.dart';

/// A small reusable badge widget that displays trust tier visually.
/// Renders a colored dot (red/amber/green) plus optional text label.
/// Pure presentational - no identity provider imports.
class TrustBadge extends StatelessWidget {
  const TrustBadge({
    required this.tier,
    this.compact = false,
    this.label,
  });

  final SelfTrustTier tier;
  final bool compact;
  final String? label;

  /// Returns the color for this tier.
  Color _getTierColor() {
    return switch (tier) {
      SelfTrustTier.red => SovereignColors.accentDanger,
      SelfTrustTier.amber => SovereignColors.accentWarning,
      SelfTrustTier.green => SovereignColors.accentEncrypt,
    };
  }

  /// Returns the default label for this tier.
  String _getDefaultLabel() {
    return switch (tier) {
      SelfTrustTier.red => 'Untrusted',
      SelfTrustTier.amber => 'Provisional',
      SelfTrustTier.green => 'Sovereign',
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _getTierColor();
    final displayLabel = label ?? _getDefaultLabel();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Colored dot
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        // Optional text label
        if (!compact)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              displayLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                  ),
            ),
          ),
      ],
    );
  }
}
