import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sovereign_colors.dart';
import '../../services/guest_group_service.dart';
import '../calls/livekit_call_screen.dart';
import 'guest_download.dart';

/// The FULL in-room experience for a guest, scoped to ONE group.
///
/// Exposes everything a normal member can do *in this room*:
///   - read + send (signed) text messages
///   - reactions (long-press a bubble)
///   - attach + send files, download files
///   - join the group call (with screenshare available in-call)
///
/// And NOTHING else: no bottom nav, no other conversations, no peer list, no
/// add-member / invite / rename / admin actions. An untrusted-guest badge is
/// always shown. All scoping is enforced server-side by the session token.
class GuestRoomScreen extends ConsumerStatefulWidget {
  const GuestRoomScreen({super.key, required this.join});

  final GuestJoinResult join;

  @override
  ConsumerState<GuestRoomScreen> createState() => _GuestRoomScreenState();
}

class _GuestRoomScreenState extends ConsumerState<GuestRoomScreen> {
  final _composeCtl = TextEditingController();
  final _scrollCtl = ScrollController();
  late List<Map<String, dynamic>> _messages;
  bool _sending = false;
  bool _uploading = false;
  bool _callConnecting = false;
  Timer? _pollTimer;

  GuestGroupService get _svc => ref.read(guestGroupServiceProvider);
  String get _token => widget.join.sessionToken;

  @override
  void initState() {
    super.initState();
    _messages = List.of(widget.join.messages);
    _refresh();
    // Poll the room so the guest sees NEW messages from the operator/members
    // (previously refreshed only once on join → sovereign→guest posts never
    // appeared). The server returns the full thread; this reconciles it.
    _pollTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _composeCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final msgs = await _svc.conversation(_token);
      if (!mounted) return;
      setState(() => _messages = msgs);
      _scrollToBottom();
    } catch (_) {
      // Stay on the last-known messages; the server may be briefly unreachable.
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtl.hasClients) {
        _scrollCtl.jumpTo(_scrollCtl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final body = _composeCtl.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final msg = await _svc.send(
        sessionToken: _token,
        groupId: widget.join.groupId,
        body: body,
      );
      _composeCtl.clear();
      if (msg.isNotEmpty) {
        setState(() => _messages = [..._messages, msg]);
        _scrollToBottom();
      }
    } catch (e) {
      _snack('Could not send message.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attach() async {
    if (_uploading) return;
    final picked = await FilePicker.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final bytes = f.bytes;
    if (bytes == null) {
      _snack('Could not read the selected file.');
      return;
    }
    setState(() => _uploading = true);
    try {
      final res = await _svc.uploadFile(
        sessionToken: _token,
        filename: f.name,
        bytes: bytes,
      );
      final msg = (res['message'] as Map?)?.cast<String, dynamic>();
      if (msg != null) {
        setState(() => _messages = [..._messages, msg]);
        _scrollToBottom();
      }
    } catch (e) {
      _snack('Upload failed.');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _react(String messageId, String emoji) async {
    try {
      await _svc.react(sessionToken: _token, messageId: messageId, emoji: emoji);
      await _refresh();
    } catch (_) {
      _snack('Reaction failed.');
    }
  }

  Future<void> _joinCall() async {
    if (_callConnecting) return;
    setState(() => _callConnecting = true);
    try {
      String? token = widget.join.callToken;
      String? url = widget.join.callUrl;
      String? room = widget.join.callRoom;
      if (token == null || url == null) {
        // (Re)mint a fresh call token for the bound room via /api/v1/guest/call.
        final res = await _svc.callToken(_token);
        if (res['available'] == true) {
          token = res['token'] as String?;
          url = res['lk_url'] as String?;
          room = (res['room'] as String?) ?? room;
        }
      }
      if (token == null || url == null) {
        _snack('The call is not available right now.');
        return;
      }
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LiveKitCallScreen(
            args: LiveKitCallArgs(
              roomName: room ?? widget.join.groupId,
              identity: widget.join.guestId,
              displayName: widget.join.displayName,
              withVideo: true,
              preMintedToken: token,
              livekitUrl: url,
            ),
          ),
        ),
      );
    } catch (_) {
      _snack('Could not start the call.');
    } finally {
      if (mounted) setState(() => _callConnecting = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        // No leading back-to-shell: a guest has nowhere else to go.
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.join.groupName,
                style: tt.titleMedium, overflow: TextOverflow.ellipsis),
            const _GuestBadge(),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Join call',
            icon: _callConnecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.videocam_outlined),
            onPressed: _callConnecting ? null : _joinCall,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                controller: _scrollCtl,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (_, i) => _GuestBubble(
                  msg: _messages[i],
                  selfId: widget.join.guestId,
                  fileUrl: _svc.fileUrl,
                  onReact: _react,
                ),
              ),
            ),
          ),
          _Composer(
            controller: _composeCtl,
            sending: _sending,
            uploading: _uploading,
            calling: _callConnecting,
            onSend: _send,
            onAttach: _attach,
            onCall: _joinCall,
          ),
        ],
      ),
    );
  }
}

