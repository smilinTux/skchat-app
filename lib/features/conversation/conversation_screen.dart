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
import '../../services/group_call_service.dart';
import '../calls/call_provider.dart';
import '../calls/livekit_call_screen.dart';
import '../chats/chats_provider.dart';
import '../groups/groups_provider.dart';
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
      // Explicitly resize the body to the soft-keyboard inset. On mobile web
      // this (combined with the bottom-anchored reverse list + inset-padded
      // composer below, and the `interactive-widget=resizes-content` viewport
      // meta in web/index.html) keeps the conversation visible instead of the
      // browser scrolling the whole canvas up when the composer is focused.
      resizeToAvoidBottomInset: true,
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

  /// Promote this 1:1 into a group by adding a member (SAME room id).
  ///
  /// Opens a peer picker; on selection it calls
  /// `POST /api/v1/groups/{peerId}/members`, which the backend treats as a
  /// promote-1:1 (no new object id, existing history carried). The new group
  /// then appears in the chat/groups list and we land on the group info screen.
  /// Start a group A/V call: ask the daemon to mint a member-scoped LiveKit
  /// token + ring the other members (`POST /api/v1/groups/{id}/call/start`),
  /// then open the multi-party call screen with the pre-minted token. Works on
  /// web (same-origin HTTP), not the CLI.
  Future<void> _startGroupCall(
    BuildContext context,
    WidgetRef ref,
    String groupName,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final svc = ref.read(groupCallServiceProvider);
    try {
      // Join an already-active room (no re-ring); otherwise start + ring.
      GroupCallSession session;
      try {
        final live = await svc.participants(peerId);
        session = live.active > 0
            ? await svc.joinCall(peerId)
            : await svc.startCall(peerId, topic: 'Call: $groupName');
      } catch (_) {
        // Participants probe failed (SFU unreachable) — fall back to start.
        session = await svc.startCall(peerId, topic: 'Call: $groupName');
      }
      if (!context.mounted) return;
      context.push(
        AppRoutes.livekitCall,
        extra: LiveKitCallArgs(
          roomName: session.room,
          identity: session.identity,
          displayName: groupName,
          withVideo: true,
          preMintedToken: session.token,
          livekitUrl: session.livekitUrl,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Group call failed: $e')),
      );
    }
  }

  Future<void> _promoteToGroup(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final chats = ref.read(chatsProvider);
    // Candidate members: other 1:1 conversations (not this one, not groups).
    final candidates = chats
        .where((c) => !c.isGroup && c.peerId != peerId)
        .toList();

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        final tt = Theme.of(sheetCtx).textTheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text('Add people',
                    style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Adding someone turns this chat into a group.',
                  style: tt.bodySmall
                      ?.copyWith(color: SovereignColors.textTertiary),
                ),
              ),
              if (candidates.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No other peers to add yet.'),
                )
              else
                ...candidates.map((c) => ListTile(
                      leading: SoulAvatar(
                        soulColor: c.resolvedSoulColor,
                        initials: c.resolvedInitials,
                        isAgent: c.isAgent,
                        isOnline: c.isOnline,
                        size: 40,
                      ),
                      title: Text(c.displayName),
                      subtitle: Text(c.isAgent ? 'Agent' : 'Human',
                          style: TextStyle(
                              color: SovereignColors.textTertiary,
                              fontSize: 12)),
                      onTap: () => Navigator.of(sheetCtx).pop(c.peerId),
                    )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked == null) return;

    final client = ref.read(skcommsClientProvider);
    try {
      // The backend promotes the 1:1 (peerId) into a group of the same id.
      await client.addGroupMember(peerId, identity: picked);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not create group: $e')));
      return;
    }
    // Refresh the lists so the new group appears (is_group:true).
    await ref.read(groupsProvider.notifier).refresh();
    await ref.read(chatsProvider.notifier).refresh();
    if (!context.mounted) return;
    context.push(AppRoutes.groupInfoPath(peerId));
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
        // Group info (groups) OR "add people" → promote a 1:1 to a group.
        if (conversation.isGroup == true)
          IconButton(
            icon: const Icon(Icons.group_outlined),
            tooltip: 'Group info',
            onPressed: () => context.push(AppRoutes.groupInfoPath(peerId)),
          )
        else
          Consumer(
            builder: (context, ref, _) => IconButton(
              icon: const Icon(Icons.group_add_outlined),
              tooltip: 'Add people (make a group)',
              onPressed: () => _promoteToGroup(context, ref),
            ),
          ),
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
            tooltip: conversation.isGroup == true
                ? 'Group video call'
                : 'Video call',
            onPressed: () {
              final conversations = ref.read(chatsProvider);
              final conv = conversations.firstWhere(
                (c) => c.peerId == peerId,
                orElse: () => conversations.first,
              );
              if (conversation.isGroup == true) {
                _startGroupCall(context, ref, conv.displayName);
                return;
              }
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

  /// Last-seen bottom view inset (soft-keyboard height). When it changes we
  /// re-pin to the bottom so the latest message stays just above the keyboard.
  double _lastBottomInset = 0;

  @override
  void initState() {
    super.initState();
    // Bottom-anchored (reverse:true) list: the bottom is offset 0, so a fresh
    // list already starts pinned to the newest message — no jump needed. Keep
    // an explicit pin for safety on the first frame.
    _scrollToBottom(animate: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // React to the soft keyboard opening/closing. On mobile web the browser may
    // shift the canvas when the composer is focused; re-pinning to the bottom
    // keeps the latest messages visible above the keyboard instead of blank.
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset != _lastBottomInset) {
      _lastBottomInset = inset;
      _scrollToBottom(animate: false);
    }
  }

  @override
  void didUpdateWidget(_MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages.length != oldWidget.messages.length) {
      _scrollToBottom();
    }
  }

  /// Scroll so the NEWEST message is visible. With `reverse: true` the newest
  /// item is at the start of the scroll range, i.e. minScrollExtent (offset 0).
  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.minScrollExtent; // == 0.0
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
  /// `index` is in chronological (widget.messages) order; the reversed list
  /// puts the newest at offset 0, so a higher chronological index sits closer
  /// to offset 0.
  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients || index < 0) return;
    // Approximate: jump proportionally to the message position. The ListView is
    // not extent-fixed, so this lands near the original (good enough UX). In a
    // reversed list, offset grows from newest(0)→oldest(max), so we invert the
    // chronological fraction.
    final max = _scrollController.position.maxScrollExtent;
    final count = widget.messages.length;
    final frac = count <= 1 ? 0.0 : (count - 1 - index) / (count - 1);
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
    final count = widget.messages.length;
    return ListView.builder(
      controller: _scrollController,
      // Bottom-anchored: newest message pins to the bottom of the viewport, so
      // it stays visible just above the soft keyboard on mobile web (where the
      // browser/canvas resize for the keyboard is unreliable, esp. iOS Safari).
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: count,
      itemBuilder: (context, index) {
        // reverse:true → walk the message list from newest to oldest.
        final message = widget.messages[count - 1 - index];
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
