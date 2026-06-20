import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../../models/attachment_ref.dart';
import '../../models/chat_message.dart';
import '../../models/call_state.dart';
import '../../services/skcomms_client.dart';
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
import 'message_dedup.dart';

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
    final messages = dedupForDisplay(ref.watch(conversationProvider(peerId)));
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
              onReact: (messageId, emoji) => ref
                  .read(conversationProvider(peerId).notifier)
                  .react(messageId, emoji),
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
            onAttach: () => _pickAndSendAttachment(context, ref, peerId),
            onTyping: (isTyping) => ref
                .read(skcommsSyncProvider.notifier)
                .sendTyping(peerId: peerId, start: isTyping),
          ),
        ],
      ),
    );
  }

  /// Pick a file, upload it to the daemon, then send an attachment-reference
  /// message so both sides render a [FileTransferBubble] for the transfer.
  ///
  /// Uses byte data (web has no file paths) so the same path works on every
  /// platform.  Optimistically inserts the bubble on success.
  Future<void> _pickAndSendAttachment(
    BuildContext context,
    WidgetRef ref,
    String peerId,
  ) async {
    final messenger = ScaffoldMessenger.of(context);

    final FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(withData: true);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open file picker: $e')),
      );
      return;
    }
    if (picked == null || picked.files.isEmpty) return; // user cancelled

    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read the selected file.')),
      );
      return;
    }

    final client = ref.read(skcommsClientProvider);
    final UploadResult upload;
    try {
      upload = await client.uploadFile(
        recipient: peerId,
        bytes: bytes,
        filename: file.name,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
      return;
    }

    final transferId =
        upload.transferId.isNotEmpty ? upload.transferId : upload.id;
    if (transferId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Upload returned no transfer id.')),
      );
      return;
    }

    final ref0 = AttachmentRef(
      transferId: transferId,
      filename: upload.filename.isNotEmpty ? upload.filename : file.name,
      size: file.size,
    );
    final body = ref0.encode();
    final tempId = '${DateTime.now().millisecondsSinceEpoch}';

    // Optimistic insert so the sender sees the attachment bubble immediately.
    ref.read(conversationProvider(peerId).notifier).addMessage(
      ChatMessage(
        id: tempId,
        peerId: peerId,
        content: body,
        timestamp: DateTime.now(),
        isOutbound: true,
        deliveryStatus: 'sent',
      ),
    );

    // Deliver the attachment-reference message over the normal transport.
    ref.read(skcommsSyncProvider.notifier).sendMessage(
      peerId: peerId,
      content: body,
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
    required this.onReact,
  });

  final List<ChatMessage> messages;
  final Color soulColor;
  final bool isTyping;
  final String peerName;
  final bool isAgent;

  /// Called when the user long-presses a bubble and picks an emoji:
  /// (messageId, emoji).
  final void Function(String messageId, String emoji) onReact;

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
          onReact: (emoji) => widget.onReact(message.id, emoji),
        );
      },
    );
  }
}
