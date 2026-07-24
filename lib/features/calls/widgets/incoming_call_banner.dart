import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../call_session.dart';

/// Ringing incoming-call banner. Watches [callSessionProvider] and shows an
/// Accept / Decline strip while a call is ringing-incoming; otherwise renders
/// nothing (SizedBox.shrink) so it costs nothing when idle.
class IncomingCallBanner extends ConsumerWidget {
  const IncomingCallBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(callSessionProvider);
    if (s == null || s.status != CallSessionStatus.ringing || !s.isIncoming) {
      return const SizedBox.shrink();
    }
    final notifier = ref.read(callSessionProvider.notifier);
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.call_received_rounded),
              const SizedBox(width: 10),
              Expanded(child: Text('Incoming call from ${s.peerName}')),
              TextButton(
                key: const Key('incoming-decline'),
                onPressed: notifier.declineIncoming,
                child: const Text('Decline'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                key: const Key('incoming-accept'),
                onPressed: notifier.acceptIncoming,
                child: const Text('Accept'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
