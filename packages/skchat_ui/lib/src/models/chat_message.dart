/// ChatMessage mirrors the skchat Python `Message` typed-contract model:
///
/// ```
/// Message { id, conversation_id, sender, content_type, body, rich, ts,
///   reply_to_id, thread_id, edited_at, edit_history[],
///   reactions{emoji:[sender]}, receipts{delivered[],read[]} }
/// ```
///
/// The Flutter app keeps a few app-local fields ([peerId], [isOutbound],
/// [deliveryStatus]) derived at ingestion time, but the wire-facing fields above
/// are carried verbatim so the conversation view can render any message by
/// [contentType] (the golden rule: an unknown type falls back to its [body]).
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.content,
    required this.timestamp,
    required this.isOutbound,
    this.conversationId,
    this.sender,
    this.contentType = 'text',
    this.rich,
    this.deliveryStatus = 'sent',
    this.isEncrypted = true,
    this.replyToId,
    this.threadId,
    this.editedAt,
    this.editHistory = const [],
    this.reactionSenders = const {},
    this.receiptsDelivered = const [],
    this.receiptsRead = const [],
    this.isAgent = false,
    this.senderName,
    this.pqLocked = false,
  });

  final String id;
  final String peerId;

  /// The human-readable message body. Mirrors the contract's `body`.
  /// (Named [content] for app-history reasons -- it IS the contract `body`.)
  final String content;
  final DateTime timestamp;
  final bool isOutbound;

  /// Contract: `conversation_id`. The room/thread-pair this message belongs to.
  final String? conversationId;

  /// Contract: `sender` -- the wire identity that authored the message.
  final String? sender;

  /// Contract: `content_type` -- e.g. `text`, `markdown`, `system`,
  /// `application/skchat.location+json`. Drives the render dispatch. An UNKNOWN
  /// type renders its [content]/[body] as a graceful fallback (forward-compat).
  final String contentType;

  /// Contract: `rich` -- optional structured payload for typed content types.
  final Map<String, dynamic>? rich;

  /// 'sent' | 'delivered' | 'read'
  final String deliveryStatus;
  final bool isEncrypted;

  /// Contract: `reply_to_id` -- the message this is a reply to (quoted above).
  final String? replyToId;

  /// Contract: `thread_id` -- the thread this message roots/belongs to.
  final String? threadId;

  /// Contract: `edited_at` -- set when the body has been edited.
  final DateTime? editedAt;

  /// Contract: `edit_history[]` -- prior bodies, oldest-first.
  final List<String> editHistory;

  /// Contract: `reactions{emoji:[sender]}` -- full per-sender reaction map.
  final Map<String, List<String>> reactionSenders;

  /// Contract: `receipts.delivered[]` -- senders who received the message.
  final List<String> receiptsDelivered;

  /// Contract: `receipts.read[]` -- senders who read the message.
  final List<String> receiptsRead;

  final bool isAgent;
  final String? senderName;

  /// A post-quantum (`pqdm1:`) sealed message that THIS device could not open
  /// (no matching private key, or the AEAD open failed, e.g. the reply was
  /// sealed to another device's prekey, or the browser has no PQC backend).
  ///
  /// Such a message still renders, as a visible "locked" placeholder, so the
  /// sender never appears silent on the reduced-assurance web/PWA leg. Because
  /// every locked copy carries the SAME placeholder [content], it must be
  /// deduplicated by [id] ONLY: content-based dedup would otherwise collapse two
  /// genuinely distinct locked replies into one, hiding all but the first. See
  /// `message_dedup.dart` and `conversation_provider.dart`.
  final bool pqLocked;

  // -- Derived helpers --------------------------------------------------------

  /// Whether this message has been edited (carries an `edited_at`).
  bool get isEdited => editedAt != null;

  /// Whether this message roots/participates in a thread.
  bool get hasThread => threadId != null && threadId!.isNotEmpty;

  /// Reactions collapsed to emoji->count for the chip row.
  Map<String, int> get reactions =>
      {for (final e in reactionSenders.entries) e.key: e.value.length};

  /// True if [me] has reacted with [emoji] (drives toggle + highlight).
  bool reactedBy(String emoji, String me) =>
      reactionSenders[emoji]?.contains(me) ?? false;

  ChatMessage copyWith({
    String? id,
    String? peerId,
    String? content,
    DateTime? timestamp,
    bool? isOutbound,
    String? conversationId,
    String? sender,
    String? contentType,
    Map<String, dynamic>? rich,
    String? deliveryStatus,
    bool? isEncrypted,
    String? replyToId,
    String? threadId,
    DateTime? editedAt,
    List<String>? editHistory,
    Map<String, List<String>>? reactionSenders,
    List<String>? receiptsDelivered,
    List<String>? receiptsRead,
    bool? isAgent,
    String? senderName,
    bool? pqLocked,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isOutbound: isOutbound ?? this.isOutbound,
      conversationId: conversationId ?? this.conversationId,
      sender: sender ?? this.sender,
      contentType: contentType ?? this.contentType,
      rich: rich ?? this.rich,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      replyToId: replyToId ?? this.replyToId,
      threadId: threadId ?? this.threadId,
      editedAt: editedAt ?? this.editedAt,
      editHistory: editHistory ?? this.editHistory,
      reactionSenders: reactionSenders ?? this.reactionSenders,
      receiptsDelivered: receiptsDelivered ?? this.receiptsDelivered,
      receiptsRead: receiptsRead ?? this.receiptsRead,
      isAgent: isAgent ?? this.isAgent,
      senderName: senderName ?? this.senderName,
      pqLocked: pqLocked ?? this.pqLocked,
    );
  }

  /// Parse the per-sender reactions map from JSON, tolerating both the new
  /// `{emoji: [sender]}` shape and a legacy `{emoji: count}` shape (count -> a
  /// list of that many anonymous placeholders, so counts still render).
  static Map<String, List<String>> _parseReactions(dynamic raw) {
    if (raw is! Map) return const {};
    final out = <String, List<String>>{};
    raw.forEach((k, v) {
      final emoji = k.toString();
      if (v is List) {
        out[emoji] = v.map((e) => e.toString()).toList();
      } else if (v is int && v > 0) {
        out[emoji] = List.generate(v, (_) => '?');
      }
    });
    return out;
  }

  static List<String> _strList(dynamic raw) =>
      raw is List ? raw.map((e) => e.toString()).toList() : const [];

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    // `ts` is the contract timestamp; `timestamp` kept as a fallback key.
    final rawTs = json['ts'] ?? json['timestamp'];
    final receipts = json['receipts'];
    return ChatMessage(
      id: json['id'] as String? ?? '',
      peerId: json['peer_id'] as String? ?? '',
      content: (json['body'] ?? json['content']) as String? ?? '',
      timestamp: rawTs is String
          ? (DateTime.tryParse(rawTs) ?? DateTime.now())
          : DateTime.now(),
      isOutbound: json['is_outbound'] as bool? ?? false,
      conversationId: json['conversation_id'] as String?,
      sender: json['sender'] as String?,
      contentType: json['content_type'] as String? ?? 'text',
      rich: (json['rich'] as Map?)?.cast<String, dynamic>(),
      deliveryStatus: json['delivery_status'] as String? ?? 'sent',
      isEncrypted: json['is_encrypted'] as bool? ?? true,
      replyToId: json['reply_to_id'] as String?,
      threadId: json['thread_id'] as String?,
      editedAt: json['edited_at'] is String
          ? DateTime.tryParse(json['edited_at'] as String)
          : null,
      editHistory: _strList(json['edit_history']),
      reactionSenders: _parseReactions(json['reactions']),
      receiptsDelivered:
          receipts is Map ? _strList(receipts['delivered']) : const [],
      receiptsRead: receipts is Map ? _strList(receipts['read']) : const [],
      isAgent: json['is_agent'] as bool? ?? false,
      senderName: json['sender_name'] as String?,
      pqLocked: json['pq_locked'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'peer_id': peerId,
        'conversation_id': conversationId,
        'sender': sender,
        'content_type': contentType,
        'body': content,
        'rich': rich,
        'ts': timestamp.toIso8601String(),
        'is_outbound': isOutbound,
        'delivery_status': deliveryStatus,
        'is_encrypted': isEncrypted,
        'reply_to_id': replyToId,
        'thread_id': threadId,
        'edited_at': editedAt?.toIso8601String(),
        'edit_history': editHistory,
        'reactions': reactionSenders,
        'receipts': {'delivered': receiptsDelivered, 'read': receiptsRead},
        'is_agent': isAgent,
        'sender_name': senderName,
        'pq_locked': pqLocked,
      };
}
