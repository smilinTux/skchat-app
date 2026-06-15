import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../../models/chat_message.dart';
import '../../models/call_state.dart';
import '../calls/call_provider.dart';
import '../calls/livekit_call_screen.dart';
import '../chats/chats_provider.dart';
import '../identity/identity_card_screen.dart';
import '../../services/skcomms_sync.dart';
import 'conversation_provider.dart';
import 'widgets/model_picker_button.dart';
import 'widgets/message_bubble.dart';
import 'widgets/typing_indicator.dart';
import 'widgets/input_bar.dart';

/// Final render-time dedup safety net: never show the same message twice.
///
/// Collapses an exact id repeat, and same content+direction within a 5-minute
/// window — which catches the optimistic-send copy (client id/timestamp) and
/// the daemon re-fetch copy (server id/timestamp) of the *same* outbound
/// message, while still preserving genuinely distinct replies (different text,
/// or the same text far enough apart in time).
List<ChatMessage> _dedupForDisplay(List<ChatMessage> msgs) {
  // Dedup by exact content (direction-agnostic). A time window is unreliable
  // here: the optimistic-send copy is stamped in local time while the
  // daemon-refetch copy is stamped in UTC, so the "same" message can be hours
  // apart. Identical content within one conversation is treated as the same
  // message; the outbound copy wins so the operator's message stays on the
  // right side. (Trade-off: two genuinely identical sends collapse to one —
  // acceptable for an AI chat.)
  final out = <ChatMessage>[];
  for (final m in msgs) {
    final content = m.content.trim();
    final idx = out.indexWhere((o) => o.id == m.id || o.content.trim() == content);
    if (idx >= 0) {
      if (m.isOutbound && !out[idx].isOutbound) out[idx] = m;
      continue;
    }
    out.add(m);
  }
  return out;
}

/// Conversation screen — shows message bubbles for a 1:1 or group chat.
/// AppBar shows soul-color avatar, name, presence, and encryption indicator.
/// Messages: outbound right (user's soul-color tint), inbound left (glass + accent edge).
/// Typing indicator: personality-aware per PRD.
/// Input bar: glass-surface, bottom-pinned.
class ConversationScreen extends ConsumerWidget {
  const ConversationScreen({super.key, required this.peerId});

  final String peerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(chatsProvider);
    final conversation = conversations.firstWhere(
      (c) => c.peerId == peerId,
      orElse: () => conversations.first,
    );
    final messages = _dedupForDisplay(ref.watch(conversationProvider(peerId)));
    final soul = conversation.resolvedSoulColor;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: _buildAppBar(context, conversation, soul),
      body: Column(
        children: [
          // Message list
          Expanded(
            child: _MessageList(
              messages: messages,
              soulColor: soul,
              isTyping: conversation.isTyping,
              peerName: conversation.displayName,
              isAgent: conversation.isAgent,
            ),
          ),

          // Typing indicator strip
          if (conversation.isTyping)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TypingIndicator(
                  peerName: conversation.displayName,
                  isAgent: conversation.isAgent,
                  soulColor: soul,
                ),
              ),
            ),

