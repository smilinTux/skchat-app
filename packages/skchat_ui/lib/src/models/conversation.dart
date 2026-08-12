import 'package:flutter/material.dart';
import '../theme/sovereign_colors.dart';

/// The ONE anti-spoofing title rule for anything a guest is behind (guest-dm
/// C3, generalized in G6).
///
/// The operator's private [alias] always wins and renders like a real contact
/// name. Absent an alias, the guest's self-chosen [name] is shown prefixed with
/// `guest:` and must be styled untrusted by the caller, so a guest naming
/// themselves "Chef" cannot pass as a real contact. Never the raw group name.
///
/// One helper, three callers: the guest-DM row title, every member of a gdm
/// roster, and per-message sender attribution in a gdm thread. If it forked,
/// one of those surfaces would eventually render a spoofable name.
String guestDisplayTitle(String? alias, String? name) {
  final a = alias?.trim() ?? '';
  if (a.isNotEmpty) return a;
  final n = name?.trim() ?? '';
  return 'guest: ${n.isNotEmpty ? n : 'guest'}';
}

/// guest-dm G7: one guest with a live call ring in a promoted room.
///
/// A 1:1 guest DM has exactly one guest, so its ring needs no name. A gdm has
/// several, so the operator cannot answer without knowing who is calling. The
/// identity here is server-resolved from the operator's own contact row, never
/// from anything the guest supplies, so it goes through the same alias-wins
/// rule as every other guest surface.
class GuestRinger {
  const GuestRinger({
    required this.guestId,
    required this.guestName,
    this.guestAlias,
    this.ringTs,
  });

  final String guestId;
  final String guestName;
  final String? guestAlias;
  final double? ringTs;

  bool get hasAlias => guestAlias != null && guestAlias!.trim().isNotEmpty;

  String get title => guestDisplayTitle(guestAlias, guestName);

  /// The caller's name is self-asserted and unaliased: style it untrusted.
  bool get isUntrustedName => !hasAlias;

