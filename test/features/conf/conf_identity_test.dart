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
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/conf/conf_screen.dart";
import "package:skchat/services/conf_service.dart";
import "package:skchat/services/self_identity.dart";
import "package:skchat/services/self_identity_provider.dart";

class MockConfService extends Mock implements ConfService {}

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
}
