import '../../services/peer_trust_store.dart';

/// A 1:1 voice/video call is blocked only for a red peer (TOFU/unverified
/// or a rotated, previously-verified key) that must be verified first
/// (Chef's rule). Amber (verified) and unverifiable (no real capauth key to
/// anchor trust to, so there is nothing to rotate/spoof) peers may call.
bool canCall(PeerTrustTier tier) => tier != PeerTrustTier.red;
