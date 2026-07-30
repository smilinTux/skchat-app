import 'package:flutter/material.dart';

import 'models/peer_trust.dart';
import 'theme/sovereign_colors.dart';

/// A small trust-tier badge for a conversation row (reconciled spec 3.2).
///
/// This is a package-pure reimplementation of the app's
/// `lib/features/identity/widgets/trust_badge.dart`, rendered with Sovereign
/// Glass tokens ([SovereignColors]) so it carries NO dependency on the app's
/// identity provider graph (the import gate, spec 3.2 step 4, forbids it).
/// Visual intent mirrors the app widget: a colored dot (red / amber / green),
/// with an optional text label when not [compact].
class TrustBadge extends StatelessWidget {
  const TrustBadge({
    super.key,
    required this.level,
    this.compact = true,
    this.label,
  });

  final PeerTrustLevel level;

  /// Compact renders just the dot (with a screen-reader label); non-compact
  /// also shows the tier text. Conversation rows use compact.
  final bool compact;

  /// Optional label override; null uses the tier default.
  final String? label;

  Color get _color => switch (level) {
        PeerTrustLevel.red => SovereignColors.accentDanger,
        PeerTrustLevel.amber => SovereignColors.accentWarning,
        PeerTrustLevel.green => SovereignColors.accentEncrypt,
      };

  String get _defaultLabel => switch (level) {
        PeerTrustLevel.red => 'Untrusted',
        PeerTrustLevel.amber => 'Provisional',
        PeerTrustLevel.green => 'Sovereign',
      };

  @override
  Widget build(BuildContext context) {
    final color = _color;
    final displayLabel = label ?? _defaultLabel;

    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Compact mode has no visible text, so announce the tier to screen
        // readers via Semantics (mirrors the app badge).
        if (compact)
          Semantics(label: _defaultLabel, child: dot)
        else ...[
          dot,
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              displayLabel,
              style:
                  Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
        ],
      ],
    );
  }
}
