import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/conversation_repository.dart';
import '../../models/conversation.dart';
import '../../core/theme/sovereign_colors.dart';
import '../../services/skcomms_client.dart';
import '../../core/chat_text.dart';

/// Well-known agent names that get special soul colors and agent badges.
const _knownAgents = {'lumina', 'jarvis', 'opus', 'ava', 'ara'};

Color? _agentSoulColor(String name) {
  switch (name.toLowerCase()) {
    case 'lumina':
      return SovereignColors.soulLumina;
    case 'jarvis':
      return SovereignColors.soulJarvis;
    case 'chef':
      return SovereignColors.soulChef;
    default:
      return null;
  }
}

/// Holds the list of conversations, sorted by recency.
/// Loads from Hive first, then tries to refresh from the SKComms daemon.
class ChatsNotifier extends Notifier<List<Conversation>> {
  @override
  List<Conversation> build() {
    Future.microtask(_loadPersistedThenDaemon);
    return [];
  }

  Future<void> _loadPersistedThenDaemon() async {
    final repo = ref.read(conversationRepositoryProvider);

    // Try Hive first — instant, no network.
    final persisted = await repo.getAll();
    if (persisted.isNotEmpty) {
      state = persisted;
    }

    // Then try the live daemon for fresh peer data.
    await _loadFromDaemon();
  }

  Future<void> _loadFromDaemon() async {
    final client = ref.read(skcommsClientProvider);
    final repo = ref.read(conversationRepositoryProvider);
    try {
      final alive = await client.isAlive();
      if (!alive) return;

      final seen = <String>{};
      final conversations = <Conversation>[];

      // 1) REAL conversations first — /api/v1/conversations returns Lumina
      //    (pinned, named, with her last message) + any other live threads.
      //    This is the source of truth for the list; getPeers() is only a
      //    fallback for discovered peers that don't have a thread yet.
      try {
        final convs = await client.getConversations();
        for (final m in convs) {
          final c = Conversation.fromJson(m);
          if (c.peerId.isEmpty) continue;
          final key = normalizePeerKey(c.peerId);
          if (!seen.add(key)) continue;
          // soul colour for known agents is resolved in the UI via
          // Conversation.resolvedSoulColor (json carries no colour).
          conversations.add(c);
        }
      } catch (_) {
        // conversations endpoint unavailable — fall through to peers only
      }

      // 2) Discovered peers WITHOUT a conversation yet — show them as
      //    startable chats (named, not the old "Peer discovered" placeholder).
      try {
        final peers = await client.getPeers();
        for (final peer in peers) {
          final raw = peer.name.isNotEmpty ? peer.name : (peer.fingerprint ?? '');
          final key = normalizePeerKey(raw);
          if (key.isEmpty || !seen.add(key)) continue;
          conversations.add(Conversation(
            peerId: key,
            displayName: peer.name.isNotEmpty ? peer.name : key,
            lastMessage: 'Tap to start chatting',
            lastMessageTime: peer.lastSeen ?? DateTime.now(),
            soulColor: _agentSoulColor(key),
            soulFingerprint: peer.fingerprint ?? key,
            isOnline: peer.lastSeen != null &&
                DateTime.now().difference(peer.lastSeen!).inMinutes < 30,
            isAgent: _knownAgents.contains(key),
          ));
        }
      } catch (_) {/* peers unavailable — conversations alone is fine */}

      if (conversations.isNotEmpty) {
        // Lumina pinned first (the operator's companion), then other agents,
        // then everyone by recency.
        conversations.sort((a, b) {
          final al = a.peerId.toLowerCase().contains('lumina');
          final bl = b.peerId.toLowerCase().contains('lumina');
          if (al != bl) return al ? -1 : 1;
          if (a.isAgent != b.isAgent) return a.isAgent ? -1 : 1;
          return b.lastMessageTime.compareTo(a.lastMessageTime);
        });
        state = conversations;
        await repo.saveAll(conversations);
      }
    } catch (_) {
      // Daemon offline — keep whatever we have.
    }
  }

  /// Re-fetch peers from the daemon.
  Future<void> refresh() async => _loadFromDaemon();

  Future<void> updateConversation(Conversation updated) async {
    state = [
      for (final c in state)
        if (c.peerId == updated.peerId) updated else c,
    ];
    final repo = ref.read(conversationRepositoryProvider);
    await repo.save(updated);
  }

  void setTyping(String peerId, {required bool typing}) {
    state = [
      for (final c in state)
        if (c.peerId == peerId) c.copyWith(isTyping: typing) else c,
    ];
  }

  Future<void> markRead(String peerId) async {
    final updated = <Conversation>[];
    Conversation? changed;
    for (final c in state) {
      if (c.peerId == peerId) {
        changed = c.copyWith(unreadCount: 0);
        updated.add(changed);
      } else {
        updated.add(c);
      }
    }
    state = updated;
    if (changed != null) {
      final repo = ref.read(conversationRepositoryProvider);
      await repo.save(changed);
    }
  }

  /// Clear the unread count on every conversation and persist.  Backs the
  /// activity feed's "Mark all read" so the derived notifications stay read
  /// across rebuilds/polls (instead of reappearing).
  Future<void> markAllRead() async {
    final repo = ref.read(conversationRepositoryProvider);
    final updated = <Conversation>[];
    for (final c in state) {
      if (c.unreadCount != 0) {
        final cleared = c.copyWith(unreadCount: 0);
        updated.add(cleared);
        await repo.save(cleared);
      } else {
        updated.add(c);
      }
    }
    state = updated;
  }

  Future<void> addConversation(Conversation conversation) async {
    if (state.any((c) => c.peerId == conversation.peerId)) return;
    state = [conversation, ...state];
    final repo = ref.read(conversationRepositoryProvider);
    await repo.save(conversation);
  }
}

final chatsProvider = NotifierProvider<ChatsNotifier, List<Conversation>>(
  ChatsNotifier.new,
);