          // Input bar — adds message optimistically, then sends to daemon.
          InputBar(
            soulColor: soul,
            onSend: (text) async {
              final tempId = '${DateTime.now().millisecondsSinceEpoch}';
              // Optimistic insert so the user sees the message immediately.
              ref.read(conversationProvider(peerId).notifier).addMessage(
                ChatMessage(
                  id: tempId,
                  peerId: peerId,
                  content: text,
                  timestamp: DateTime.now(),
                  isOutbound: true,
                  deliveryStatus: 'sent',
                ),
              );
              // Fire-and-forget to daemon; delivery status updated on next poll.
              ref.read(skcommsSyncProvider.notifier).sendMessage(
                peerId: peerId,
                content: text,
              );
            },
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    conversation,
    Color soul,
  ) {
    final tt = Theme.of(context).textTheme;

    return AppBar(
      backgroundColor: SovereignColors.surfaceBase,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      titleSpacing: 0,
      title: GestureDetector(
        onTap: () => context.push(
          AppRoutes.identityPath(conversation.peerId),
          extra: IdentityCardArgs(conversation: conversation),
        ),
        child: Row(
          children: [
            SoulAvatar(
              soulColor: soul,
              initials: conversation.resolvedInitials,
              isOnline: conversation.isOnline,
              isAgent: conversation.isAgent,
              size: 36,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conversation.displayName,
                    style: tt.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _presenceText(conversation),
                    style: tt.labelSmall?.copyWith(
                      color: conversation.isOnline
                          ? soul
                          : SovereignColors.textTertiary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        const EncryptBadge(size: 16),
        const SizedBox(width: 4),
        // Reply-model picker — only for AI agents (Lumina/Opus).
        if (conversation.isAgent == true) ModelPickerButton(peerId: peerId),
        // Voice call button — initiates call and navigates to outgoing screen.
        Consumer(
          builder: (context, ref, _) => IconButton(
            icon: const Icon(Icons.call_outlined),
            tooltip: 'Voice call',
            onPressed: () {
              final conversations = ref.read(chatsProvider);
              final conv = conversations.firstWhere(
                (c) => c.peerId == peerId,
                orElse: () => conversations.first,
              );
              ref.read(callProvider.notifier).initiateCall(
                peerId: peerId,
                peerName: conv.displayName,
                peerSoulColor: conv.resolvedSoulColor,
                type: CallType.voice,
              );
              context.push(AppRoutes.outgoingCallPath(peerId));
            },
          ),
        ),
        // Video call button.
        Consumer(
          builder: (context, ref, _) => IconButton(
            icon: const Icon(Icons.videocam_outlined),
            tooltip: 'Video call',
            onPressed: () {
              final conversations = ref.read(chatsProvider);
              final conv = conversations.firstWhere(
                (c) => c.peerId == peerId,
                orElse: () => conversations.first,
              );
              ref.read(callProvider.notifier).initiateCall(
                peerId: peerId,
                peerName: conv.displayName,
                peerSoulColor: conv.resolvedSoulColor,
                type: CallType.video,
              );
              context.push(AppRoutes.outgoingCallPath(peerId));
            },
          ),
        ),
        // LiveKit SFU group/agent call button.
        IconButton(
          icon: const Icon(Icons.meeting_room_outlined),
          tooltip: 'Agent room (LiveKit)',
          onPressed: () {
            final ids = [peerId, 'local']..sort();
            final roomName = 'sk-room-${ids.join("-")}';
            context.push(
              AppRoutes.livekitCall,
              extra: LiveKitCallArgs(
                roomName: roomName,
                identity: 'local',
                displayName: peerId,
              ),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.more_vert_rounded),
          onPressed: () {},
          tooltip: 'More options',
        ),
      ],
    );
  }

  String _presenceText(dynamic conv) {
    if (conv.isTyping) return 'composing...';
    if (conv.isOnline) return 'online';
    if (conv.isAgent) return 'agent · offline';
    return 'last seen recently';
  }
}

/// Scrollable message list with auto-scroll-to-bottom behavior.
class _MessageList extends StatefulWidget {
  const _MessageList({
    required this.messages,
    required this.soulColor,
    required this.isTyping,
    required this.peerName,
    required this.isAgent,
  });

  final List<ChatMessage> messages;
  final Color soulColor;
  final bool isTyping;
  final String peerName;
  final bool isAgent;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Jump to the latest message on open (the conversation provider keeps state
    // across opens, so messages are often already present on first build).
    _scrollToBottom(animate: false);
  }

  @override
  void didUpdateWidget(_MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages.length != oldWidget.messages.length) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.messages.length,
      itemBuilder: (context, index) {
        final message = widget.messages[index];
        return MessageBubble(
          message: message,
          soulColor: widget.soulColor,
        );
      },
    );
  }
}
