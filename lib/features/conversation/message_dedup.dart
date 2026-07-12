import '../../models/chat_message.dart';

/// Collapse duplicate renderings of the same logical message.
///
/// With a single ingestion path this is mostly a safety net, but it must still
/// reconcile the **optimistic send copy** (client temp-id + local timestamp)
/// with the **daemon `history` copy** (server id + UTC timestamp) of the same
/// outbound message, they share neither id nor timestamp, so we key on
/// (direction-agnostic) trimmed content. The outbound copy wins so the
/// operator's own message stays on the right side, never rendering as a green
/// inbound duplicate.
///
/// Trade-off: two genuinely identical sends collapse to one, acceptable for a
/// chat with an AI agent, and far better than phantom duplicates.
List<ChatMessage> dedupForDisplay(List<ChatMessage> msgs) {
  final out = <ChatMessage>[];
  for (final m in msgs) {
    final content = m.content.trim();
    final idx = out.indexWhere((o) => o.id == m.id || o.content.trim() == content);
    if (idx >= 0) {
      // Keep the outbound copy if this one is outbound and the kept one isn't.
      if (m.isOutbound && !out[idx].isOutbound) out[idx] = m;
      continue;
    }
    out.add(m);
  }
  return out;
}
