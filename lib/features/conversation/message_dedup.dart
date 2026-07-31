import '../../models/chat_message.dart';

/// How far apart two copies of the *same logical message* can be and still be
/// reconciled by content. The optimistic send copy (client temp-id, local now)
/// and the daemon `history` copy (server id, UTC) of one send are the same
/// instant, so their absolute difference is only the send-to-persist latency
/// (a second or two) plus any device/server clock skew. This window is the
/// bound on that skew — wide enough to always fold the pair, far below the
/// interval at which a user re-sends identical text on purpose.
///
/// This is a heuristic bridge. The durable fix is a stable client-generated
/// message id that survives optimistic -> persisted and is echoed by the
/// server, so dedup keys on identity alone and no window is needed. See
/// docs/superpowers/specs/2026-07-31-skchat-dm-thread-consistency.md.
const Duration kReconcileWindow = Duration(seconds: 120);

/// Collapse duplicate renderings of the *same logical message*.
///
/// Two rows are the same message when they share an [ChatMessage.id], OR they
/// carry identical trimmed content within [kReconcileWindow] of each other (the
/// optimistic send copy vs the daemon `history` copy of one send — they share
/// neither id nor exact timestamp). The outbound copy wins so the operator's
/// own message stays on the right side, never rendering as a green inbound
/// duplicate.
///
/// The window is load-bearing: WITHOUT it, identical text sent far apart (a
/// user re-testing with "hello" weeks later) collapsed into the older copy, so
/// the just-sent message vanished from the thread while the conversation-list
/// overview — updated directly, with no content collapse — still showed it.
/// That divergence was the "sent message missing from the open DM" bug.
List<ChatMessage> dedupForDisplay(List<ChatMessage> msgs) {
  final out = <ChatMessage>[];
  for (final m in msgs) {
    final content = m.content.trim();
    final idx = out.indexWhere(
      (o) =>
          o.id == m.id ||
          (o.content.trim() == content &&
              o.timestamp.difference(m.timestamp).abs() <= kReconcileWindow),
    );
    if (idx >= 0) {
      // Keep the outbound copy if this one is outbound and the kept one isn't.
      if (m.isOutbound && !out[idx].isOutbound) out[idx] = m;
      continue;
    }
    out.add(m);
  }
  return out;
}
