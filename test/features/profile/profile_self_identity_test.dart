import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/profile/profile_screen.dart";
import "package:skchat/services/capabilities_service.dart";
import "package:skchat/services/self_identity.dart";
import "package:skchat/services/self_identity_provider.dart";
import "package:skchat/services/skcomms_client.dart";
import "package:skchat/services/skcomms_sync.dart";

class MockSKCommsClient extends Mock implements SKCommsClient {}

/// A no-op sync notifier that skips timer creation / polling (mirrors the
/// pattern in test/widget_test.dart) so this widget test never touches the
/// network.
class _NoOpSyncNotifier extends SKCommsSyncNotifier {
  @override
  DaemonState build() => const DaemonState(status: DaemonStatus.offline);
}

/// Fixed identities used across the three scenarios. The operator (green)
/// fingerprint and the guest (red) fingerprint are deliberately different so
/// "the operator fingerprint is NOT shown to a guest" can be asserted by
/// absence of the operator's formatted fingerprint text.
const _operatorIdentity = SelfIdentity(
  displayName: "Lumina",
  id: "AABBCCDDEEFF00112233",
  fingerprint: "AABBCCDDEEFF00112233",
  tier: SelfTrustTier.green,
  isOperator: true,
  pgpKeyId: "00112233",
  pgpKeySize: 4096,
);

const _guestIdentity = SelfIdentity(
  displayName: "Guest-Otter42",
  id: "deadbeefdeadbeefdeadbeef",
  fingerprint: "deadbeefdeadbeefdeadbeef",
  tier: SelfTrustTier.red,
  isOperator: false,
);

const _degradedGuestIdentity = SelfIdentity(
  displayName: "Guest-Otter42",
  id: "deadbeefdeadbeefdeadbeef",
  fingerprint: "deadbeefdeadbeefdeadbeef",
  tier: SelfTrustTier.red,
  isOperator: false,
  degraded: true,
);

/// "AABBCCDDEEFF00112233" grouped in 4s and uppercased, the same formatting
/// `_IdentityHeader._formatFingerprint` applies.
const _operatorFingerprintFormatted = "AABB CCDD EEFF 0011 2233";

Widget _wrap(SelfIdentity me, MockSKCommsClient client) {
  return ProviderScope(
    overrides: [
      selfIdentityProvider.overrideWith((ref) async => me),
      skcommsClientProvider.overrideWithValue(client),
      skcommsSyncProvider.overrideWith(() => _NoOpSyncNotifier()),
      nodeCapabilitiesProvider.overrideWith((ref) async => null),
    ],
    child: const MaterialApp(home: ProfileScreen()),
  );
}

void main() {
  setUpAll(() {
    // daemonUrlProvider / backendConfigProvider open Hive boxes on first
    // build; seed a throwaway temp dir (same fix as test/widget_test.dart).
    Hive.init(Directory.systemTemp.createTempSync("skchat_test_hive").path);
  });

  late MockSKCommsClient client;

  setUp(() {
    client = MockSKCommsClient();
    when(() => client.isAlive()).thenAnswer((_) async => false);
  });

  testWidgets("red guest: Untrusted shown, operator identity hidden",
      (tester) async {
    await tester.pumpWidget(_wrap(_guestIdentity, client));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text("Untrusted"), findsOneWidget);
    expect(
      find.text("Self-asserted identity, not sovereign-verified"),
      findsOneWidget,
    );
    expect(find.text(_operatorFingerprintFormatted), findsNothing);
    expect(find.text("PGP Key"), findsNothing);
    expect(find.text("Sovereign"), findsNothing);
  });

  testWidgets("green operator: Sovereign shown, real fingerprint + PGP Key",
      (tester) async {
    await tester.pumpWidget(_wrap(_operatorIdentity, client));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text("Sovereign"), findsOneWidget);
    expect(find.text("Full trust, self-sovereign"), findsOneWidget);
    expect(find.text(_operatorFingerprintFormatted), findsOneWidget);
    expect(find.text("PGP Key"), findsOneWidget);
    expect(find.text("Untrusted"), findsNothing);
  });

  testWidgets("red + degraded: shows the will-not-survive-reload warning",
      (tester) async {
    await tester.pumpWidget(_wrap(_degradedGuestIdentity, client));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      find.textContaining("will not survive a reload"),
      findsOneWidget,
    );
  });
}
