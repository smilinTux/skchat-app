import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../../models/attachment_ref.dart';
import '../../models/chat_message.dart';
import '../../models/call_state.dart';
import '../../services/daemon_service.dart';
import '../../services/skcomms_client.dart';
import '../calls/call_provider.dart';
import '../calls/livekit_call_screen.dart';
import '../chats/chats_provider.dart';
import '../identity/identity_card_screen.dart';
import '../../services/skcomms_sync.dart';
import '../../core/chat_text.dart';
import 'conversation_provider.dart';
import 'reply_state_provider.dart';
import 'widgets/model_picker_button.dart';
import 'widgets/message_bubble.dart';
import 'widgets/reply_preview.dart';
import 'widgets/thread_view.dart';
import 'widgets/conversation_subviews.dart';
import 'widgets/typing_indicator.dart';
import 'widgets/input_bar.dart';
import 'message_dedup.dart';

/// Conversation screen — shows message bubbles for a 1:1 or group chat.
/// AppBar: soul-color avatar, name, presence, encryption indicator, and a
/// header menu opening the Media / Files / Links / Pinned sub-views.
/// Message rows carry the full interaction kit (swipe-reply, react, edit,
/// receipts, thread). Reply composer chip sits above the input bar.
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
    final replyTarget = ref.watch(replyStateProvider(peerId));
    final soul = conversation.resolvedSoulColor;
    final me = _myIdentity(ref);

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: _buildAppBar(context, ref, conversation, soul, messages),
      body: Column(
        children: [
          Expanded(
            child: _MessageList(
              messages: messages,
              soulColor: soul,
              userSoulColor: SovereignColors.soulChef,
              myIdentity: me,
              peerName: conversation.displayName,
              isAgent: conversation.isAgent,
              onReact: (messageId, emoji) => ref
                  .read(conversationProvider(peerId).notifier)
                  .react(messageId, emoji),
              onReply: (message) =>
                  ref.read(replyStateProvider(peerId).notifier).setReply(message),
              onEdit: (messageId, body) => ref
                  .read(conversationProvider(peerId).notifier)
                  .editMessage(messageId, body),
              onOpenThread: (threadId) => showThreadView(
                context: context,
                ref: ref,
                threadId: threadId,
                soulColor: soul,
              ),
            ),
          ),

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

          // Reply composer chip (quotes the message being replied to).
          if (replyTarget != null)
            ReplyPreview(
              replyMessage: replyTarget,
              soulColor: soul,
              onCancel: () =>
                  ref.read(replyStateProvider(peerId).notifier).clear(),
            ),

          InputBar(
            soulColor: soul,
            onSend: (text) async {
              final reply = ref.read(replyStateProvider(peerId));
              final tempId = '${DateTime.now().millisecondsSinceEpoch}';
              // Optimistic insert (carries reply_to_id so the quote renders).
              ref.read(conversationProvider(peerId).notifier).addMessage(
                    ChatMessage(
                      id: tempId,
                      peerId: peerId,
                      content: text,
                      timestamp: DateTime.now(),
                      isOutbound: true,
                      deliveryStatus: 'sent',
                      replyToId: reply?.id,
                      threadId: reply?.threadId,
                      conversationId: peerId,
                      sender: me,
                    ),
                  );
              // Clear the reply chip immediately (the optimistic bubble is in).
              ref.read(replyStateProvider(peerId).notifier).clear();
              // Send to the daemon; carry reply_to_id/thread_id. The contract
              // returns the persisted user turn AND the agent's reply — fold
              // both in so the reply bubble appears without waiting for the
              // next 4s history poll. (Native CLI sends carry no reply here;
              // the history poll renders them instead.)
              final result =
                  await ref.read(skcommsSyncProvider.notifier).sendMessage(
                        peerId: peerId,
                        content: text,
                        inReplyTo: reply?.id,
                        threadId: reply?.threadId,
                      );
              if (result != null &&
                  (result.echoedMessage != null || result.reply != null)) {
                await ref
                    .read(conversationProvider(peerId).notifier)
                    .ingestSendResponse(
                      peerId,
                      echoedMessage: result.echoedMessage,
                      reply: result.reply,
                    );
              }
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

  String _myIdentity(WidgetRef ref) {
    final id = ref.read(daemonServiceProvider).localIdentity;
    return id != null ? normalizePeerKey(id) : 'me';
  }

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
    if (picked == null || picked.files.isEmpty) return;

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
      messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
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

    ref.read(skcommsSyncProvider.notifier).sendMessage(
          peerId: peerId,
          content: body,
        );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    WidgetRef ref,
    conversation,
    Color soul,
    List<ChatMessage> messages,
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
        if (conversation.isAgent == true) ModelPickerButton(peerId: peerId),
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
        // Header menu — per-conversation sub-views.
        PopupMenuButton<int>(
          icon: const Icon(Icons.more_vert_rounded),
          tooltip: 'More options',
          color: SovereignColors.surfaceRaised,
          onSelected: (i) => showConversationSubviews(
            context: context,
            messages: messages,
            soulColor: soul,
            initialIndex: i,
          ),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 0, child: _MenuRow(Icons.photo_library_outlined, 'Media')),
            PopupMenuItem(value: 1, child: _MenuRow(Icons.insert_drive_file_outlined, 'Files')),
            PopupMenuItem(value: 2, child: _MenuRow(Icons.link, 'Links')),
            PopupMenuItem(value: 3, child: _MenuRow(Icons.push_pin_outlined, 'Pinned')),
          ],
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

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: SovereignColors.textSecondary),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: SovereignColors.textPrimary)),
      ],
    );
  }
}

