import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:skchat/services/self_identity_provider.dart";
import "package:skchat/services/spaces_identity_service.dart";
import "package:skchat/features/profile/profile_screen.dart";
import "package:skchat/services/operator_session_service.dart";

/// Overrides [hasLiveSession] only, same pattern as
/// self_identity_provider_test.dart's fake (no network call happens here).
class _FakeOp extends OperatorSessionService {
  _FakeOp({required this.hasSession});

  final bool hasSession;

  @override
  bool hasLiveSession() => hasSession;
}

/// A [LocalIdentityNotifier] that returns a fixed [LocalIdentity] on build
/// and never schedules `_fetchFromDaemon`, keeping these tests network-free.
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

const _operatorFingerprint = "AABBCCDDEEFF0011";
const _guestId = "deadbeefdeadbeefdeadbeefdeadbeef";

/// A trivial synchronous [Provider] whose only job is to hand
/// [selfFingerprintNow] / [selfDisplayNameNow] a real [Ref] to read through,
/// the same shape of ref a production [Notifier] (e.g. `ConfNotifier`) holds.
/// Reading this provider is itself synchronous, so it captures the exact
/// "before selfIdentityProvider has resolved" window these helpers exist for.
final _fingerprintProbe = Provider<String>((ref) => selfFingerprintNow(ref));
final _displayNameProbe = Provider<String>((ref) => selfDisplayNameNow(ref));

void main() {
  group("selfFingerprintNow / selfDisplayNameNow", () {
    test(
      "OPERATOR-UNCHANGED: hasLiveSession()==true returns the daemon "
      "fingerprint (and display name) even before selfIdentityProvider has "
      "resolved",
      () {
        final container = ProviderContainer(
          overrides: [
            operatorSessionServiceProvider.overrideWithValue(
              _FakeOp(hasSession: true),
            ),
            localIdentityProvider.overrideWith(
              () => _FakeLocal(
                const LocalIdentity(
                  displayName: "Lumina",
                  fingerprint: _operatorFingerprint,
                  pgpKeySize: 4096,
                ),
              ),
            ),
            // spacesIdentityProvider is deliberately left at its real
            // (storage-backed) default: the operator branch must never touch
            // it, so if it did, this test would hang or throw in the VM
            // sandbox rather than silently passing.
          ],
        );
        addTearDown(container.dispose);

        // selfIdentityProvider has NOT been read/awaited yet: its first
        // synchronous read is AsyncLoading, exactly the cold-start window
        // these helpers exist to cover.
        expect(container.read(selfIdentityProvider).valueOrNull, isNull);

        expect(container.read(_fingerprintProbe), _operatorFingerprint);
        expect(container.read(_displayNameProbe), "Lumina");
      },
    );

    test(
      "GUEST-NO-LEAK: hasLiveSession()==false returns the guest's own "
      "per-device id (once spacesIdentityProvider has resolved), NEVER the "
      "operator's localIdentityProvider fingerprint, even while "
      "selfIdentityProvider itself is still unresolved",
      () async {
        final container = ProviderContainer(
          overrides: [
            operatorSessionServiceProvider.overrideWithValue(
              _FakeOp(hasSession: false),
            ),
            localIdentityProvider.overrideWith(
              () => _FakeLocal(
                const LocalIdentity(
                  displayName: "Lumina",
                  fingerprint: _operatorFingerprint,
                  pgpKeySize: 4096,
                ),
              ),
            ),
            spacesIdentityProvider.overrideWith(
              () => _FakeSpaces(
                const SpacesIdentity(
                  id: _guestId,
                  displayName: "Guest-Otter42",
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Resolve spacesIdentityProvider (the guest's own source) WITHOUT
        // resolving selfIdentityProvider itself, reproducing the exact
        // window Finding I-2 describes: the guest's own identity is already
        // known, but the composed selfIdentityProvider has not caught up.
        await container.read(spacesIdentityProvider.future);
        expect(container.read(selfIdentityProvider).valueOrNull, isNull);

        final fp = container.read(_fingerprintProbe);
        final name = container.read(_displayNameProbe);

        expect(fp, _guestId);
        expect(fp, isNot(_operatorFingerprint));
        expect(name, "Guest-Otter42");
        expect(name, isNot("Lumina"));
      },
    );

    test(
      "GUEST-NO-LEAK: returns empty string, never the operator's identity, "
      "when NEITHER selfIdentityProvider nor spacesIdentityProvider has "
      "resolved yet",
      () {
        final container = ProviderContainer(
          overrides: [
            operatorSessionServiceProvider.overrideWithValue(
              _FakeOp(hasSession: false),
            ),
            localIdentityProvider.overrideWith(
              () => _FakeLocal(
                const LocalIdentity(
                  displayName: "Lumina",
                  fingerprint: _operatorFingerprint,
                  pgpKeySize: 4096,
                ),
              ),
            ),
            spacesIdentityProvider.overrideWith(
              () => _FakeSpaces(
                const SpacesIdentity(
                  id: _guestId,
                  displayName: "Guest-Otter42",
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Nothing has been awaited: both providers are still AsyncLoading
        // the instant the probe reads them.
        final fp = container.read(_fingerprintProbe);
        final name = container.read(_displayNameProbe);

        expect(fp, isEmpty);
        expect(fp, isNot(_operatorFingerprint));
        expect(name, isEmpty);
        expect(name, isNot("Lumina"));
      },
    );
  });
}
