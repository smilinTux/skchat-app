import '../../services/peer_trust_store.dart';

/// Fold each group member's trust tier into ONE aggregate tier for the tile.
///
/// - Only members with a real key count (tier `red` or `amber`); a `null`
///   (still resolving, or watched-but-keyless) or `unverifiable` tier is
///   ignored, exactly like a keyless 1:1 peer shows no dot.
/// - `red` if ANY keyed member is unverified (weakest link wins).
/// - `amber` if every keyed member is verified.
/// - `null` if no member has a real key -> the tile shows no badge.
PeerTrustTier? foldGroupTier(Iterable<PeerTrustTier?> memberTiers) {
  var anyKeyed = false;
  for (final t in memberTiers) {
    if (t == PeerTrustTier.red) return PeerTrustTier.red;
    if (t == PeerTrustTier.amber) anyKeyed = true;
  }
  return anyKeyed ? PeerTrustTier.amber : null;
}
