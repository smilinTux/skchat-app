import "package:flutter_riverpod/flutter_riverpod.dart";

import "../features/profile/profile_screen.dart" show localIdentityProvider;
import "operator_session_service.dart";
import "self_identity.dart";
import "spaces_identity_service.dart";

/// The unified "who am I" for THIS device.
///
/// Operator (green): this device holds a live enrolled operator session, so
/// we surface the sovereign daemon identity exactly as before. Everyone else
/// (red): their own per-device identity, never the operator's. This is what
/// stops a guest from being shown the operator's fingerprint / PGP / trust.
final selfIdentityProvider = FutureProvider<SelfIdentity>((ref) async {
  final isOperator =
      ref.watch(operatorSessionServiceProvider).hasLiveSession();
  if (isOperator) {
    final d = ref.watch(localIdentityProvider);
    final pgpId = d.fingerprint.length >= 8
        ? d.fingerprint.substring(d.fingerprint.length - 8)
        : d.fingerprint;
    return SelfIdentity.operator__(
      displayName: d.displayName,
      fingerprint: d.fingerprint,
      pgpKeyId: pgpId,
      pgpKeySize: d.pgpKeySize,
    );
  }
  final sp = await ref.watch(spacesIdentityProvider.future);
  return SelfIdentity.guest(
    displayName: sp.displayName,
    fingerprint: sp.id,
    degraded: sp.degraded,
  );
});