/// Scrollable message list with auto-scroll-to-bottom + scroll-to-message.
class _MessageList extends StatefulWidget {
  const _MessageList({
    required this.messages,
    required this.soulColor,
    required this.userSoulColor,
    required this.myIdentity,
    required this.peerName,
    required this.isAgent,
    required this.onReact,
    required this.onReply,
    required this.onEdit,
    required this.onOpenThread,
  });

  final List<ChatMessage> messages;
  final Color soulColor;
  final Color userSoulColor;
  final String myIdentity;
  final String peerName;
  final bool isAgent;

  final void Function(String messageId, String emoji) onReact;
  final void Function(ChatMessage message) onReply;
  final void Function(String messageId, String body) onEdit;
  final void Function(String threadId) onOpenThread;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
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

  /// Scroll to a specific message index (quoted-reply tap → original).
  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients || index < 0) return;
    // Approximate: jump proportionally to the message position. The ListView is
    // not extent-fixed, so this lands near the original (good enough UX).
    final max = _scrollController.position.maxScrollExtent;
    final frac = widget.messages.isEmpty
        ? 0.0
        : index / widget.messages.length;
    _scrollController.animateTo(
      (max * frac).clamp(0.0, max),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
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
        // Resolve the replied-to message (for the quoted block) within window.
        ChatMessage? repliedTo;
        if (message.replyToId != null) {
          final matches = widget.messages
              .where((m) => m.id == message.replyToId)
              .toList();
          if (matches.isNotEmpty) repliedTo = matches.first;
        }
        return MessageBubble(
          message: message,
          soulColor: widget.soulColor,
          userSoulColor: widget.userSoulColor,
          myIdentity: widget.myIdentity,
          repliedTo: repliedTo,
          onReact: (emoji) => widget.onReact(message.id, emoji),
          onReply: () => widget.onReply(message),
          onEdit: (body) => widget.onEdit(message.id, body),
          onJumpToReplied: repliedTo == null
              ? null
              : () => _scrollToIndex(
                    widget.messages.indexWhere((m) => m.id == repliedTo!.id),
                  ),
          onOpenThread: message.hasThread
              ? () => widget.onOpenThread(message.threadId!)
              : null,
        );
      },
    );
  }
}
