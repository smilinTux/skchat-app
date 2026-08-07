import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skchat_ui/skchat_ui.dart' show guestDisplayTitle;

import '../../core/theme/sovereign_colors.dart';
import '../../services/guest_group_service.dart';
import '../calls/livekit_call_screen.dart';
import 'guest_download.dart';
import 'guest_invite_inactive.dart';

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
  const GuestRoomScreen({
    super.key,
    required this.join,
    this.isDm = false,
    this.operatorName,
  });

  final GuestJoinResult join;

  /// guest-dm C2: a mode=dm invite renders 1:1 framing (title = operator name)
  /// instead of the group name + a chat, not group, mental model.
  final bool isDm;

  /// The operator's display name for the DM header (from the invite preview).
  final String? operatorName;

  @override
  ConsumerState<GuestRoomScreen> createState() => _GuestRoomScreenState();
}

class _GuestRoomScreenState extends ConsumerState<GuestRoomScreen> {
  final _composeCtl = TextEditingController();
  final _scrollCtl = ScrollController();
  late List<Map<String, dynamic>> _messages;
  // guest-dm C2: session token + display name are mutable, a self-rename remints
  // the token (S5) and the caller must swap it or the change reverts.
  late String _session;
  late String _displayName;
  // guest-dm G6: the room's thread mode ("dm" | "gdm") + the guest-visible
  // roster, refreshed on every poll so a dm -> gdm promotion mid-session is
  // caught live (no reload needed - build() just reads _mode).
  String? _mode;
  List<GuestRoomMember> _members = const [];
  // The first _refresh() is the initial load (already in widget.join.messages
  // in spirit); only diffs AFTER it should produce a "so-and-so joined" line,
  // so a fresh join never opens with a synthetic notice about itself.
  bool _rosterLoaded = false;
  final List<_JoinNotice> _joinNotices = [];
  // Non-null once a contact-terminal 403 (revoked/expired) is seen anywhere in
  // the room: the whole screen swaps to the inactive view (S3 reason codes).
  String? _terminalReason;
  bool _renaming = false;
  bool _sending = false;
  bool _uploading = false;
  bool _callConnecting = false;
  Timer? _pollTimer;

  GuestGroupService get _svc => ref.read(guestGroupServiceProvider);
  String get _token => _session;

  /// The DM 1:1 title (operator name) or the group name.
  String get _title =>
      widget.isDm ? (widget.operatorName ?? widget.join.groupName) : widget.join.groupName;

  /// If [error] is a contact-terminal 403 (S3), record the reason so [build]
  /// swaps to the inactive view, and return true. Callers stop after this.
  bool _handleTerminal(Object error) {
    final reason = contactTerminalReason(error);
    if (reason == null) return false;
    if (mounted) setState(() => _terminalReason = reason);
    return true;
  }

