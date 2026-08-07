import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skchat_ui/skchat_ui.dart';

import '../../services/group_call_service.dart';
import '../chats/chats_provider.dart';
import 'livekit_call_screen.dart';

/// guest-dm C5: watches the live conversation feed (which the app already polls
/// from `/api/v1/conversations`) for a guest DM whose S6 poll-fallback ring is
/// active (`ringing` + `ring_ts`), and surfaces the newest un-dismissed one.
///
/// This is the poll-only counterpart to [IncomingCallWatcher] (which polls
/// `/call/incoming` for member calls). It dedupes by `peerId:ring_ts` so a ring
/// the operator already answered or dismissed never re-appears, and a revoked/
/// expired contact never rings.
class GuestRingNotifier extends Notifier<Conversation?> {
  final Set<String> _handled = {};

  static String _key(Conversation c) => '${c.peerId}:${c.ringTs}';

  @override
  Conversation? build() {
    final ringing = ref
        .watch(chatsProvider)
        .where((c) => c.isGuestDm && c.ringing && !c.isGuestInactive)
        .toList()
      ..sort((a, b) => (b.ringTs ?? 0).compareTo(a.ringTs ?? 0));
    for (final c in ringing) {
      if (!_handled.contains(_key(c))) return c;
    }
    return null;
  }

  /// Stop showing this ring (answered or dismissed) without re-ringing it.
  void dismiss(Conversation c) {
    _handled.add(_key(c));
    ref.invalidateSelf();
  }
}

final guestRingProvider =
    NotifierProvider<GuestRingNotifier, Conversation?>(GuestRingNotifier.new);

/// The operator's incoming guest-ring banner. Mirrors [IncomingCallBanner]:
/// renders nothing when no guest is ringing, else an Answer / Dismiss strip
/// with the alias-wins identity (never the raw group name or an un-prefixed
/// guest self-name).
class GuestRingBanner extends ConsumerWidget {
  const GuestRingBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ringing = ref.watch(guestRingProvider);
    if (ringing == null) return const SizedBox.shrink();
    final notifier = ref.read(guestRingProvider.notifier);
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
              Expanded(
                child: Text('Incoming call from ${ringing.guestTitle}'),
              ),
              TextButton(
                key: const Key('guest-ring-dismiss'),
                onPressed: () => notifier.dismiss(ringing),
                child: const Text('Dismiss'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                key: const Key('guest-ring-answer'),
                onPressed: () => _answer(context, ref, ringing),
                child: const Text('Answer'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Answer joins the DM group's call room via the existing group-call join path
  /// (never re-rings anyone), then opens the call screen. The ring is dismissed
  /// either way so it does not linger.
  Future<void> _answer(
    BuildContext context, WidgetRef ref, Conversation c) async {
    final notifier = ref.read(guestRingProvider.notifier);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    notifier.dismiss(c);
    try {
      final s = await ref.read(groupCallServiceProvider).joinCall(c.peerId);
      if (!navigator.mounted) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => LiveKitCallScreen(
            args: LiveKitCallArgs(
              roomName: s.room,
              identity: s.identity,
              displayName: c.guestTitle,
              withVideo: true,
              preMintedToken: s.token,
              livekitUrl: s.livekitUrl,
            ),
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not join the call.')),
      );
    }
  }
}
