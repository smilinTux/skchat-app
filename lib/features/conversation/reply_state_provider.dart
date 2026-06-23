import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/chat_message.dart';

/// Holds the message the user is currently replying to, per conversation
/// (keyed by peerId). Null when there is no active reply.
///
/// The conversation screen watches this to show the reply composer chip and to
/// carry `reply_to_id` on the next send; the message-row swipe-to-reply gesture
/// sets it, and the chip's cancel button (or a completed send) clears it.
class ReplyStateNotifier extends FamilyNotifier<ChatMessage?, String> {
  @override
  ChatMessage? build(String peerId) => null;

  /// Set the message being replied to.
  void setReply(ChatMessage message) => state = message;

  /// Clear the active reply (chip cancel / after send).
  void clear() => state = null;
}

final replyStateProvider =
    NotifierProviderFamily<ReplyStateNotifier, ChatMessage?, String>(
  ReplyStateNotifier.new,
);
