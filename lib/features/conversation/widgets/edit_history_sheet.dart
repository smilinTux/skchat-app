import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/theme.dart';
import '../../../models/chat_message.dart';

/// Bottom-sheet showing a message's edit history (oldest revision -> current),
/// opened when the user taps the "edited" badge.
Future<void> showEditHistory({
  required BuildContext context,
  required ChatMessage message,
  required Color soulColor,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _EditHistorySheet(message: message, soulColor: soulColor),
  );
}

class _EditHistorySheet extends StatelessWidget {
  const _EditHistorySheet({required this.message, required this.soulColor});

  final ChatMessage message;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    // Oldest revision first, then each subsequent edit, ending with current.
    final revisions = <String>[...message.editHistory, message.content];

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: SovereignColors.surfaceRaised.withValues(alpha: 0.96),
            border: Border(
              top: BorderSide(color: soulColor.withValues(alpha: 0.25)),
            ),
          ),
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            16 + MediaQuery.of(context).padding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: SovereignColors.textTertiary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.history, size: 18, color: soulColor),
                  const SizedBox(width: 8),
                  Text(
                    'Edit history',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: SovereignColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  if (message.editedAt != null)
                    Text(
                      'edited ${DateFormat('MMM d, h:mm a').format(message.editedAt!.toLocal())}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: SovereignColors.textTertiary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: revisions.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final isCurrent = i == revisions.length - 1;
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? soulColor.withValues(alpha: 0.12)
                            : SovereignColors.surfaceGlass,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isCurrent
                              ? soulColor.withValues(alpha: 0.3)
                              : SovereignColors.surfaceGlassBorder,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isCurrent ? 'Current' : 'Revision ${i + 1}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: isCurrent
                                  ? soulColor
                                  : SovereignColors.textTertiary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            revisions[i],
                            style: const TextStyle(
                              fontSize: 14,
                              color: SovereignColors.textPrimary,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
