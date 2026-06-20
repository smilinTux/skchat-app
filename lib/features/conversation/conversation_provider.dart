import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/message_repository.dart';
import '../../models/chat_message.dart';
import '../../models/control_signal.dart';
import '../../models/conversation.dart';
import '../../services/daemon_service.dart';
import '../../services/skcomms_client.dart';
import '../../services/skcomms_sync.dart';
import '../../core/chat_text.dart';
import '../chats/chats_provider.dart';

/// Holds the message list for a single conversation (identified by peerId).
/// Loads persisted messages from Hive first, then tries to fetch from the
/// SKComms daemon for any new messages not yet persisted.
class ConversationNotifier extends FamilyNotifier<List<ChatMessage>, String> {
  Timer? _pollTimer;

  /// Ids of reaction sentinels already folded into state, so re-polling the
  /// same history (reactions persist) doesn't double-apply them.
  final Set<String> _appliedReactionIds = {};

  /// Clears the transient "is composing" flag after an inbound typing-start
  /// that isn't followed by a stop (sender crashed, message dropped, etc.).
  Timer? _typingClearTimer;

  @override
  List<ChatMessage> build(String peerId) {
    _loadPersistedThenDaemon(peerId);
    // This provider is the SINGLE source of conversation messages: it polls the
    // full thread (`skchat history`, both directions) on a timer. skcomms_sync
    // no longer dispatches chat messages here (that caused multi-path dups /
    // wrong-side rendering). New agent replies appear via this poll.
    _pollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _fetchFromDaemon(peerId),
    );
    ref.onDispose(() {
      _pollTimer?.cancel();
      _typingClearTimer?.cancel();
    });
    return [];
  }

  /// Remove duplicates: same id, or same content+direction within 10s.
  /// (The local Hive cache can accumulate dup saves from the two load paths.)
  static List<ChatMessage> _dedup(List<ChatMessage> msgs) {
    final ids = <String>{};
    final out = <ChatMessage>[];
    for (final m in msgs) {
      if (!ids.add(m.id)) continue;
      final near = out.any((o) =>
          o.content == m.content &&
          o.isOutbound == m.isOutbound &&
          (o.timestamp.difference(m.timestamp).inSeconds).abs() < 10);
      if (near) continue;
      out.add(m);
    }
    return out;
  }

  Future<void> _loadPersistedThenDaemon(String peerId) async {
    final repo = ref.read(messageRepositoryProvider);

    // Instant load from Hive (deduped — the cache can hold dup saves).
    final persisted = await repo.getMessages(peerId);
    if (persisted.isNotEmpty) {
      state = _dedup(persisted);
    }

    // Then try the daemon for fresh data.
    await _fetchFromDaemon(peerId);
  }

  /// Fetch conversation history from the skchat local store via CLI.
  ///
  /// Calls `skchat inbox --json` and filters messages by [peerId].
  /// Falls back to the SKComms HTTP API for conversation IDs when the CLI
  /// is unavailable.  Merges into Hive-persisted state without duplicates.
  Future<void> _fetchFromDaemon(String peerId) async {
    final daemon = ref.read(daemonServiceProvider);
    final repo = ref.read(messageRepositoryProvider);

    // Primary: skchat CLI conversation history.
    try {
      final cliMessages = await daemon.getConversation(peerId, limit: 100);
      if (cliMessages.isNotEmpty) {
        final localId = daemon.localIdentity;
        final localShort =
            localId != null ? normalizePeerKey(localId) : null;
        final peerShort = normalizePeerKey(peerId);

        final existing = state.map((m) => m.id).toSet();
        // Content signatures (content|direction) already shown, to drop the
        // bridge's occasional double-delivery (same text, different ids).
        final seenSig = <String>{
          for (final m in state) '${m.isOutbound}|${m.content}',
        };
        final fresh = <ChatMessage>[];

        for (final m in cliMessages) {
          final senderShort = normalizePeerKey(m.sender);
          final isOutbound =
              localShort != null && senderShort == localShort;
          final msgPeerId =
              isOutbound ? normalizePeerKey(m.recipient) : senderShort;
          // Only include messages that belong to this conversation.
          if (msgPeerId != peerShort) continue;

          // Reaction sentinel (__REACT__) — fold into the target message's
          // reactions map instead of rendering. Skip our own outbound echoes
          // (we applied them optimistically) and already-applied ones.
          final react = ReactionSignal.parse(m.content);
          if (react != null) {
            if (!isOutbound && _appliedReactionIds.add(m.id)) {
              _applyReaction(react);
            }
            continue;
          }

          // Typing sentinel (__TYPING__) — ephemeral; flip the peer's
          // "is composing" flag. Never persisted or shown. Ignore our own.
          final typing = TypingSignal.parse(m.content);
          if (typing != null) {
            if (!isOutbound) _handleIncomingTyping(msgPeerId, typing);
            continue;
          }

          if (existing.contains(m.id)) continue;
          // Skip non-displayable traffic (control envelopes, prompt-echoes,
          // delivery-receipt UUIDs) so the thread stays clean.
          if (displayTextFor(m.content) == null) continue;

          final sig = '$isOutbound|${m.content}';
          if (!seenSig.add(sig)) continue; // duplicate content+direction

          fresh.add(ChatMessage(
            id: m.id,
            peerId: msgPeerId,
            content: m.content,
            timestamp: m.timestamp,
            isOutbound: isOutbound,
            deliveryStatus: isOutbound ? 'sent' : 'delivered',
          ));
        }

        if (fresh.isNotEmpty) {
          final merged = _dedup([...state, ...fresh]);
          merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          state = merged;
          for (final msg in fresh) {
            await repo.saveMessage(msg);
          }
        }
        return;
      }
    } catch (_) {
      // CLI unavailable — fall through to HTTP fallback.
    }

    // Fallback: SKComms HTTP conversation listing (no per-message history yet).
    final client = ref.read(skcommsClientProvider);
    try {
      final alive = await client.isAlive();
      if (!alive) return;
      // HTTP API does not yet expose per-conversation message history;
      // the CLI path above is the canonical source.  Nothing more to do.
    } catch (_) {
      // Daemon offline — keep Hive data.
    }
  }

  Future<void> addMessage(ChatMessage message) async {
    // Dedup: skip if we already have this message (same id), or a near-identical
    // one (same content + direction within a few seconds). Covers both the
    // Hive+daemon merge re-adding a message and the bridge delivering a reply
    // more than once.
    final isDup = state.any((m) =>
        m.id == message.id ||
        (m.content == message.content &&
            m.isOutbound == message.isOutbound &&
            (m.timestamp.difference(message.timestamp).inSeconds).abs() < 10));
    if (isDup) return;

    state = [...state, message];

    // Persist to Hive.
    final repo = ref.read(messageRepositoryProvider);
    await repo.saveMessage(message);

    // Update the conversation list with the new last message.
    ref.read(chatsProvider.notifier).updateConversation(
      ref
          .read(chatsProvider)
          .firstWhere(
            (c) => c.peerId == message.peerId,
            orElse: () => Conversation(
              peerId: message.peerId,
              displayName: message.peerId,
              lastMessage: message.content,
              lastMessageTime: message.timestamp,
            ),
          )
          .copyWith(
            lastMessage: message.content,
            lastMessageTime: message.timestamp,
            lastDeliveryStatus: 'sent',
          ),
    );
  }

  Future<void> updateDeliveryStatus(String messageId, String status) async {
    state = [
      for (final m in state)
        if (m.id == messageId) m.copyWith(deliveryStatus: status) else m,
    ];

    final repo = ref.read(messageRepositoryProvider);
    await repo.updateDeliveryStatus(this.arg, messageId, status);
  }

  /// Fold a reaction into the target message's `reactions` map (emoji → count).
  ///
  /// Used both for the local optimistic update when the operator reacts and
  /// for incoming reaction sentinels from a peer. A 'remove' action decrements
  /// (dropping the entry at zero); 'add' increments. Persists the updated
  /// message so the reaction survives an app restart.
  void _applyReaction(ReactionSignal react) {
    var changed = false;
    final updated = <ChatMessage>[];
    for (final m in state) {
      if (m.id != react.targetId) {
        updated.add(m);
        continue;
      }
      final next = Map<String, int>.from(m.reactions);
      if (react.isAdd) {
        next[react.emoji] = (next[react.emoji] ?? 0) + 1;
      } else {
        final c = (next[react.emoji] ?? 0) - 1;
        if (c > 0) {
          next[react.emoji] = c;
        } else {
          next.remove(react.emoji);
        }
      }
      updated.add(m.copyWith(reactions: next));
      changed = true;
    }
    if (!changed) return;
    state = updated;
    // Persist the reacted message so it survives a reload.
    final repo = ref.read(messageRepositoryProvider);
    final target = state.firstWhere((m) => m.id == react.targetId);
    repo.saveMessage(target);
  }

  /// React to a message in this conversation: apply locally (optimistic) and
  /// send the `__REACT__` sentinel to the peer over the transport.
  Future<void> react(String targetMessageId, String emoji) async {
    _applyReaction(ReactionSignal(targetId: targetMessageId, emoji: emoji));
    await ref.read(skcommsSyncProvider.notifier).sendReaction(
          peerId: arg,
          targetMessageId: targetMessageId,
          emoji: emoji,
        );
  }

  /// Handle an incoming typing sentinel: flip the peer's "is composing" flag.
  /// On 'start', also arm a safety timer to auto-clear if no 'stop' arrives.
  void _handleIncomingTyping(String peerId, TypingSignal typing) {
    final chats = ref.read(chatsProvider.notifier);
    chats.setTyping(peerId, typing: typing.isStart);
    _typingClearTimer?.cancel();
    if (typing.isStart) {
      _typingClearTimer = Timer(const Duration(seconds: 8), () {
        ref.read(chatsProvider.notifier).setTyping(peerId, typing: false);
      });
    }
  }
}

final conversationProvider =
    NotifierProviderFamily<ConversationNotifier, List<ChatMessage>, String>(
      ConversationNotifier.new,
    );
