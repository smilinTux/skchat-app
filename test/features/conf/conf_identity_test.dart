// Task 7 regression: the effective conf/LiveKit identity ConfNotifier resolves
// via ConfNotifier._identity must come from selfIdentityProvider, not the
// shared daemon localIdentityProvider. An operator device must still resolve
// to the daemon fingerprint (byte-for-byte unchanged); a guest device must
// resolve to its OWN per-device fingerprint, never the operator's.
//
// Drives this through the public surface (ConfNotifier.connect(), which calls
// the private _identity getter internally) rather than reaching for the
// private getter directly, since Dart privacy is per-file and this test lives
// in a different library than conf_screen.dart.
import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/conf/conf_screen.dart";
import "package:skchat/services/conf_service.dart";
import "package:skchat/services/operator_session_service.dart";
import "package:skchat/services/self_identity.dart";
import "package:skchat/services/self_identity_provider.dart";
import "package:skchat/services/spaces_identity_service.dart";

class MockConfService extends Mock implements ConfService {}

/// Stands in for [OperatorSessionService] so the pre-resolution fallback
/// (`selfFingerprintNow`, hit while [selfIdentityProvider] is still loading)
/// reads a deterministic `hasLiveSession()` instead of the real, Hive-backed
/// service.
class _FakeOp extends OperatorSessionService {
  _FakeOp({required this.hasSession});

  final bool hasSession;

  @override
  bool hasLiveSession() => hasSession;
}

/// A deterministic stand-in for the guest's own per-device identity source,
/// used to prove the pre-resolution fallback path resolves to THIS, not the
/// shared daemon identity (Finding I-2: falling back to the daemon identity
/// for a guest, even transiently, leaks the operator's fingerprint).
class _StubSpaces extends SpacesIdentityNotifier {
  _StubSpaces(this._value);

  final SpacesIdentity _value;

  @override
  Future<SpacesIdentity> build() async => _value;
}

const _operatorIdentity = SelfIdentity(
  displayName: "Lumina",
  id: "F0F0F0F0F0F0F0F0",
  fingerprint: "F0F0F0F0F0F0F0F0",
  tier: SelfTrustTier.green,
  isOperator: true,
  pgpKeyId: "F0F0F0F0",
  pgpKeySize: 4096,
);

const _guestIdentity = SelfIdentity(
  displayName: "Guest-Otter42",
  id: "G1G1G1G1G1G1G1G1",
  fingerprint: "G1G1G1G1G1G1G1G1",
  tier: SelfTrustTier.red,
  isOperator: false,
);

