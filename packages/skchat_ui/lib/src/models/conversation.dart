import 'package:flutter/material.dart';
import '../theme/sovereign_colors.dart';

/// One participant of a group conversation, carrying the identity plus the
/// real capauth soul-fingerprint needed to anchor a per-member trust tier
/// (and the folded aggregate group badge). Mirrors GroupMemberInfo's parse
/// keys so the server emits ONE member shape for both /groups/:id/members and
/// the participants embedded in /conversations.
class ConversationMember {
  const ConversationMember({
    required this.identityUri,
    required this.displayName,
    this.soulFingerprint,
  });

  final String identityUri;
  final String displayName;

  /// Real capauth fingerprint from the peer store (server-resolved). Null or
  /// empty for a keyless member (keyless means no badge, never a fabricated key).
  final String? soulFingerprint;

  factory ConversationMember.fromJson(Map<String, dynamic> json) {
    return ConversationMember(
      identityUri: json['identity_uri'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      // Server emits both the conversation-contract key and the peer alias.
      soulFingerprint: (json['soul_fingerprint'] as String?) ??
          (json['fingerprint'] as String?),
    );
  }
}

/// Represents a conversation thread (DM or group).
class Conversation {
  const Conversation({
    required this.peerId,
    required this.displayName,
    required this.lastMessage,
    required this.lastMessageTime,
    this.soulColor,
    this.soulFingerprint,
    this.isOnline = false,
    this.isAgent = false,
    this.unreadCount = 0,
    this.lastDeliveryStatus = 'sent',
    this.isTyping = false,
    this.isGroup = false,
    this.memberCount = 0,
    this.initials,
    this.avatarUrl,
    this.members = const [],
  });

  final String peerId;
  final String displayName;
  final String lastMessage;
  final DateTime lastMessageTime;

  /// Soul-color derived from CapAuth fingerprint.
  /// Falls back to [soulFingerprint] derivation if null.
  final Color? soulColor;
  final String? soulFingerprint;

  final bool isOnline;
  final bool isAgent;
  final int unreadCount;
  final String lastDeliveryStatus;
  final bool isTyping;
  final bool isGroup;
  final int memberCount;
  final String? initials;
  final String? avatarUrl;

  /// Group participants (empty for a 1:1). Populated from the server
  /// `participants` array; drives the composite avatar + aggregate badge.
  final List<ConversationMember> members;

  /// Resolved soul-color, derives from fingerprint if [soulColor] is not set.
  Color get resolvedSoulColor {
    if (soulColor != null) return soulColor!;
    if (soulFingerprint != null) {
      return SovereignColors.fromFingerprint(soulFingerprint!);
    }
    return SovereignColors.textSecondary;
  }

  String get resolvedInitials {
    if (initials != null) return initials!;
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
  }

  Conversation copyWith({
    String? peerId,
    String? displayName,
    String? lastMessage,
    DateTime? lastMessageTime,
    Color? soulColor,
    String? soulFingerprint,
    bool? isOnline,
    bool? isAgent,
    int? unreadCount,
    String? lastDeliveryStatus,
    bool? isTyping,
    bool? isGroup,
    int? memberCount,
    String? initials,
    String? avatarUrl,
    List<ConversationMember>? members,
  }) {
    return Conversation(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      soulColor: soulColor ?? this.soulColor,
      soulFingerprint: soulFingerprint ?? this.soulFingerprint,
      isOnline: isOnline ?? this.isOnline,
      isAgent: isAgent ?? this.isAgent,
      unreadCount: unreadCount ?? this.unreadCount,
      lastDeliveryStatus: lastDeliveryStatus ?? this.lastDeliveryStatus,
      isTyping: isTyping ?? this.isTyping,
      isGroup: isGroup ?? this.isGroup,
      memberCount: memberCount ?? this.memberCount,
      initials: initials ?? this.initials,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      members: members ?? this.members,
    );
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      peerId: json['peer_id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      lastMessage: json['last_message'] as String? ?? '',
      lastMessageTime: json['last_message_time'] != null
          ? DateTime.parse(json['last_message_time'] as String)
          : DateTime.now(),
      soulFingerprint: json['soul_fingerprint'] as String?,
      isOnline: json['is_online'] as bool? ?? false,
      isAgent: json['is_agent'] as bool? ?? false,
      unreadCount: json['unread_count'] as int? ?? 0,
      lastDeliveryStatus: json['last_delivery_status'] as String? ?? 'sent',
      isGroup: json['is_group'] as bool? ?? false,
      memberCount: json['member_count'] as int? ?? 0,
      avatarUrl: json['avatar_url'] as String?,
      members: (json['participants'] as List<dynamic>?)
              ?.map((e) =>
                  ConversationMember.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}