  @override
  void initState() {
    super.initState();
    _session = widget.join.sessionToken;
    _displayName = widget.join.displayName;
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
      final convo = await _svc.conversation(_token);
      if (!mounted) return;
      // guest-dm G6: diff the roster against the last poll to notice a NEW
      // member (a guest who joined while this guest was sitting in the room).
      // Skipped on the very first load (nothing to diff against yet).
      if (_rosterLoaded) {
        final priorIds = _members.map((m) => m.identityUri).toSet();
        for (final m in convo.members) {
          if (!m.isSelf && !priorIds.contains(m.identityUri)) {
            _joinNotices.add(_JoinNotice(
              afterIndex: convo.messages.length,
              text: _joinNoticeText(m),
            ));
          }
        }
      }
      _rosterLoaded = true;
      setState(() {
        _mode = convo.mode;
        _members = convo.members;
        _messages = _mergeJoinNotices(convo.messages, _joinNotices);
      });
      _scrollToBottom();
    } catch (e) {
      // The 3s poller is the most likely place to first see a revoke/expiry:
      // swap to the inactive view. Otherwise stay on the last-known messages
      // (the server may be briefly unreachable).
      _handleTerminal(e);
    }
  }

  /// guest-dm C2: change my own display name (S5 remints the session token).
  Future<void> _rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || _renaming) return;
    setState(() => _renaming = true);
    try {
      final res = await _svc.rename(sessionToken: _token, name: trimmed);
      final newToken = res['session_token'] as String?;
      final newName = (res['display_name'] as String?) ?? trimmed;
      if (!mounted) return;
      setState(() {
        // Swap in the reminted token, or the change reverts on the next request.
        if (newToken != null && newToken.isNotEmpty) _session = newToken;
        _displayName = newName;
      });
    } catch (e) {
      if (_handleTerminal(e)) return;
      _snack('Could not change your name.');
    } finally {
      if (mounted) setState(() => _renaming = false);
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
        // Show the plaintext we typed, not the sealed pqdm1 token the server
        // echoes back (we sealed to the operator and cannot open our own send).
        final shown = {...msg, 'body': body, 'content': body};
        setState(() => _messages = [..._messages, shown]);
        _scrollToBottom();
      }
    } catch (e) {
      if (_handleTerminal(e)) return;
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
      if (_handleTerminal(e)) return;
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
    } catch (e) {
      if (_handleTerminal(e)) return;
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

  /// guest-dm C2: prompt for a new self-name, prefilled with the current one.
  Future<void> _promptRename() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: _displayName),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _rename(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    // Contact revoked/expired (S3): the room is gone, nothing to retry.
    if (_terminalReason != null) {
      return GuestInviteInactiveView(reason: _terminalReason);
    }
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        // No leading back-to-shell: a guest has nowhere else to go.
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_title,
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
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'rename') _promptRename();
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'rename',
                child: Text('Change my name'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // guest-dm G6: persistent notice once the room is a group - reads
          // live off _mode, so a dm -> gdm flip seen mid-session (the 3s
          // poller) shows it immediately, no reload required.
          if (_mode == 'gdm') const _GdmBanner(),
          // Strip is a gdm affordance only. In a 1:1 the guest already knows
          // who the host is (it names the room), so showing it there would
          // just re-skin the landing C2 shipped.
          if (_mode == 'gdm' && _members.length > 1)
            _MemberStrip(members: _members),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                controller: _scrollCtl,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (_, i) {
                  final m = _messages[i];
                  if (m['is_system'] == true) {
                    return _SystemLine(text: (m['body'] as String?) ?? '');
                  }
                  return _GuestBubble(
                    msg: m,
                    selfId: widget.join.guestId,
                    fileUrl: _svc.fileUrl,
                    onReact: _react,
                  );
                },
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

/// guest-dm G6: wording for the local "someone joined" line. Only guests join
/// after the initial roster (the operator seat is already present at join
/// time), but a non-guest fallback keeps this correct if that ever changes.
String _joinNoticeText(GuestRoomMember m) {
  final who = m.isGuest ? guestDisplayTitle(null, m.displayName) : 'the host';
  return '$who joined the room.';
}

/// A local-only "X joined" line, positioned at [afterIndex] into the server
/// message list AS OF the poll that detected it - so on later polls, once
/// more real messages have arrived, it still renders roughly where the join
/// actually happened instead of always trailing at the very end. Never sent
/// to or read from the server.
class _JoinNotice {
  const _JoinNotice({required this.afterIndex, required this.text});
  final int afterIndex;
  final String text;
}

/// Weave the accumulated [notices] into [serverMsgs] at their captured
/// positions. Marked `is_system: true` so the list renders them as a
/// centered system line, not a chat bubble (see [_SystemLine]).
List<Map<String, dynamic>> _mergeJoinNotices(
  List<Map<String, dynamic>> serverMsgs,
  List<_JoinNotice> notices,
) {
  if (notices.isEmpty) return serverMsgs;
  final out = <Map<String, dynamic>>[];
  var noticeIdx = 0;
  for (var i = 0; i <= serverMsgs.length; i++) {
    while (noticeIdx < notices.length && notices[noticeIdx].afterIndex == i) {
      out.add(_systemLineMessage(notices[noticeIdx].text, noticeIdx));
      noticeIdx++;
    }
    if (i < serverMsgs.length) out.add(serverMsgs[i]);
  }
  // Fail-safe: a notice captured past the current server length (shouldn't
  // happen - afterIndex is stamped from the same poll's message count) still
  // renders, at the end, rather than silently vanishing.
  while (noticeIdx < notices.length) {
    out.add(_systemLineMessage(notices[noticeIdx].text, noticeIdx));
    noticeIdx++;
  }
  return out;
}

Map<String, dynamic> _systemLineMessage(String text, int idx) => {
      'id': 'local-join-notice-$idx',
      'is_system': true,
      'body': text,
      'content': text,
    };

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

/// guest-dm G6: the persistent "your audience changed" notice. Shown for the
/// life of the room once `mode == "gdm"` - plain, honest wording for a
/// non-technical guest, no jargon like "promoted" or "gdm".
class _GdmBanner extends StatelessWidget {
  const _GdmBanner();

  static const text =
      'This conversation is now a group chat. Other people, not just the '
      'host, can read what you send here.';

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: SovereignColors.accentWarning.withValues(alpha: 0.14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.group_outlined,
              size: 16, color: SovereignColors.accentWarning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: tt.bodySmall?.copyWith(color: SovereignColors.accentWarning),
            ),
          ),
        ],
      ),
    );
  }
}

/// guest-dm G6: a lightweight horizontal strip of who is in the room. Other
/// guests render as `guest: <name>` (untrusted styling, same anti-spoof rule
/// as the rest of the app - see [guestDisplayTitle]); the operator's `guest:
/// false` row is the trusted host; the caller's own row reads "you".
class _MemberStrip extends StatelessWidget {
  const _MemberStrip({required this.members});
  final List<GuestRoomMember> members;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: members.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) => _MemberChip(member: members[i]),
      ),
    );
  }
}

class _MemberChip extends StatelessWidget {
  const _MemberChip({required this.member});
  final GuestRoomMember member;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final String label;
    final Color color;
    if (member.isSelf) {
      label = 'you';
      color = SovereignColors.textSecondary;
    } else if (!member.isGuest) {
      label = 'host';
      color = SovereignColors.accentEncrypt;
    } else {
      label = guestDisplayTitle(null, member.displayName);
      color = SovereignColors.accentWarning;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: tt.bodySmall?.copyWith(color: color, fontSize: 11),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// guest-dm G6: a centered, local-only "so-and-so joined" line - not a chat
/// bubble, so it reads as a room event rather than something someone said.
class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: tt.bodySmall?.copyWith(
            color: SovereignColors.textSecondary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
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

/// Self-contained rename dialog: owns its [TextEditingController] so it is
/// disposed with the dialog State (not synchronously after pop, which would tear
/// down the field while the route is still animating out).
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change my name'),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Display name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctl.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
