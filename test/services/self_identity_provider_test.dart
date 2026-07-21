import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:skchat/services/self_identity.dart";
import "package:skchat/services/self_identity_provider.dart";
import "package:skchat/services/spaces_identity_service.dart";
import "package:skchat/features/profile/profile_screen.dart";
import "package:skchat/services/operator_session_service.dart";

/// Overrides [hasLiveSession] only; the rest of [OperatorSessionService] is
/// never exercised (no network call happens in this test) since
/// [selfIdentityProvider] only ever calls this one method on the service.
class _FakeOp extends OperatorSessionService {
  _FakeOp({required this.hasSession});

  final bool hasSession;

  @override
  bool hasLiveSession() => hasSession;
}

/// A [LocalIdentityNotifier] that returns a fixed [LocalIdentity] on build
/// and, unlike the real notifier, does NOT schedule `_fetchFromDaemon`, so
/// the operator-tier test stays network-free.
class _FakeLocal extends LocalIdentityNotifier {
  _FakeLocal(this._value);

  final LocalIdentity _value;

  @override
  LocalIdentity build() => _value;
}

/// A [SpacesIdentityNotifier] that returns a fixed [SpacesIdentity] on build
/// instead of reading/generating one from storage.
class _FakeSpaces extends SpacesIdentityNotifier {
  _FakeSpaces(this._value);

  final SpacesIdentity _value;

  @override
  Future<SpacesIdentity> build() async => _value;
}

void main() {
  test("guest device -> red, per-device id, no operator key", () async {
    final container = ProviderContainer(overrides: [
      operatorSessionServiceProvider.overrideWithValue(
        _FakeOp(hasSession: false),
      ),
      spacesIdentityProvider.overrideWith(() => _FakeSpaces(
            const SpacesIdentity(
              id: "deadbeefdeadbeefdeadbeefdeadbeef",
              displayName: "Guest-Otter42",
            ),
          )),
    ]);
    addTearDown(container.dispose);
    final me = await container.read(selfIdentityProvider.future);
    expect(me.tier, SelfTrustTier.red);
    expect(me.isOperator, isFalse);
    expect(me.fingerprint, "deadbeefdeadbeefdeadbeefdeadbeef");
    expect(me.pgpKeyId, "");
  });

  test("operator device -> green, daemon identity value unchanged", () async {
    final container = ProviderContainer(overrides: [
      operatorSessionServiceProvider.overrideWithValue(
        _FakeOp(hasSession: true),
      ),
      localIdentityProvider.overrideWith(() => _FakeLocal(
            const LocalIdentity(
              displayName: "Lumina",
              fingerprint: "AABBCCDDEEFF0011",
              pgpKeySize: 4096,
            ),
          )),
    ]);
    addTearDown(container.dispose);
    final me = await container.read(selfIdentityProvider.future);
    expect(me.tier, SelfTrustTier.green);
    expect(me.isOperator, isTrue);
    expect(me.displayName, "Lumina");
    expect(me.fingerprint, "AABBCCDDEEFF0011");
    expect(me.pgpKeyId, "EEFF0011"); // last 8 of fingerprint
    expect(me.pgpKeySize, 4096);
  });
}
