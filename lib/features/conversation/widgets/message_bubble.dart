import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/theme.dart';
import '../../../core/chat_text.dart';
import '../../../models/attachment_ref.dart';
import '../../../models/chat_message.dart';
import 'file_transfer_bubble.dart';
import 'reaction_picker.dart';

/// How far (logical px) the user must drag right to trigger the reply action.
const double _kReplyThreshold = 72.0;

/// Message bubble per the PRD:
/// - Outbound (right): user's soul-color tint on glass surface
/// - Inbound (left): neutral glass with sender's soul-color left-edge accent line
/// - Rounded corners 16px
/// - Timestamp inside bubble, bottom-right, caption size
/// - Swipe right to trigger reply (calls [onReply])
/// - Long-press to open emoji reaction picker (calls [onReact])
/// - Reactions row shown below the bubble when [message.reactions] is non-empty
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.soulColor,
    this.userSoulColor = SovereignColors.soulChef,
    this.showSenderName = false,
    this.onReply,
    this.onReact,
  });

  final ChatMessage message;

  /// Sender's soul-color (inbound accent bar / outbound tint).
  final Color soulColor;

  /// Local user's soul-color (outbound bubble tint + delivery tick).
  final Color userSoulColor;

  /// Show sender name above bubble (group chats).
  final bool showSenderName;

  /// Called when the user completes a swipe-right-to-reply gesture.
  final VoidCallback? onReply;

  /// Called with the chosen emoji when the user long-presses and selects.
  final void Function(String emoji)? onReact;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  /// Horizontal drag offset while the user is actively swiping.
  double _dragOffset = 0.0;

  /// Reply icon opacity — fades in as the user approaches the threshold.
  double get _replyIconOpacity =>
      (_dragOffset / _kReplyThreshold).clamp(0.0, 1.0);

  /// True once we have fired the haptic/callback for this drag stroke.
  bool _replyTriggered = false;

  late AnimationController _snapController;
  late Animation<double> _snapAnimation;
  double _snapStartOffset = 0.0;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _snapAnimation = CurvedAnimation(
      parent: _snapController,
      curve: Curves.elasticOut,
    );
    _snapController.addListener(() {
      setState(() {
        _dragOffset = _snapStartOffset * (1 - _snapAnimation.value);
      });
    });
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    // Only allow right-swipe (positive dx).
    final newOffset = (_dragOffset + details.delta.dx).clamp(0.0, _kReplyThreshold * 1.1);
    setState(() => _dragOffset = newOffset);

    if (!_replyTriggered && _dragOffset >= _kReplyThreshold) {
      _replyTriggered = true;
      HapticFeedback.selectionClick();
    }
  }

  void _onHorizontalDragEnd(DragEndDetails _) {
    final didTrigger = _replyTriggered;
    _replyTriggered = false;

    // Snap back to zero with spring.
    _snapStartOffset = _dragOffset;
    _snapController.forward(from: 0);

    if (didTrigger) {
      widget.onReply?.call();
    }
  }

  void _onHorizontalDragCancel() {
    _replyTriggered = false;
    _snapStartOffset = _dragOffset;
    _snapController.forward(from: 0);
  }

  void _onLongPress(BuildContext context) {
    // Find the bubble's position on screen so the picker can anchor to it.
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;

    final topLeft = box.localToGlobal(Offset.zero);
    final anchorRect = topLeft & box.size;

    showReactionPicker(
      context: context,
      anchorRect: anchorRect,
      soulColor: widget.soulColor,
      onSelect: (emoji) => widget.onReact?.call(emoji),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOut = widget.message.isOutbound;

    return GestureDetector(
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onHorizontalDragCancel: _onHorizontalDragCancel,
      onLongPress: () => _onLongPress(context),
      child: Transform.translate(
        offset: Offset(_dragOffset, 0),
        child: Padding(
          padding: EdgeInsets.only(
            left: isOut ? 60 : 12,
            right: isOut ? 12 : 60,
            top: 3,
            bottom: 3,
          ),
          child: Row(
            mainAxisAlignment:
                isOut ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Reply icon revealed on swipe
              if (!isOut) ...[
                Opacity(
                  opacity: _replyIconOpacity,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.reply_rounded,
                      size: 20,
                      color: widget.soulColor,
                    ),
                  ),
                ),
              ],

              Flexible(
                child: Column(
                  crossAxisAlignment:
                      isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    // Optional sender name (group chats)
                    if (widget.showSenderName && !isOut) ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 2),
                        child: Text(
                          widget.message.senderName ?? 'Unknown',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: widget.soulColor,
                          ),
                        ),
                      ),
                    ],

                    // Bubble
                    _BubbleContent(
                      message: widget.message,
                      soulColor: widget.soulColor,
                      userSoulColor: widget.userSoulColor,
                    ),

                    // Reactions row
                    if (widget.message.reactions.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _ReactionsRow(
                        reactions: widget.message.reactions,
                        soulColor: widget.soulColor,
                      ),
                    ],
                  ],
                ),
              ),

              // Reply icon on the right side for outbound bubbles
              if (isOut) ...[
                Opacity(
                  opacity: _replyIconOpacity,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.reply_rounded,
                      size: 20,
                      color: widget.userSoulColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bubble content (extracted for clarity)

class _BubbleContent extends StatelessWidget {
  const _BubbleContent({
    required this.message,
    required this.soulColor,
    required this.userSoulColor,
  });

  final ChatMessage message;
  final Color soulColor;
  final Color userSoulColor;

  @override
  Widget build(BuildContext context) {
    final isOut = message.isOutbound;
    final tt = Theme.of(context).textTheme;

    // Attachment messages carry a small __ATTACH__ sentinel body. Render a
    // file-transfer card (with thumbnail + tap-to-download) instead of text.
    final attachment = AttachmentRef.parse(message.content);
    if (attachment != null) {
      return _AttachmentBubble(
        attachment: attachment,
        isOut: isOut,
        soulColor: soulColor,
        userSoulColor: userSoulColor,
        timestamp: message.timestamp,
        deliveryStatus: message.deliveryStatus,
        isAgent: message.isAgent,
      );
    }

    final display = displayTextFor(message.content);

    // Non-displayable (empty / system / raw envelope / control / prompt-echo):
    // hide entirely so it doesn't clutter the thread.
    if (display == null) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: isOut
            ? userSoulColor.withValues(alpha: 0.18)
            : SovereignColors.surfaceGlass,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isOut ? 16 : 4),
          bottomRight: Radius.circular(isOut ? 4 : 16),
        ),
        // NOTE: a non-uniform Border (e.g. a thicker left accent) combined with
        // borderRadius throws a rendering exception that aborts painting the
        // whole bubble — its text included. Keep the border uniform.
        border: Border.all(
          color: isOut
              ? userSoulColor.withValues(alpha: 0.3)
              : soulColor.withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Explicit, theme-independent text style. Using tt.bodyMedium here
          // resolved to an invisible style in this subtree (the bubble text
          // disappeared); a self-contained TextStyle with an explicit light
          // color renders reliably on the near-black glass bubble.
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              display,
              style: const TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 15,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 4),

          // Timestamp + delivery row
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateFormat('h:mm a').format(message.timestamp.toLocal()),
                style: tt.labelSmall?.copyWith(color: SovereignColors.textTertiary),
              ),
              if (isOut) ...[
                const SizedBox(width: 4),
                DeliveryStatus(
                  status: message.deliveryStatus,
                  soulColor: userSoulColor,
                ),
              ] else if (message.isAgent) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.auto_awesome,
                  size: 11,
                  color: soulColor.withValues(alpha: 0.6),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Attachment bubble — renders a FileTransferBubble inside the glass surface.

class _AttachmentBubble extends StatelessWidget {
  const _AttachmentBubble({
    required this.attachment,
    required this.isOut,
    required this.soulColor,
    required this.userSoulColor,
    required this.timestamp,
    required this.deliveryStatus,
    required this.isAgent,
  });

  final AttachmentRef attachment;
  final bool isOut;
  final Color soulColor;
  final Color userSoulColor;
  final DateTime timestamp;
  final String deliveryStatus;
  final bool isAgent;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final accent = isOut ? userSoulColor : soulColor;

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      decoration: BoxDecoration(
        color: isOut
            ? userSoulColor.withValues(alpha: 0.18)
            : SovereignColors.surfaceGlass,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isOut ? 16 : 4),
          bottomRight: Radius.circular(isOut ? 4 : 16),
        ),
        border: Border.all(
          color: accent.withValues(alpha: isOut ? 0.3 : 0.45),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FileTransferBubble(
            transferId: attachment.transferId,
            fileName: attachment.filename,
            fileSize: attachment.size,
            soulColor: accent,
            isImage: attachment.isImage,
            caption: attachment.caption,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                DateFormat('h:mm a').format(timestamp.toLocal()),
                style:
                    tt.labelSmall?.copyWith(color: SovereignColors.textTertiary),
              ),
              if (isOut) ...[
                const SizedBox(width: 4),
                DeliveryStatus(status: deliveryStatus, soulColor: userSoulColor),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reactions row

class _ReactionsRow extends StatelessWidget {
  const _ReactionsRow({
    required this.reactions,
    required this.soulColor,
  });

  final Map<String, int> reactions;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: reactions.entries.map((e) {
        return _ReactionPill(emoji: e.key, count: e.value, soulColor: soulColor);
      }).toList(),
    );
  }
}

class _ReactionPill extends StatefulWidget {
  const _ReactionPill({
    required this.emoji,
    required this.count,
    required this.soulColor,
  });

  final String emoji;
  final int count;
  final Color soulColor;

  @override
  State<_ReactionPill> createState() => _ReactionPillState();
}

class _ReactionPillState extends State<_ReactionPill>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.3)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.3, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 50,
      ),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTap() {
    HapticFeedback.mediumImpact();
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _onTap,
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: widget.soulColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: widget.soulColor.withValues(alpha: 0.28),
              width: 1,
            ),
          ),
          child: Text(
            '${widget.emoji} ${widget.count}',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }
}
