import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/conversation.dart';
import '../../../services/peer_trust_store.dart';
import '../../calls/call_gate.dart';
import '../../calls/call_session.dart';
import '../../identity/verify_peer_sheet.dart';

/// Single app-bar Call control for a 1:1 conversation: tap = audio call,
/// long-press = video call. Both route through CallSession after the
/// verify-before-call trust gate (red peer blocked, same prompt as before).
class ConversationCallButton extends ConsumerWidget {
  const ConversationCallButton({super.key, required this.conversation});

  final Conversation conversation;

  Future<void> _startGated(BuildContext context, WidgetRef ref, {required bool video}) async {
    final messenger = ScaffoldMessenger.of(context);
    final tier = await ref
        .read(peerTrustResolverProvider)
        .tierFor(conversation.peerId, conversation.soulFingerprint);
    if (!canCall(tier)) {
      messenger.showSnackBar(SnackBar(
        content: Text('Verify ${conversation.displayName} before calling'),
        action: SnackBarAction(
          label: 'Verify',
          onPressed: () {
            if (!context.mounted) return;
            showVerifyPeerSheet(
              context,
              ref,
              peerId: conversation.peerId,
              peerName: conversation.displayName,
              peerFingerprint: conversation.soulFingerprint,
            );
          },
        ),
      ));
      return;
    }
    await ref.read(callSessionProvider.notifier).startOutgoing(
          peer: conversation.peerId,
          peerName: conversation.displayName,
          video: video,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The tooltip is its own Tooltip (not IconButton.tooltip) with a manual
    // trigger: IconButton.tooltip wraps the button in a Tooltip whose
    // default trigger is itself a long-press gesture recognizer, which wins
    // the gesture arena over the GestureDetector below and silently
    // swallows the long-press-for-video tap. Manual trigger keeps the
    // message for accessibility/semantics without competing for the gesture.
    return Tooltip(
      message: 'Call (long-press for video)',
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPress: () => _startGated(context, ref, video: true),
        child: IconButton(
          key: const Key('conversation-call-button'),
          icon: const Icon(Icons.call_outlined),
          onPressed: () => _startGated(context, ref, video: false),
        ),
      ),
    );
  }
}
