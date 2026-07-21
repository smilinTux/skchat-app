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
import "package:skchat/features/profile/profile_screen.dart"
    show LocalIdentity, LocalIdentityNotifier, localIdentityProvider;
import "package:skchat/services/conf_service.dart";
import "package:skchat/services/self_identity.dart";
import "package:skchat/services/self_identity_provider.dart";

class MockConfService extends Mock implements ConfService {}

// A deterministic stand-in for the shared daemon identity, replacing
// LocalIdentityNotifier's real build() (which kicks off a network fetch via
// skcommsClientProvider, unrelated infra this test has no need to exercise)
// with a fixed value so the pre-resolution fallback path is deterministic.
class _StubLocalIdentityNotifier extends LocalIdentityNotifier {
  @override
  LocalIdentity build() => const LocalIdentity(
        displayName: "Daemon-Fallback",
        fingerprint: "D0D0D0D0D0D0D0D0",
      );
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

  // Regression for the review finding: _identity must not permanently pin
  // the pre-resolution fallback. If _identity is first read while
  // selfIdentityProvider is still loading (AsyncLoading, .valueOrNull ==
  // null), it must return the shared-daemon fallback for THAT call only and
  // must not cache it; once selfIdentityProvider resolves, a later access
  // must recompute and pick up the guest's own per-device fingerprint G,
  // never staying pinned to the fallback for the whole conf session.
  test(
      "does not permanently cache the pre-resolution fallback: a later "
      "access after selfIdentityProvider resolves returns the resolved "
      "guest fingerprint G, not the pinned fallback", () async {
    final selfCompleter = Completer<SelfIdentity>();
    final container = ProviderContainer(overrides: [
      confServiceProvider.overrideWithValue(conf),
      // Stays unresolved (AsyncLoading, valueOrNull == null) until we
      // complete it below, reproducing the race from the finding.
      selfIdentityProvider.overrideWith((ref) => selfCompleter.future),
      localIdentityProvider.overrideWith(_StubLocalIdentityNotifier.new),
    ]);
    addTearDown(container.dispose);

    // Keep the family notifier alive across both connect() calls, mirroring
    // a real conf session where ConfScreen keeps confProvider watched for
    // the lifetime of the call rather than a fresh notifier per access.
    final sub = container.listen(confProvider(bareArgs), (_, __) {});
    addTearDown(sub.close);
    final notifier = container.read(confProvider(bareArgs).notifier);

    // First access: selfIdentityProvider has not resolved yet, so _identity
    // must fall back to the shared daemon identity for this call only, and
    // must not crash or return null (still a plain, non-empty String).
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
    expect(firstAccess, "D0D0D0D0D0D0D0D0"); // the shared daemon fallback
    expect(firstAccess, isNot(_guestIdentity.fingerprint));
    expect(secondAccess, _guestIdentity.fingerprint);
    expect(secondAccess, isNot(firstAccess));
  });
}
