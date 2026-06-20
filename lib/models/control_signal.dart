import 'dart:convert';

/// Typed control signals carried *inside* a chat message body over the normal
/// SKComms text transport (`skchat send` / `POST /api/v1/send`).
///
/// Reactions and typing indicators have no dedicated daemon endpoint reachable
/// from the app: the HTTP client exposes none, and the `skchat react` CLI only
/// mutates an in-memory store that neither transports nor persists across
/// processes. So — mirroring how [AttachmentRef] carries an attachment pointer
/// as a `__ATTACH__:{json}` sentinel — we encode reactions and typing as small
/// single-line sentinels that survive the plaintext transport and are trivial
/// to detect on the receiving side:
///
///   __REACT__:{"target_id":"m-123","emoji":"❤️","action":"add"}
///   __TYPING__:{"state":"start"}
///
/// The receiver parses these out of the message stream and folds them into UI
/// state instead of rendering them as chat text (see `displayTextFor`, which
/// drops both prefixes). Reactions are **persisted** (folded into the target
/// message's `reactions` map); typing is **ephemeral** (sets a transient
/// "is composing" flag and is never stored or shown as a bubble).

/// A reaction event: add or remove an emoji on a target message.
class ReactionSignal {
  const ReactionSignal({
    required this.targetId,
    required this.emoji,
    this.action = 'add',
  });

  /// Id of the message being reacted to.
  final String targetId;

  /// The reaction emoji (e.g. '❤️').
  final String emoji;

  /// 'add' | 'remove'.
  final String action;

  bool get isAdd => action != 'remove';

  /// Sentinel prefix that marks a message body as a reaction signal.
  static const String prefix = '__REACT__:';

  /// Encode as the single-line message body to send over the transport.
  String encode() => '$prefix${jsonEncode({
        'target_id': targetId,
        'emoji': emoji,
        'action': action,
      })}';

  /// Parse a raw message body into a [ReactionSignal], or null if it is not a
  /// well-formed reaction sentinel.
  static ReactionSignal? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (!trimmed.startsWith(prefix)) return null;
    try {
      final decoded = jsonDecode(trimmed.substring(prefix.length));
      if (decoded is! Map) return null;
      final targetId = decoded['target_id'] as String? ?? '';
      final emoji = decoded['emoji'] as String? ?? '';
      if (targetId.isEmpty || emoji.isEmpty) return null;
      final action = decoded['action'] as String? ?? 'add';
      return ReactionSignal(
        targetId: targetId,
        emoji: emoji,
        action: action == 'remove' ? 'remove' : 'add',
      );
    } catch (_) {
      return null;
    }
  }
}

/// An ephemeral typing signal: the sender started or stopped composing.
///
/// Never persisted and never rendered — it only drives the "is composing"
/// strip in the conversation view, and is cleared on stop or after a timeout.
class TypingSignal {
  const TypingSignal({this.state = 'start'});

  /// 'start' | 'stop'.
  final String state;

  bool get isStart => state != 'stop';

  /// Sentinel prefix that marks a message body as a typing signal.
  static const String prefix = '__TYPING__:';

  /// Encode as the single-line message body to send over the transport.
  String encode() => '$prefix${jsonEncode({'state': state})}';

  /// Parse a raw message body into a [TypingSignal], or null if it is not a
  /// well-formed typing sentinel.
  static TypingSignal? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (!trimmed.startsWith(prefix)) return null;
    try {
      final decoded = jsonDecode(trimmed.substring(prefix.length));
      if (decoded is! Map) return null;
      final state = decoded['state'] as String? ?? 'start';
      return TypingSignal(state: state == 'stop' ? 'stop' : 'start');
    } catch (_) {
      return null;
    }
  }
}
