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

// ── Synchronous, operator-aware pre-resolution fallback ────────────────────
//
// [selfIdentityProvider] is async: the microsecond before it first resolves,
// a synchronous call site (a tap handler, a build method reading `.valueOrNull`)
// has nothing to read yet. The naive fix, falling back to
// `ref.read(localIdentityProvider)`, is wrong: on the hosted deployment that
// IS the operator's daemon identity, so a GUEST tapping during that cold-start
// window would derive a conf room / QR payload / call room from the
// OPERATOR's fingerprint, sometimes for the whole session (the value gets
// cached downstream, e.g. ConfArgs.identity -> ConfNotifier). These two
// helpers close that gap: same operator/guest gate as [selfIdentityProvider]
// itself, just synchronous. Operator devices are unaffected (still the daemon
// fingerprint, unchanged); guest devices fall back to their own per-device id
// (or empty), NEVER the operator's.
//
// Two entry points share one implementation via each ref type's own `read`
// method: [Ref] (provider/notifier code, e.g. a Notifier's `this.ref`) and
// [WidgetRef] (widgets/ConsumerState) do not share a common supertype in this
// Riverpod version, so there is one small overload per caller shape.

/// Best-effort self fingerprint for synchronous callbacks that may fire
/// before [selfIdentityProvider] resolves. Operator -> daemon fingerprint
/// (unchanged); guest -> own per-device id if available, else empty. NEVER
/// the operator's identity for a guest. Use from provider/notifier code that
/// holds a [Ref] (e.g. [ConfNotifier]).
String selfFingerprintNow(Ref ref) => _fingerprintNow(ref.read);

/// Same as [selfFingerprintNow], for call sites that only have a [WidgetRef]
/// (a widget's `build`, or a `ConsumerState`).
String selfFingerprintNowFromWidget(WidgetRef ref) => _fingerprintNow(ref.read);

String _fingerprintNow(R Function<R>(ProviderListenable<R> provider) read) {
  final resolved = read(selfIdentityProvider).valueOrNull;
  if (resolved != null) return resolved.fingerprint;
  if (read(operatorSessionServiceProvider).hasLiveSession()) {
    return read(localIdentityProvider).fingerprint; // operator: unchanged
  }
  return read(spacesIdentityProvider).valueOrNull?.id ?? "";
}

/// Same operator-aware fallback gate as [selfFingerprintNow], for the display
/// name. Never surfaces the operator's display name to a guest.
String selfDisplayNameNow(Ref ref) => _displayNameNow(ref.read);

/// Same as [selfDisplayNameNow], for call sites that only have a [WidgetRef].
String selfDisplayNameNowFromWidget(WidgetRef ref) =>
    _displayNameNow(ref.read);

String _displayNameNow(R Function<R>(ProviderListenable<R> provider) read) {
  final resolved = read(selfIdentityProvider).valueOrNull;
  if (resolved != null) return resolved.displayName;
  if (read(operatorSessionServiceProvider).hasLiveSession()) {
    return read(localIdentityProvider).displayName; // operator: unchanged
  }
  return read(spacesIdentityProvider).valueOrNull?.displayName ?? "";
}
