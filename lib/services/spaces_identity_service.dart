/// Stable, unique-per-device identity for SK Spaces (LiveKit audio rooms).
///
/// Root cause this exists to fix: on the web app at /app/, every browser
/// shares ONE identity fetched from the local SKComms node daemon
/// (`localIdentityProvider` in profile_screen.dart), because that daemon is a
/// single sovereign node with one capauth fingerprint. Spaces used that
/// shared fingerprint as the LiveKit participant identity, so two different
/// people joining the same /app/ deployment collided on the SAME LiveKit
/// identity, LiveKit evicted the duplicate, and the host got kicked the
/// moment a second person joined.
///
/// The fix: a Spaces-scoped identity that is generated locally, on-device,
/// and has nothing to do with the shared daemon. It is persisted so the SAME
/// device keeps the SAME id across reloads (a host can rejoin as host), while
/// two different devices/browsers independently generate two different ids
/// (no collision, no eviction).
///
/// This is intentionally NOT the same identity used for chats/1:1/conf
/// ([localIdentityProvider] in profile_screen.dart, which stays wired to the
/// daemon for those features). Scope: Spaces only.
library;

import "dart:math";

import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";

const _kDeviceIdKey = "spaces_device_id";
const _kDisplayNameKey = "spaces_display_name";

/// A stable, unique-per-device Spaces identity.
@immutable
class SpacesIdentity {
  const SpacesIdentity({required this.id, required this.displayName});

  /// Locally generated, persisted-per-device unique id (32 hex chars, 16
  /// random bytes). Used directly as the LiveKit participant identity and as
  /// `host_fqid` when this device creates a Space, so the host's own
  /// participant identity always equals the `host_fqid` it minted, no
  /// suffixing needed, no self-collision.
  final String id;

  /// A friendly, distinguishing name. Defaults to a generated guest alias
  /// (`Guest-` + animal + 2 digits, matching the web space.html style) so two
  /// strangers in the same Space are visibly distinct instead of both
  /// showing as "Sovereign Node"; editable and persisted per device.
  final String displayName;

  SpacesIdentity copyWith({String? id, String? displayName}) => SpacesIdentity(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
      );
}

/// Minimal key-value persistence seam [SpacesIdentityService] depends on,
/// instead of `FlutterSecureStorage` directly, so tests can exercise the
/// generate-once/persist/reuse logic with a plain in-memory fake instead of a
/// platform channel. Production wiring uses [SecureSpacesIdentityStorage].
abstract class SpacesIdentityStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Production [SpacesIdentityStorage]: wraps `flutter_secure_storage`.
///
/// Web caveat (verified against `flutter_secure_storage_web` 1.2.1 source):
/// on web this backend persists to `window.localStorage` (AES-GCM encrypted,
/// with the WebCrypto key itself also kept in localStorage), NOT
/// sessionStorage. localStorage is scoped per browser origin and survives
/// both page reloads and full browser restarts, and is never shared across
/// different browsers/devices, which is exactly the persistence this needs:
/// stable per device, distinct across devices. (The one inherent limit is
/// private/incognito windows, which discard all storage on close, a browser
/// policy no in-app persistence choice can work around.)
class SecureSpacesIdentityStorage implements SpacesIdentityStorage {
  const SecureSpacesIdentityStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Guest alias word list + format, kept in lockstep with the web client's
/// `GUEST_ANIMALS` / `randomGuestAlias()` in
/// `skchat/src/skchat/static/space.html` so a browser guest and the app guest
/// alias style match.
const _kGuestAnimals = [
  "Falcon", "Otter", "Panda", "Lynx", "Heron", "Wolf", "Finch", "Marlin",
  "Badger", "Sparrow", "Orca", "Ibex", "Kite", "Puffin", "Raven", "Stag",
  "Tapir", "Wren", "Yak", "Zebra", "Bison", "Coyote", "Dingo", "Egret",
];

/// Generates + persists the per-device Spaces identity.
class SpacesIdentityService {
  const SpacesIdentityService(this._storage);

  final SpacesIdentityStorage _storage;

  /// Loads the persisted identity, generating + persisting one on first use.
  /// Idempotent: repeated calls against the same backing storage return the
  /// SAME id and display name (no regeneration once persisted).
  Future<SpacesIdentity> ensure() async {
    var id = await _storage.read(_kDeviceIdKey);
    if (id == null || id.isEmpty) {
      id = _generateDeviceId();
      await _storage.write(_kDeviceIdKey, id);
    }

    var name = await _storage.read(_kDisplayNameKey);
    if (name == null || name.isEmpty) {
      name = _generateGuestAlias();
      await _storage.write(_kDisplayNameKey, name);
    }

    return SpacesIdentity(id: id, displayName: name);
  }

  /// Persists an explicit user-chosen display name for this device. Future
  /// [ensure] calls (including after a reload) return this name instead of a
  /// fresh alias.
  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _storage.write(_kDisplayNameKey, trimmed);
  }

  static String _generateDeviceId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
  }

  static String _generateGuestAlias() {
    final rand = Random.secure();
    final animal = _kGuestAnimals[rand.nextInt(_kGuestAnimals.length)];
    final digits = 10 + rand.nextInt(90); // 2 digits, matches space.html
    return "Guest-$animal$digits";
  }
}

// ── Riverpod wiring ──────────────────────────────────────────────────────────

final _spacesIdentityStorageProvider = Provider<SpacesIdentityStorage>(
  (_) => const SecureSpacesIdentityStorage(
    FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  ),
);

final spacesIdentityServiceProvider = Provider<SpacesIdentityService>(
  (ref) => SpacesIdentityService(ref.watch(_spacesIdentityStorageProvider)),
);

/// Loads (generating + persisting on first use) this device's Spaces
/// identity. `AsyncNotifier` so `setDisplayName` can update the cached state
/// in place once the user edits their alias, without re-reading storage.
class SpacesIdentityNotifier extends AsyncNotifier<SpacesIdentity> {
  @override
  Future<SpacesIdentity> build() =>
      ref.read(spacesIdentityServiceProvider).ensure();

  /// Persist + apply an explicit display-name edit.
  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await ref.read(spacesIdentityServiceProvider).setDisplayName(trimmed);
    final current = state.valueOrNull;
    state = AsyncData(
      (current ?? SpacesIdentity(id: "", displayName: trimmed))
          .copyWith(displayName: trimmed),
    );
  }
}

final spacesIdentityProvider =
    AsyncNotifierProvider<SpacesIdentityNotifier, SpacesIdentity>(
  SpacesIdentityNotifier.new,
);
