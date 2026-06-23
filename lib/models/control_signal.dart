import 'dart:convert';

/// Typed control signals carried *inside* a chat message body over the normal
/// SKComms text transport (`skchat send` / `POST /api/v1/send`).
///
/// The typed-message contract adds first-class HTTP endpoints
/// (`/api/v1/react`, `/api/v1/edit`, `/api/v1/receipt`). The app calls those
/// endpoints when reachable, but the **native CLI transport** (`skchat send`,
/// the canonical history path) carries only plaintext bodies. So -- mirroring
/// how [AttachmentRef] carries an attachment pointer as a `__ATTACH__:{json}`
/// sentinel -- reactions / typing / edits / receipts are ALSO encoded as small
/// single-line sentinels that survive the plaintext transport and are trivial
/// to fold into UI state on the receiving side:
///
///   __REACT__:{"target_id":"m-123","emoji":"❤️","action":"add","sender":"chef"}
///   __TYPING__:{"state":"start"}
///   __EDIT__:{"target_id":"m-123","body":"new text"}
///   __RECEIPT__:{"target_id":"m-123","kind":"read","sender":"lumina"}
///
/// `displayTextFor` drops every prefix so none render as chat text.

/// A reaction event: add or remove an emoji on a target message.
class ReactionSignal {
  const ReactionSignal({
    required this.targetId,
    required this.emoji,
    this.action = 'add',
    this.sender,
  });

  /// Id of the message being reacted to.
  final String targetId;

  /// The reaction emoji (e.g. heart).
  final String emoji;

  /// 'add' | 'remove'.
  final String action;

  /// Who reacted (wire identity). Null for legacy senders; folds as '?'.
  final String? sender;

  bool get isAdd => action != 'remove';

  /// Sentinel prefix that marks a message body as a reaction signal.
  static const String prefix = '__REACT__:';

  /// Encode as the single-line message body to send over the transport.
  String encode() => '$prefix${jsonEncode({
        'target_id': targetId,
        'emoji': emoji,
        'action': action,
        if (sender != null) 'sender': sender,
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
        sender: decoded['sender'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// An ephemeral typing signal: the sender started or stopped composing.
///
/// Never persisted and never rendered -- it only drives the "is composing"
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

/// An edit of a previously-sent message: replaces the target's body and marks
/// it edited. Folded into the target message (sets body + `edited_at`).
class EditSignal {
  const EditSignal({required this.targetId, required this.body});

  final String targetId;
  final String body;

  static const String prefix = '__EDIT__:';

  String encode() => '$prefix${jsonEncode({
        'target_id': targetId,
        'body': body,
      })}';

  static EditSignal? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (!trimmed.startsWith(prefix)) return null;
    try {
      final decoded = jsonDecode(trimmed.substring(prefix.length));
      if (decoded is! Map) return null;
      final targetId = decoded['target_id'] as String? ?? '';
      if (targetId.isEmpty) return null;
      return EditSignal(
        targetId: targetId,
        body: decoded['body'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// A delivery/read receipt for a target message.
class ReceiptSignal {
  const ReceiptSignal({
    required this.targetId,
    required this.kind,
    this.sender,
  });

  final String targetId;

  /// 'delivered' | 'read'.
  final String kind;
  final String? sender;

  static const String prefix = '__RECEIPT__:';

  String encode() => '$prefix${jsonEncode({
        'target_id': targetId,
        'kind': kind,
        if (sender != null) 'sender': sender,
      })}';

  static ReceiptSignal? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (!trimmed.startsWith(prefix)) return null;
    try {
      final decoded = jsonDecode(trimmed.substring(prefix.length));
      if (decoded is! Map) return null;
      final targetId = decoded['target_id'] as String? ?? '';
      final kind = decoded['kind'] as String? ?? '';
      if (targetId.isEmpty || (kind != 'delivered' && kind != 'read')) {
        return null;
      }
      return ReceiptSignal(
        targetId: targetId,
        kind: kind,
        sender: decoded['sender'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
