import 'package:hive_flutter/hive_flutter.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';

/// Hive type IDs -- keep unique across the app.
const int chatMessageTypeId = 0;
const int conversationTypeId = 1;

class ChatMessageAdapter extends TypeAdapter<ChatMessage> {
  @override
  final int typeId = chatMessageTypeId;

  @override
  ChatMessage read(BinaryReader reader) {
    final map = reader.readMap().cast<String, dynamic>();
    // Reactions: new shape is {emoji: [sender]}; older persisted boxes stored
    // {emoji: count}. Read both so a box written before this contract still
    // renders its reactions.
    final rawReactions = map['reactions'];
    final reactionSenders = <String, List<String>>{};
    if (rawReactions is Map) {
      rawReactions.forEach((k, v) {
        final emoji = k.toString();
        if (v is List) {
          reactionSenders[emoji] = v.map((e) => e.toString()).toList();
        } else if (v is int && v > 0) {
          reactionSenders[emoji] = List.generate(v, (_) => '?');
        }
      });
    }
    return ChatMessage(
      id: map['id'] as String? ?? '',
      peerId: map['peer_id'] as String? ?? '',
      content: map['content'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        map['timestamp'] as int? ?? 0,
      ),
      isOutbound: map['is_outbound'] as bool? ?? false,
      conversationId: map['conversation_id'] as String?,
      sender: map['sender'] as String?,
      contentType: map['content_type'] as String? ?? 'text',
      rich: (map['rich'] as Map?)?.cast<String, dynamic>(),
      deliveryStatus: map['delivery_status'] as String? ?? 'sent',
      isEncrypted: map['is_encrypted'] as bool? ?? true,
      replyToId: map['reply_to_id'] as String?,
      threadId: map['thread_id'] as String?,
      editedAt: map['edited_at'] is int
          ? DateTime.fromMillisecondsSinceEpoch(map['edited_at'] as int)
          : null,
      editHistory: (map['edit_history'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      reactionSenders: reactionSenders,
      receiptsDelivered: (map['receipts_delivered'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      receiptsRead: (map['receipts_read'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      isAgent: map['is_agent'] as bool? ?? false,
      senderName: map['sender_name'] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ChatMessage obj) {
    writer.writeMap(<String, dynamic>{
      'id': obj.id,
      'peer_id': obj.peerId,
      'content': obj.content,
      'timestamp': obj.timestamp.millisecondsSinceEpoch,
      'is_outbound': obj.isOutbound,
      'conversation_id': obj.conversationId,
      'sender': obj.sender,
      'content_type': obj.contentType,
      'rich': obj.rich,
      'delivery_status': obj.deliveryStatus,
      'is_encrypted': obj.isEncrypted,
      'reply_to_id': obj.replyToId,
      'thread_id': obj.threadId,
      'edited_at': obj.editedAt?.millisecondsSinceEpoch,
      'edit_history': obj.editHistory,
      // Persist the full per-sender reactions map so toggles survive a reload.
      'reactions': obj.reactionSenders,
      'receipts_delivered': obj.receiptsDelivered,
      'receipts_read': obj.receiptsRead,
      'is_agent': obj.isAgent,
      'sender_name': obj.senderName,
    });
  }
}

class ConversationAdapter extends TypeAdapter<Conversation> {
  @override
  final int typeId = conversationTypeId;

  @override
  Conversation read(BinaryReader reader) {
    final map = reader.readMap().cast<String, dynamic>();
    return Conversation(
      peerId: map['peer_id'] as String? ?? '',
      displayName: map['display_name'] as String? ?? '',
      lastMessage: map['last_message'] as String? ?? '',
      lastMessageTime: DateTime.fromMillisecondsSinceEpoch(
        map['last_message_time'] as int? ?? 0,
      ),
      soulFingerprint: map['soul_fingerprint'] as String?,
      isOnline: map['is_online'] as bool? ?? false,
      isAgent: map['is_agent'] as bool? ?? false,
      unreadCount: map['unread_count'] as int? ?? 0,
      lastDeliveryStatus: map['last_delivery_status'] as String? ?? 'sent',
      isTyping: false,
      isGroup: map['is_group'] as bool? ?? false,
      memberCount: map['member_count'] as int? ?? 0,
      avatarUrl: map['avatar_url'] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Conversation obj) {
    writer.writeMap(<String, dynamic>{
      'peer_id': obj.peerId,
      'display_name': obj.displayName,
      'last_message': obj.lastMessage,
      'last_message_time': obj.lastMessageTime.millisecondsSinceEpoch,
      'soul_fingerprint': obj.soulFingerprint,
      'is_online': obj.isOnline,
      'is_agent': obj.isAgent,
      'unread_count': obj.unreadCount,
      'last_delivery_status': obj.lastDeliveryStatus,
      'is_group': obj.isGroup,
      'member_count': obj.memberCount,
      'avatar_url': obj.avatarUrl,
    });
  }
}
