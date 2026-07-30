/// Pure trust view-model for a conversation row (reconciled spec 3.2).
///
/// This is the LAST deferred ChatsScreen-parity piece: the per-conversation
/// trust badge. The real trust standing lives app-side in `peer_trust_store`
/// (Riverpod + Hive TOFU) and `group_trust` (the aggregate fold), which cannot
/// cross the import gate into this pure package. So the package defines only a
/// tiny, dependency-free view of what the tile needs to RENDER, and the app
/// injects it (see [ConversationTrustResolver] on `ChatsSurface`). Absent trust
/// data means no badge, so a standalone / unwired mount still renders cleanly.
library;

/// The trust tier the tile renders, mapped by the app from its own
/// `PeerTrustTier`. `red` = a real key exists but is not yet verified
/// (untrusted / TOFU), `amber` = verified peer (provisional), `green` =
/// sovereign (self / operator). A peer with no real key resolves to no
/// [PeerTrust] at all, so it shows no badge.
enum PeerTrustLevel { red, amber, green }

/// What a conversation row needs to render a trust badge, and nothing more.
///
/// Injected from the app via a [ConversationTrustResolver]; the package never
/// reaches into the trust store itself. A null [PeerTrust] for a conversation
/// (resolver returns null, or no resolver at all) renders no badge.
class PeerTrust {
  const PeerTrust({required this.level, this.label});

  /// The tier that selects the badge color.
  final PeerTrustLevel level;

  /// Optional override for the badge's screen-reader / expanded label. Null
  /// uses the tier's default label.
  final String? label;
}
