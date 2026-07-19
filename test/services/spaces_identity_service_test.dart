import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/spaces_identity_service.dart";

/// In-memory [SpacesIdentityStorage] fake. A fresh instance models a fresh
/// install/browser profile (empty backing store); reusing the SAME instance
/// across calls models the SAME device's persisted storage surviving a
/// reload (which is exactly how `flutter_secure_storage`'s web backend
/// behaves: it writes through to `window.localStorage`, which outlives the
/// Dart isolate that a page reload tears down).
class FakeSpacesIdentityStorage implements SpacesIdentityStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }
}

void main() {
  group("SpacesIdentityService.ensure", () {
    test("generates a non-empty id and a Guest- alias on first use", () async {
      final svc = SpacesIdentityService(FakeSpacesIdentityStorage());
      final identity = await svc.ensure();

      expect(identity.id, isNotEmpty);
      // 16 random bytes, hex-encoded.
      expect(identity.id, hasLength(32));
      expect(RegExp(r"^[0-9a-f]{32}$").hasMatch(identity.id), isTrue);
      expect(identity.displayName, startsWith("Guest-"));
      expect(identity.displayName, isNot("Sovereign Node"));
    });

    test("two fresh installs (two separate stores) get different ids",
        () async {
      final a = await SpacesIdentityService(FakeSpacesIdentityStorage())
          .ensure();
      final b = await SpacesIdentityService(FakeSpacesIdentityStorage())
          .ensure();

      expect(a.id, isNot(equals(b.id)));
    });

    test("two fresh installs also get different display-name aliases most "
        "of the time (independent random draws, not hardcoded)", () async {
      // Not a strict guarantee (both could roll the same animal+digits by
      // chance), but with 24 animals * 90 two-digit combinations the
      // collision odds are low enough that this is a meaningful smoke check
      // across a batch of draws, not a single flaky comparison.
      final names = <String>{};
      for (var i = 0; i < 20; i++) {
        final identity = await SpacesIdentityService(
          FakeSpacesIdentityStorage(),
        ).ensure();
        names.add(identity.displayName);
      }
      expect(names.length, greaterThan(1));
    });

    test("the SAME store returns the SAME id across repeated ensure() calls "
        "(stable across reloads)", () async {
      final storage = FakeSpacesIdentityStorage();
      final first = await SpacesIdentityService(storage).ensure();
      final second = await SpacesIdentityService(storage).ensure();
      final third = await SpacesIdentityService(storage).ensure();

      expect(second.id, equals(first.id));
      expect(third.id, equals(first.id));
      expect(second.displayName, equals(first.displayName));
    });

    test("a fresh SpacesIdentityService wrapping the SAME storage instance "
        "(models a page reload recreating the Dart object graph, while the "
        "browser's localStorage-backed storage survives) still returns the "
        "persisted id, not a new one", () async {
      final storage = FakeSpacesIdentityStorage();
      final beforeReload = await SpacesIdentityService(storage).ensure();

      // Simulate "reload": a brand new service instance, same storage.
      final afterReload = await SpacesIdentityService(storage).ensure();

      expect(afterReload.id, equals(beforeReload.id));
    });

    test("setDisplayName persists an explicit name across subsequent ensure()",
        () async {
      final storage = FakeSpacesIdentityStorage();
      final svc = SpacesIdentityService(storage);
      await svc.ensure();

      await svc.setDisplayName("Casey");

      final reloaded = await SpacesIdentityService(storage).ensure();
      expect(reloaded.displayName, equals("Casey"));
    });

    test("setDisplayName does not change the persisted device id", () async {
      final storage = FakeSpacesIdentityStorage();
      final svc = SpacesIdentityService(storage);
      final before = await svc.ensure();

      await svc.setDisplayName("Casey");
      final after = await SpacesIdentityService(storage).ensure();

      expect(after.id, equals(before.id));
    });

    test("blank setDisplayName is a no-op (keeps the existing name)",
        () async {
      final storage = FakeSpacesIdentityStorage();
      final svc = SpacesIdentityService(storage);
      final before = await svc.ensure();

      await svc.setDisplayName("   ");
      final after = await SpacesIdentityService(storage).ensure();

      expect(after.displayName, equals(before.displayName));
    });
  });
}