/// The always-visible untrusted-guest badge.
class _GuestBadge extends StatelessWidget {
  const _GuestBadge();
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.shield_outlined,
            size: 12, color: SovereignColors.accentWarning),
        const SizedBox(width: 4),
        Text(
          'Guest · untrusted',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: SovereignColors.accentWarning,
                fontSize: 11,
              ),
        ),
      ],
    );
  }
}

class _GuestBubble extends StatelessWidget {
  const _GuestBubble({
    required this.msg,
    required this.selfId,
    required this.fileUrl,
    required this.onReact,
  });

  final Map<String, dynamic> msg;
  final String selfId;
  final String Function(String transferId) fileUrl;
  final void Function(String messageId, String emoji) onReact;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final sender = (msg['sender'] as String?) ?? '';
    final mine = sender == selfId;
    final body = (msg['body'] as String?) ?? (msg['content'] as String?) ?? '';
    final id = (msg['id'] as String?) ?? '';
    final isGuest = msg['is_guest'] == true;
    final atts = (msg['attachments'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: id.isEmpty ? null : () => _showReactions(context, id),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(
            color: mine
                ? SovereignColors.soulLumina.withValues(alpha: 0.18)
                : SovereignColors.surfaceRaised,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine)
                Text(
                  (msg['sender_name'] as String?) ?? 'Member',
                  style: tt.bodySmall?.copyWith(
                    color: isGuest
                        ? SovereignColors.accentWarning
                        : SovereignColors.textSecondary,
                  ),
                ),
              if (body.isNotEmpty) Text(body, style: tt.bodyMedium),
              for (final a in atts) _FileChip(att: a, url: fileUrl),
            ],
          ),
        ),
      ),
    );
  }

  void _showReactions(BuildContext context, String id) {
    const emojis = ['👍', '❤️', '😂', '🎉', '👀', '🙏'];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SovereignColors.surfaceRaised,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (final e in emojis)
              IconButton(
                icon: Text(e, style: const TextStyle(fontSize: 26)),
                onPressed: () {
                  Navigator.of(context).pop();
                  onReact(id, e);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.att, required this.url});
  final Map<String, dynamic> att;
  final String Function(String transferId) url;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final tid = (att['transfer_id'] as String?) ?? '';
    final name = (att['filename'] as String?) ?? 'file';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        onTap: tid.isEmpty ? null : () => GuestDownload.open(url(tid)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.attach_file,
                size: 16, color: SovereignColors.soulLumina),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                style: tt.bodySmall?.copyWith(
                  color: SovereignColors.soulLumina,
                  decoration: TextDecoration.underline,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

}


class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.uploading,
    required this.calling,
    required this.onSend,
    required this.onAttach,
    required this.onCall,
  });

  final TextEditingController controller;
  final bool sending;
  final bool uploading;
  final bool calling;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            IconButton(
              icon: uploading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              onPressed: uploading ? null : onAttach,
              tooltip: 'Attach file',
            ),
            IconButton(
              icon: calling
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.call_outlined),
              color: SovereignColors.soulLumina,
              onPressed: calling ? null : onCall,
              tooltip: 'Start call',
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Message',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              color: SovereignColors.soulLumina,
              onPressed: sending ? null : onSend,
            ),
          ],
        ),
      ),
    );
  }
}
