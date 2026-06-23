import "dart:convert";

/// Pure helpers for deriving the human-displayable text of a chat message and
/// for normalizing peer identities into a single conversation key.
///
/// These are intentionally free of Flutter/Riverpod deps so they can be unit
/// tested in isolation and reused by both the conversation bubble and the
/// conversation-list preview.

/// Prefix used by skchat "context" / system messages that should never be
/// shown as ordinary chat text.
const String _kChatContextPrefix = "Chat context (recent):";

/// Prefix marking an attachment-reference message body (see [AttachmentRef]).
const String _kAttachPrefix = "__ATTACH__:";

/// Prefixes marking control-signal message bodies (see [ReactionSignal] /
/// [TypingSignal]). These are folded into UI state by the conversation layer
/// and must never render as ordinary chat text.
const String _kReactPrefix = "__REACT__:";
const String _kTypingPrefix = "__TYPING__:";
const String _kEditPrefix = "__EDIT__:";
const String _kReceiptPrefix = "__RECEIPT__:";

/// A bare UUID token (delivery receipt / message-id envelope) — never chat text.
final RegExp _kUuidOnly = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// JSON control-envelope discriminators (typing / presence / acks) that must
/// never render as chat text.
const Set<String> _kControlTypes = {
  "typing", "presence", "ack", "receipt", "delivery", "heartbeat", "read",
};

/// Returns the text that should be displayed for a raw message body, or
/// `null` when the message is **non-displayable** (empty, whitespace-only, a
/// serialized transport envelope, or an injected "Chat context" system
/// message).
///
/// Behaviour:
/// - `null` / empty / whitespace-only  -> `null`
/// - a JSON envelope (object containing `"sender"` + `"recipient"`, typically
///   also `"id"`/`"content"`) -> unwrap to its inner `content` if that inner
///   content is itself displayable, otherwise `null`
/// - a "Chat context (recent):" system message -> `null`
/// - anything else -> the trimmed original string
String? displayTextFor(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  // System "context" injection — never user-visible chat text.
  if (trimmed.startsWith(_kChatContextPrefix)) return null;

  // Reaction / typing control sentinels — handled by the conversation layer,
  // never shown as a chat bubble or list preview.
  if (trimmed.startsWith(_kReactPrefix)) return null;
  if (trimmed.startsWith(_kTypingPrefix)) return null;
  if (trimmed.startsWith(_kEditPrefix)) return null;
  if (trimmed.startsWith(_kReceiptPrefix)) return null;

  // Attachment sentinel (__ATTACH__:{json}). The conversation bubble renders a
  // file card from this; for list previews we surface a short "📎 filename"
  // line instead of the raw JSON payload.
  if (trimmed.startsWith(_kAttachPrefix)) {
    try {
      final decoded = jsonDecode(trimmed.substring(_kAttachPrefix.length));
      if (decoded is Map) {
        final name = (decoded["filename"] as String?)?.trim();
        final caption = (decoded["caption"] as String?)?.trim();
        final label = (name != null && name.isNotEmpty) ? name : "attachment";
        return (caption != null && caption.isNotEmpty)
            ? "📎 $label — $caption"
            : "📎 $label";
      }
    } catch (_) {
      // Malformed sentinel — fall through to default handling.
    }
    return "📎 attachment";
  }

  // Bare delivery-receipt / message-id token.
  if (_kUuidOnly.hasMatch(trimmed)) return null;

  // Consciousness/bridge prompt-echo leakage (passthrough-era artifacts), e.g.
  // "New message from The Strategic Architect: hi [Respond as Lumina ...]".
  if (trimmed.contains("[Respond as ")) return null;

  // Any JSON object: unwrap transport envelopes, drop control messages.
  if (trimmed.startsWith("{")) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        // Control envelopes — typing / presence / acks / heartbeats.
        final disc =
            (decoded["type"] ?? decoded["state"] ?? "").toString().toLowerCase();
        if (decoded.containsKey("state") ||
            decoded.containsKey("identity_uri") ||
            _kControlTypes.contains(disc)) {
          return null;
        }
        // Transport envelope carrying inner content -> unwrap recursively.
        if (decoded.containsKey("sender") && decoded.containsKey("recipient")) {
          final inner = decoded["content"];
          return displayTextFor(inner is String ? inner : null);
        }
        // Any other JSON object (not control, not an envelope) -> show as-is.
      }
    } catch (_) {
      // Not valid JSON after all — fall through and show the trimmed text.
    }
  }

  return trimmed;
}

/// Normalizes a peer identity (CapAuth URI, fqid, bare name, or display name)
/// into a single stable conversation key.
///
/// Examples (all map to `lumina`):
///   `Lumina`                       -> `lumina`
///   `lumina`                       -> `lumina`
///   `lumina@skworld.io`            -> `lumina`
///   `capauth:lumina@skworld.io`    -> `lumina`
///   `did:capauth:lumina@skworld.io`-> `lumina`
///
/// The key is the lowercased **local-part**: scheme prefix(es) stripped and the
/// domain (everything from `@`) dropped. Whitespace is collapsed so display
/// names like `"Lumina  "` normalize cleanly.
String normalizePeerKey(String peer) {
  var s = peer.trim();
  if (s.isEmpty) return s;

  // Strip any leading scheme prefixes, e.g. `did:capauth:` or `capauth:`.
  // We strip the part before the LAST colon that precedes the local-part.
  final atIdx = s.indexOf("@");
  final schemePart = atIdx >= 0 ? s.substring(0, atIdx) : s;
  final domainPart = atIdx >= 0 ? s.substring(atIdx) : "";
  final lastColon = schemePart.lastIndexOf(":");
  final localPart =
      lastColon >= 0 ? schemePart.substring(lastColon + 1) : schemePart;

  // Drop the domain entirely; we key on the local-part only.
  // (domainPart retained above only to make the scheme-stripping unambiguous.)
  final _ = domainPart;

  return localPart.trim().toLowerCase();
}