void main() {
  late MockConfService conf;

  setUp(() {
    conf = MockConfService();
    when(() => conf.enterWaiting(any(),
            identity: any(named: "identity"), display: any(named: "display")))
        .thenAnswer((_) async => const WaitingStatus(
              admitted: false,
              position: 1,
              message: "Waiting for host to admit you",
            ));
  });

  // A bare-room guest join (no identity carried in ConfArgs, the same shape a
  // deep link like /conf?room=... produces) forces ConfNotifier down the
  // "resolve my own identity" branch instead of trusting a caller-supplied one.
  const bareArgs = ConfArgs(identity: "", room: "conf-1", role: "guest");

  Future<String> effectiveIdentity(SelfIdentity me) async {
    final container = ProviderContainer(overrides: [
      confServiceProvider.overrideWithValue(conf),
      selfIdentityProvider.overrideWith((ref) async => me),
    ]);
    addTearDown(container.dispose);

    // Resolve the async self identity BEFORE calling connect(), so the
    // notifier's synchronous _identity getter sees resolved data rather than
    // racing the FutureProvider's first microtask (see Task 7 brief: a
    // not-yet-resolved read is expected to fall back, but this test wants to
    // pin the RESOLVED value).
    await container.read(selfIdentityProvider.future);

    await container.read(confProvider(bareArgs).notifier).connect();

    final captured = verify(() => conf.enterWaiting(any(),
            identity: captureAny(named: "identity"),
            display: any(named: "display")))
        .captured;
    return captured.single as String;
  }

  test("operator device: effective conf identity equals the daemon "
      "fingerprint F (unchanged)", () async {
    final identity = await effectiveIdentity(_operatorIdentity);
    expect(identity, _operatorIdentity.fingerprint);
  });

  test("guest device: effective conf identity equals the per-device "
      "fingerprint G, never the operator's", () async {
    final identity = await effectiveIdentity(_guestIdentity);
    expect(identity, _guestIdentity.fingerprint);
    expect(identity, isNot(_operatorIdentity.fingerprint));
  });

  // Regression for Finding I-2: _identity must not permanently pin the
  // pre-resolution fallback, AND that fallback must be operator-aware (never
  // the shared daemon identity for a GUEST, even for one call). If _identity
  // is first read while selfIdentityProvider is still loading (AsyncLoading,
  // .valueOrNull == null), a guest device must fall back to ITS OWN
  // per-device identity (via selfFingerprintNow -> spacesIdentityProvider)
  // for that call only, and must not cache it; once selfIdentityProvider
  // resolves, a later access must recompute and pick up the guest's real
  // resolved fingerprint G, never staying pinned to the fallback for the
  // whole conf session.
  test(
      "does not permanently cache the pre-resolution fallback, and that "
      "fallback is the guest's own identity, never the operator's", () async {
    final selfCompleter = Completer<SelfIdentity>();
    const preResolutionFallback = SpacesIdentity(
      id: "S3S3S3S3S3S3S3S3",
      displayName: "Spaces-Fallback",
    );
    final container = ProviderContainer(overrides: [
      confServiceProvider.overrideWithValue(conf),
      // Stays unresolved (AsyncLoading, valueOrNull == null) until we
      // complete it below, reproducing the race from the finding.
      selfIdentityProvider.overrideWith((ref) => selfCompleter.future),
      // No live operator session: the pre-resolution fallback must resolve
      // through the guest's own spacesIdentityProvider, NOT localIdentityProvider.
      operatorSessionServiceProvider.overrideWithValue(
        _FakeOp(hasSession: false),
      ),
      spacesIdentityProvider.overrideWith(
        () => _StubSpaces(preResolutionFallback),
      ),
    ]);
    addTearDown(container.dispose);

    // Keep the family notifier alive across both connect() calls, mirroring
    // a real conf session where ConfScreen keeps confProvider watched for
    // the lifetime of the call rather than a fresh notifier per access.
    final sub = container.listen(confProvider(bareArgs), (_, __) {});
    addTearDown(sub.close);
    final notifier = container.read(confProvider(bareArgs).notifier);

    // Let the guest's OWN identity source resolve (but NOT selfIdentityProvider
    // itself, which stays pending on selfCompleter), so the very first
    // _identity access below exercises a deterministic pre-resolution
    // fallback instead of racing spacesIdentityProvider's own first microtask.
    await container.read(spacesIdentityProvider.future);

    // First access: selfIdentityProvider has not resolved yet, so _identity
    // must fall back to the GUEST's own per-device identity for this call
    // only (never the operator/daemon identity), and must not crash or
    // return null (still a plain, non-empty String).
    await notifier.connect();

    // Now let selfIdentityProvider resolve to the guest's own identity.
    selfCompleter.complete(_guestIdentity);
    await container.read(selfIdentityProvider.future);

    // Second access: selfIdentityProvider is resolved now. If the fallback
    // had been wrongly cached, this would still return the pinned fallback
    // instead of recomputing.
    await notifier.connect();

    final captured = verify(() => conf.enterWaiting(any(),
            identity: captureAny(named: "identity"),
            display: any(named: "display")))
        .captured;
    expect(captured, hasLength(2));
    final firstAccess = captured[0] as String;
    final secondAccess = captured[1] as String;

    expect(firstAccess, isNotEmpty);
    // The pre-resolution fallback: the guest's OWN per-device id, never the
    // operator's identity and never a hardcoded/shared daemon value.
    expect(firstAccess, preResolutionFallback.id);
    expect(firstAccess, isNot(_operatorIdentity.fingerprint));
    expect(firstAccess, isNot(_guestIdentity.fingerprint));
    expect(secondAccess, _guestIdentity.fingerprint);
    expect(secondAccess, isNot(firstAccess));
  });
}
