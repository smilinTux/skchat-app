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

  // Detect a serialized envelope: a JSON object that carries routing fields.
  // Cheap pre-check before attempting a full parse.
  final looksLikeEnvelope = trimmed.startsWith("{") &&
      trimmed.contains("\"sender\"") &&
      trimmed.contains("\"recipient\"");
  if (looksLikeEnvelope) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map && decoded.containsKey("sender") &&
          decoded.containsKey("recipient")) {
        final inner = decoded["content"];
        // Recursively resolve the inner content (it may itself be empty or a
        // nested context message).
        return displayTextFor(inner is String ? inner : null);
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
