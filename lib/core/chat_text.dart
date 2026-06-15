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
