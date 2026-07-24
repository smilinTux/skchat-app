import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/call_api_client.dart';
import 'call_session.dart';

/// Polls the server /call/incoming and surfaces the newest unhandled invite as
/// a ringing CallSession. Dedupes by nonce so the same server-retained invite
/// is not re-rung after the user handled it. A poll failure is swallowed (the
/// next tick retries) so a transient error never spams a phantom ring.
class IncomingCallWatcher {
  IncomingCallWatcher(this._ref);
  final Ref _ref;
  final Set<String> _handled = {};

  Future<void> pollOnce() async {
    // Never interrupt a call already in progress.
    final cur = _ref.read(callSessionProvider);
    if (cur != null && cur.status != CallSessionStatus.idle) return;

    List<CallInvite> invites;
    try {
      invites = await _ref.read(callApiProvider).pollIncoming();
    } catch (_) {
      return; // silent retry next tick
    }
    if (invites.isEmpty) return;
    // Newest by ts; skip any nonce we already surfaced.
    invites.sort((a, b) => b.ts.compareTo(a.ts));
    final fresh = invites.where((i) => !_handled.contains(i.nonce)).toList();
    if (fresh.isEmpty) return;
    final invite = fresh.first;
    _handled.add(invite.nonce);
    _ref.read(callSessionProvider.notifier).receiveIncoming(invite);
  }
}

final incomingCallWatcherProvider =
    Provider<IncomingCallWatcher>((ref) => IncomingCallWatcher(ref));
