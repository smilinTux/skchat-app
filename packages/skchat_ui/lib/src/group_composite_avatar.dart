import 'package:flutter/material.dart';

import 'models/conversation.dart';
import 'theme/sovereign_colors.dart';

/// Composite avatar for a group conversation tile (reconciled spec 3.2).
///
/// Package-pure reimplementation of the app's
/// `lib/features/chats/widgets/group_composite_avatar.dart`: up to 3 stacked
/// soul-color initial chips derived purely from the [members] list, falling
/// back to a single group-icon disc when there are no members. No providers,
/// so it is cheap to rebuild inside a ListView and trivially widget-testable,
/// and it stays inside the import gate (Sovereign Glass tokens only).
class GroupCompositeAvatar extends StatelessWidget {
  const GroupCompositeAvatar({
    super.key,
    required this.members,
    required this.fallbackColor,
    this.size = 48,
  });

  final List<ConversationMember> members;
  final Color fallbackColor;
  final double size;

  Color _memberColor(ConversationMember m) {
    final fp = m.soulFingerprint;
    if (fp != null && fp.isNotEmpty) {
      return SovereignColors.fromFingerprint(fp);
    }
    return fallbackColor;
  }

  String _initial(ConversationMember m) {
    final n = m.displayName.trim();
    return n.isNotEmpty ? n[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border:
              Border.all(color: fallbackColor.withValues(alpha: 0.6), width: 2),
          color: fallbackColor.withValues(alpha: 0.12),
        ),
        child: Center(
          child: Icon(Icons.group_rounded,
              color: fallbackColor, size: size * 0.46),
        ),
      );
    }

    final shown = members.take(3).toList();
    final chip = size * 0.62;
    // Two anchor points on the top row, one centered below, so 1-3 chips all
    // read as a cluster within the standard 48px avatar footprint.
    final offsets = <Offset>[
      const Offset(0, 0),
      Offset(size - chip, 0),
      Offset((size - chip) / 2, size - chip),
    ];

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: offsets[i].dx,
              top: offsets[i].dy,
              child: _InitialChip(
                initial: _initial(shown[i]),
                color: _memberColor(shown[i]),
                diameter: chip,
              ),
            ),
        ],
      ),
    );
  }
}

class _InitialChip extends StatelessWidget {
  const _InitialChip({
    required this.initial,
    required this.color,
    required this.diameter,
  });

  final String initial;
  final Color color;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.22),
        border: Border.all(color: SovereignColors.surfaceBase, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontSize: diameter * 0.42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
