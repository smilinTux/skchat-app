import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/theme.dart';
import '../../../models/chat_message.dart';
import '../../../services/daemon_service.dart';
import '../../../services/skcomms_client.dart';
import '../../../core/chat_text.dart';
import 'message_bubble.dart';

/// Opens the thread view as a modal sheet for [threadId], fetching
/// `GET /api/v1/thread/{id}`. Read-only display of the thread's messages with
/// the same bubble rendering as the main conversation (golden-rule included).
Future<void> showThreadView({
  required BuildContext context,
  required WidgetRef ref,
  required String threadId,
  required Color soulColor,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _ThreadView(
        threadId: threadId,
        soulColor: soulColor,
        client: ref.read(skcommsClientProvider),
        localIdentity: ref.read(daemonServiceProvider).localIdentity,
      ),
    ),
  );
}

class _ThreadView extends StatefulWidget {
  const _ThreadView({
    required this.threadId,
    required this.soulColor,
    required this.client,
    required this.localIdentity,
  });

  final String threadId;
  final Color soulColor;
  final SKCommsClient client;
  final String? localIdentity;

  @override
  State<_ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<_ThreadView> {
  List<ChatMessage>? _messages;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await widget.client.getThread(widget.threadId);
      final localShort = widget.localIdentity != null
          ? normalizePeerKey(widget.localIdentity!)
          : null;
      final msgs = raw.map((j) {
        final m = ChatMessage.fromJson(j);
        final senderShort =
            m.sender != null ? normalizePeerKey(m.sender!) : '';
        final isOut = localShort != null && senderShort == localShort;
        return m.copyWith(isOutbound: isOut);
      }).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (mounted) setState(() => _messages = msgs);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Container(
        color: SovereignColors.surfaceBase,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: SovereignColors.textTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.forum_outlined, color: widget.soulColor, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Thread',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: SovereignColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_error) {
      return const Center(
        child: Text('Could not load thread',
            style: TextStyle(color: SovereignColors.textTertiary)),
      );
    }
    final msgs = _messages;
    if (msgs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (msgs.isEmpty) {
      return const Center(
        child: Text('No messages in this thread yet',
            style: TextStyle(color: SovereignColors.textTertiary)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: msgs.length,
      itemBuilder: (context, i) => MessageBubble(
        message: msgs[i],
        soulColor: widget.soulColor,
      ),
    );
  }
}