  factory GuestRinger.fromJson(Map<String, dynamic> json) {
    return GuestRinger(
      guestId: json['guest_id'] as String? ?? '',
      guestName: json['guest_name'] as String? ?? '',
      guestAlias: json['guest_alias'] as String?,
      ringTs: (json['ring_ts'] as num?)?.toDouble(),
    );
  }
}

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
    this.isGuest = false,
    this.guestName,
    this.guestAlias,
    this.guestStatus,
    this.membershipStatus,
  });

  final String identityUri;
  final String displayName;

  /// Real capauth fingerprint from the peer store (server-resolved). Null or
  /// empty for a keyless member (keyless means no badge, never a fabricated key).
  final String? soulFingerprint;

  // ── guest-dm G6: per-member guest identity in a gdm roster (G4 payload) ────
  /// This member is an untrusted guest, not a capauth-trusted member.
  final bool isGuest;

  /// The guest's self-chosen (untrusted, self-asserted) name.
  final String? guestName;

  /// The operator's PRIVATE alias for this guest. Alias-wins, per member.
  final String? guestAlias;

  /// Person-level status (`active` | `revoked`): the guest was revoked
  /// everywhere but is still seated here, so the row renders dimmed.
  final String? guestStatus;

  /// Per-group status (`active` | `revoked`). A per-group revoke normally
  /// removes the seat outright, so this is the belt to guestStatus's braces.
  final String? membershipStatus;

  bool get hasGuestAlias => guestAlias != null && guestAlias!.trim().isNotEmpty;

  /// Revoked at either level: dim the row, no live actions.
  bool get isRevoked =>
      guestStatus == 'revoked' || membershipStatus == 'revoked';

  /// Alias-wins title for this member. Trusted members keep their real
  /// display name; guests go through the shared anti-spoof rule.
  String get title => isGuest
      ? guestDisplayTitle(guestAlias, guestName ?? displayName)
      : displayName;

  /// True when this member's name is self-asserted and unaliased - the caller
  /// must render it with untrusted styling.
  bool get isUntrustedName => isGuest && !hasGuestAlias;

  factory ConversationMember.fromJson(Map<String, dynamic> json) {
    return ConversationMember(
      identityUri: json['identity_uri'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      // Server emits both the conversation-contract key and the peer alias.
      soulFingerprint: (json['soul_fingerprint'] as String?) ??
          (json['fingerprint'] as String?),
      isGuest: json['guest'] as bool? ?? false,
      guestName: json['guest_name'] as String?,
      guestAlias: json['guest_alias'] as String?,
      guestStatus: json['guest_status'] as String?,
      membershipStatus: json['membership_status'] as String?,
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
    this.isGuestDm = false,
    this.guestName,
    this.guestAlias,
    this.guestStatus,
    this.guestMuted = false,
    this.ringing = false,
    this.ringTs,
    this.mode,
    this.ringers = const [],
    this.expiresAt,
    this.metaProject,
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

  // ── guest-dm C3: operator-facing guest-DM badge (S4 payload) ──────────────
  /// True when this "group" is actually a guest DM (server `guest_dm`). The row
  /// renders inline in Chats with a guest badge and the guest/alias title, never
  /// the raw group name.
  final bool isGuestDm;

  /// The guest's self-chosen (untrusted, self-asserted) display name.
  final String? guestName;

  /// The operator's PRIVATE alias for this guest. When set it ALWAYS wins the
  /// title and renders like a real contact name; the guest can never set it, so
  /// a guest naming themselves "Chef" cannot impersonate a real contact.
  final String? guestAlias;

  /// `active` | `revoked` | `expired` (S3/S4). Non-active renders dimmed.
  final String? guestStatus;

  /// Operator muted this guest DM (S4). Carried for the contact sheet (C4).
  final bool guestMuted;

  /// guest-dm C5: the guest is ringing the operator right now (S6 poll fallback).
  final bool ringing;

  /// Epoch-seconds timestamp of the active ring; the client dedupes on it so a
  /// handled ring is not re-surfaced.
  final double? ringTs;

  /// guest-dm G6: the server's guest-family room mode, `dm` or `gdm`. A `gdm`
  /// is a promoted guest DM: still guest-flavored (untrusted people are in it,
  /// so it stays under the Guests filter) but group-shaped - several guests,
  /// a roster, a member count, and per-message attribution.
  final String? mode;

  bool get isGdm => mode == 'gdm';

  /// guest-dm G7: guests currently ringing this room, newest first. Empty for a
  /// 1:1 guest DM, where [ringing] alone already identifies the caller.
  final List<GuestRinger> ringers;

  /// The room's WHOLE-GROUP expiry as epoch seconds, or null when unset. Once
  /// it passes, every guest of the room is locked out (`group_expired`); the
  /// operator's own history is untouched. Distinct from the per-CONTACT expiry
  /// on the guest contact sheet, which expires one person everywhere.
  final double? expiresAt;

  /// True when a schedule is set and has NOT yet passed. A room whose expiry is
  /// already in the past reads as [hasExpired] instead, so the roster can say
  /// "expired" rather than showing a countdown that ran out.
  bool get hasGroupExpiry => expiresAt != null;

  bool get hasExpired {
    final e = expiresAt;
    if (e == null) return false;
    return DateTime.now().millisecondsSinceEpoch / 1000 >= e;
  }

  /// skcode Code section card C-12 (spec section 10): a group carrying
  /// server-side `meta.project = repo:<name>` binds this thread to a
  /// repo/project, so the Code pane can mount the SAME conversation thread
  /// as its project-chat column/tab instead of inventing a second chat
  /// store. Parsed defensively from an optional `meta` object nobody else
  /// on the wire needs to send or understand; null on every conversation
  /// until the server actually tags one (an honest, expected steady state
  /// today, not a parse failure -- the Code pane's own empty state covers
  /// exactly this case).
  final String? metaProject;

  /// Who to name on an incoming gdm ring, or null when the room is not a gdm
  /// or the server named nobody. Never guessed client-side: an unnamed ring
  /// stays unnamed rather than borrowing the room's title as a person.
  GuestRinger? get ringingCaller => ringers.isEmpty ? null : ringers.first;

  /// True when the operator has set a private alias (alias-wins title).
  bool get hasGuestAlias => guestAlias != null && guestAlias!.trim().isNotEmpty;

  bool get isGuestRevoked => guestStatus == 'revoked';
  bool get isGuestExpired => guestStatus == 'expired';

  /// A revoked or expired guest DM: render dimmed with a label, no live actions.
  bool get isGuestInactive => isGuestRevoked || isGuestExpired;

  /// The anti-spoofing title for a guest DM: the operator alias wins (rendered
  /// like a real contact), else the guest's self-name with a `guest:` prefix
  /// and untrusted styling. NEVER the raw group name.
  ///
  /// A gdm holds several guests, so there is no single guest to title with -
  /// the room is titled by its own name and the per-guest rule moves to the
  /// roster and to message attribution (both via [guestDisplayTitle]).
  String get guestTitle => isGdm
      ? (displayName.trim().isNotEmpty ? displayName.trim() : 'Guest group')
      : guestDisplayTitle(guestAlias, guestName);

  /// The gdm room title is the group's own name and is operator-set, so it is
  /// never spoofable the way a guest's self-name is.
  bool get isUntrustedTitle => isGuestDm && !isGdm && !hasGuestAlias;

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
    bool? isGuestDm,
    String? guestName,
    String? guestAlias,
    String? guestStatus,
    bool? guestMuted,
    bool? ringing,
    double? ringTs,
    String? mode,
    List<GuestRinger>? ringers,
    double? expiresAt,
    // `expiresAt: null` cannot mean "clear" in a copyWith, so clearing the
    // room's schedule is an explicit flag (same idiom as GuestContact).
    bool clearExpiry = false,
    String? metaProject,
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
      isGuestDm: isGuestDm ?? this.isGuestDm,
      guestName: guestName ?? this.guestName,
      guestAlias: guestAlias ?? this.guestAlias,
      guestStatus: guestStatus ?? this.guestStatus,
      guestMuted: guestMuted ?? this.guestMuted,
      ringing: ringing ?? this.ringing,
      ringTs: ringTs ?? this.ringTs,
      mode: mode ?? this.mode,
      ringers: ringers ?? this.ringers,
      expiresAt: clearExpiry ? null : (expiresAt ?? this.expiresAt),
      metaProject: metaProject ?? this.metaProject,
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
      // A gdm is a promoted guest DM: the server stops emitting the flat
      // `guest_dm` badge (there is no single guest to badge) and emits
      // `mode: gdm` instead, so fold it in here - untrusted people are still
      // in the room and every guest surface must keep catching it.
      isGuestDm: (json['guest_dm'] as bool? ?? false) || json['mode'] == 'gdm',
      mode: json['mode'] as String?,
      guestName: json['guest_name'] as String?,
      guestAlias: json['guest_alias'] as String?,
      guestStatus: json['guest_status'] as String?,
      guestMuted: json['muted'] as bool? ?? false,
      ringing: json['ringing'] as bool? ?? false,
      ringTs: (json['ring_ts'] as num?)?.toDouble(),
      ringers: (json['ringers'] as List<dynamic>?)
              ?.whereType<Map>()
              .map((e) => GuestRinger.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [],
      expiresAt: (json['expires_at'] as num?)?.toDouble(),
      // Defensive: `meta` may be absent entirely, present but not a Map, or
      // present without a `project` key -- every shape degrades to null
      // rather than throwing, matching this file's existing tolerance for a
      // server that has not caught up to every optional field yet.
      metaProject: (json['meta'] is Map)
          ? (json['meta'] as Map)['project'] as String?
          : null,
    );
  }
}
