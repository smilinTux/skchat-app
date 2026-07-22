import '../../services/peer_trust_store.dart';

/// A 1:1 voice/video call is allowed only to an amber+ peer. A red peer
/// (TOFU/unverified or key-changed) must be verified first (Chef's rule).
bool canCall(PeerTrustTier tier) => tier != PeerTrustTier.red;
