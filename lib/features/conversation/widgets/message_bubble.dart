import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/theme.dart';
import '../../../models/attachment_ref.dart';
import '../../../models/chat_message.dart';
import 'edit_history_sheet.dart';
import 'file_transfer_bubble.dart';
import 'message_actions_sheet.dart';
import 'message_content.dart';
import 'quoted_reply.dart';

/// How far (logical px) the user must drag horizontally to trigger reply.
const double _kReplyThreshold = 72.0;

/// Message bubble -- the message-row interaction kit:
/// - Swipe (right for inbound, left for outbound) to reply -> [onReply]
/// - Long-press -> actions sheet (React/Reply/Edit/Copy) + reaction tray
/// - Double-tap an own message -> inline edit -> [onEdit]
/// - Reaction chips below the bubble; tap a chip to toggle -> [onReact]
/// - Quoted-reply rendered above the body when [message.replyToId] resolves
/// - "edited" badge + tap-for-history; delivery/read receipts on own messages
/// - Thread affordance when the message belongs to a thread -> [onOpenThread]
/// - Body rendered by content_type (golden rule) via [MessageContent]
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.soulColor,
    this.userSoulColor = SovereignColors.soulChef,
    this.showSenderName = false,
    this.repliedTo,
    this.myIdentity = 'me',
    this.onReply,
    this.onReact,
    this.onEdit,
    this.onJumpToReplied,
    this.onOpenThread,
  });

  final ChatMessage message;

  /// Sender's soul-color (inbound accent / outbound tint).
  final Color soulColor;

  /// Local user's soul-color (outbound bubble tint + delivery tick).
  final Color userSoulColor;

  /// Show sender name above bubble (group chats).
  final bool showSenderName;

  /// The resolved message this one replies to (for the quoted block), or null.
  final ChatMessage? repliedTo;

  /// The local operator's short identity (highlights chips we reacted to).
  final String myIdentity;

  /// Called when the user completes a swipe-to-reply gesture.
  final VoidCallback? onReply;

  /// Called with the chosen emoji when the user reacts (tap chip / pick).
  final void Function(String emoji)? onReact;

  /// Called with the new body when the user edits an own message.
  final void Function(String newBody)? onEdit;

  /// Called when the user taps the quoted-reply block (scroll to original).
  final VoidCallback? onJumpToReplied;

  /// Called when the user taps the thread affordance.
  final VoidCallback? onOpenThread;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  double _dragOffset = 0.0;
  bool _replyTriggered = false;

  late AnimationController _snapController;
  late Animation<double> _snapAnimation;
  double _snapStartOffset = 0.0;

  /// Swipe direction: inbound swipes right (+), outbound swipes left (-).
  double get _dir => widget.message.isOutbound ? -1.0 : 1.0;

  double get _replyIconOpacity =>
      (_dragOffset.abs() / _kReplyThreshold).clamp(0.0, 1.0);

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
    // Only allow swiping in the reply direction.
    final raw = _dragOffset + details.delta.dx;
    final clamped = _dir > 0
        ? raw.clamp(0.0, _kReplyThreshold * 1.1)
        : raw.clamp(-_kReplyThreshold * 1.1, 0.0);
    setState(() => _dragOffset = clamped);

    if (!_replyTriggered && _dragOffset.abs() >= _kReplyThreshold) {
      _replyTriggered = true;
      HapticFeedback.selectionClick();
    }
  }

  void _onHorizontalDragEnd(DragEndDetails _) {
    final didTrigger = _replyTriggered;
    _replyTriggered = false;
    _snapStartOffset = _dragOffset;
    _snapController.forward(from: 0);
    if (didTrigger) widget.onReply?.call();
  }

  void _onHorizontalDragCancel() {
    _replyTriggered = false;
    _snapStartOffset = _dragOffset;
    _snapController.forward(from: 0);
  }

  bool get _canEdit {
    if (!widget.message.isOutbound || widget.onEdit == null) return false;
    // 24h window (server also enforces). Hide the affordance for old messages.
    return DateTime.now().difference(widget.message.timestamp).inHours < 24;
  }

  void _onLongPress(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchorRect = box.localToGlobal(Offset.zero) & box.size;

    showMessageActions(
      context: context,
      message: widget.message,
      anchorRect: anchorRect,
      soulColor: widget.soulColor,
      onReply: widget.onReply,
      onReact: widget.onReact,
      onEdit: _canEdit ? () => _beginEdit(context) : null,
    );
  }

  void _onDoubleTap(BuildContext context) {
    if (_canEdit) _beginEdit(context);
  }

  Future<void> _beginEdit(BuildContext context) async {
    final newBody = await showEditDialog(
      context: context,
      initial: widget.message.content,
      soulColor: widget.userSoulColor,
    );
    if (newBody != null && newBody.trim().isNotEmpty) {
      widget.onEdit?.call(newBody.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOut = widget.message.isOutbound;

    final replyIcon = Opacity(
      opacity: _replyIconOpacity,
      child: Icon(
        Icons.reply_rounded,
        size: 20,
        color: isOut ? widget.userSoulColor : widget.soulColor,
      ),
    );

    return GestureDetector(
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onHorizontalDragCancel: _onHorizontalDragCancel,
      onLongPress: () => _onLongPress(context),
      onDoubleTap: () => _onDoubleTap(context),
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
              if (!isOut) ...[
                Padding(padding: const EdgeInsets.only(right: 6), child: replyIcon),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment:
                      isOut ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    if (widget.showSenderName && !isOut)
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
                    _BubbleContent(
                      message: widget.message,
                      soulColor: widget.soulColor,
                      userSoulColor: widget.userSoulColor,
                      repliedTo: widget.repliedTo,
                      onJumpToReplied: widget.onJumpToReplied,
                      onShowHistory: () => showEditHistory(
                        context: context,
                        message: widget.message,
                        soulColor: widget.soulColor,
                      ),
                    ),
                    if (widget.message.hasThread)
                      _ThreadAffordance(
                        soulColor: isOut ? widget.userSoulColor : widget.soulColor,
                        onTap: widget.onOpenThread,
                      ),
                    if (widget.message.reactions.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _ReactionsRow(
                        message: widget.message,
                        soulColor: widget.soulColor,
                        myIdentity: widget.myIdentity,
                        onToggle: widget.onReact,
                      ),
                    ],
                  ],
                ),
              ),
              if (isOut) ...[
                Padding(padding: const EdgeInsets.only(left: 6), child: replyIcon),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bubble content

class _BubbleContent extends StatelessWidget {
  const _BubbleContent({
    required this.message,
    required this.soulColor,
    required this.userSoulColor,
    this.repliedTo,
    this.onJumpToReplied,
    this.onShowHistory,
  });

  final ChatMessage message;
  final Color soulColor;
  final Color userSoulColor;
  final ChatMessage? repliedTo;
  final VoidCallback? onJumpToReplied;
  final VoidCallback? onShowHistory;

  @override
  Widget build(BuildContext context) {
    final isOut = message.isOutbound;
    final tt = Theme.of(context).textTheme;
    final accent = isOut ? userSoulColor : soulColor;

    // Attachment messages carry a small __ATTACH__ sentinel body.
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

    final hasReply = message.replyToId != null && message.replyToId!.isNotEmpty;

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
        border: Border.all(
          color: accent.withValues(alpha: isOut ? 0.3 : 0.45),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quoted reply (above the body, tappable to scroll to original).
          if (hasReply)
            QuotedReply(
              original: repliedTo,
              quotedText: message.quotedText,
              quotedSender: message.quotedSender,
              accent: accent,
              onTap: onJumpToReplied,
            ),

          // Body rendered BY content_type (golden rule: unknown -> body).
          MessageContent(message: message),

          const SizedBox(height: 4),

          // Timestamp + edited badge + delivery row.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateFormat('h:mm a').format(message.timestamp.toLocal()),
                style: tt.labelSmall
                    ?.copyWith(color: SovereignColors.textTertiary),
              ),
              if (message.isEdited) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onShowHistory,
                  behavior: HitTestBehavior.opaque,
                  child: Text(
                    'edited',
                    style: tt.labelSmall?.copyWith(
                      color: SovereignColors.textTertiary,
                      fontStyle: FontStyle.italic,
                      decoration: TextDecoration.underline,
                      decorationColor: SovereignColors.textTertiary,
                    ),
                  ),
                ),
              ],
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
// Inline edit dialog

/// Shows a simple inline edit dialog seeded with [initial]; returns the new
/// body, or null if cancelled.
Future<String?> showEditDialog({
  required BuildContext context,
  required String initial,
  required Color soulColor,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text('Edit message',
            style: TextStyle(color: SovereignColors.textPrimary, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          style: const TextStyle(color: SovereignColors.textPrimary),
          decoration: InputDecoration(
            filled: true,
            fillColor: SovereignColors.surfaceGlass,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: soulColor.withValues(alpha: 0.3)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: soulColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            style: TextButton.styleFrom(foregroundColor: soulColor),
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Thread affordance

class _ThreadAffordance extends StatelessWidget {
  const _ThreadAffordance({required this.soulColor, this.onTap});

  final Color soulColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 14, color: soulColor),
            const SizedBox(width: 4),
            Text(
              'View thread',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: soulColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Attachment bubble

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
                style: tt.labelSmall
                    ?.copyWith(color: SovereignColors.textTertiary),
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
// Reactions row (per-sender contract: highlight chips the operator reacted to)

class _ReactionsRow extends StatelessWidget {
  const _ReactionsRow({
    required this.message,
    required this.soulColor,
    required this.myIdentity,
    this.onToggle,
  });

  final ChatMessage message;
  final Color soulColor;
  final String myIdentity;
  final void Function(String emoji)? onToggle;

  @override
  Widget build(BuildContext context) {
    final entries = message.reactions.entries.toList();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: entries.map((e) {
        final mine = message.reactedBy(e.key, myIdentity);
        return _ReactionPill(
          emoji: e.key,
          count: e.value,
          soulColor: soulColor,
          mine: mine,
          onTap: onToggle == null ? null : () => onToggle!(e.key),
        );
      }).toList(),
    );
  }
}

class _ReactionPill extends StatefulWidget {
  const _ReactionPill({
    required this.emoji,
    required this.count,
    required this.soulColor,
    required this.mine,
    this.onTap,
  });

  final String emoji;
  final int count;
  final Color soulColor;
  final bool mine;
  final VoidCallback? onTap;

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
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final alpha = widget.mine ? 0.24 : 0.12;
    final borderAlpha = widget.mine ? 0.6 : 0.28;
    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: widget.soulColor.withValues(alpha: alpha),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: widget.soulColor.withValues(alpha: borderAlpha),
              width: widget.mine ? 1.5 : 1,
            ),
          ),
          child: Text(
            '${widget.emoji} ${widget.count}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: widget.mine ? FontWeight.w700 : FontWeight.w400,
              color: SovereignColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
