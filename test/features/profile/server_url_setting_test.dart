// Widget tests for the discoverable "Server URL" setting on the Me/Profile
// screen. This is a more prominent, always-visible entry point to the same
// daemonUrlProvider / backendConfigProvider apply the buried instance-picker
// "Custom host" field already performs; it must not replace that picker.
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/profile/profile_screen.dart";
import "package:skchat/services/backend_config.dart";
import "package:skchat/services/capabilities_service.dart";
import "package:skchat/services/daemon_config.dart";
import "package:skchat/services/self_identity.dart";
import "package:skchat/services/self_identity_provider.dart";
import "package:skchat/services/skcomms_client.dart";
import "package:skchat/services/skcomms_sync.dart";

class MockSKCommsClient extends Mock implements SKCommsClient {}

/// No-op sync notifier, mirrors test/widget_test.dart / profile_self_identity
/// test: skips timer creation / polling so this never touches the network.
class _NoOpSyncNotifier extends SKCommsSyncNotifier {
  @override
  DaemonState build() => const DaemonState(status: DaemonStatus.offline);
}

const _guestIdentity = SelfIdentity(
  displayName: "Guest-Otter42",
  id: "deadbeefdeadbeefdeadbeef",
  fingerprint: "deadbeefdeadbeefdeadbeef",
  tier: SelfTrustTier.red,
  isOperator: false,
);

List<Override> _baseOverrides(MockSKCommsClient client) => [
      selfIdentityProvider.overrideWith((ref) async => _guestIdentity),
      skcommsClientProvider.overrideWithValue(client),
      skcommsSyncProvider.overrideWith(() => _NoOpSyncNotifier()),
      nodeCapabilitiesProvider.overrideWith((ref) async => null),
    ];

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

  // The "Server URL" row lives near the bottom of the Me screen's ListView,
  // below the default 800x600 test surface. Enlarge the surface so the whole
  // screen lays out without needing to scroll (simpler + less flaky than
  // driving the Scrollable by hand).
  Future<void> _growSurface(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets("Server URL row renders the current daemon URL",
      (tester) async {
    await _growSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _baseOverrides(client),
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text("Server URL"), findsOneWidget);
    // The row's subtitle mirrors whatever daemonUrlProvider currently holds.
    expect(find.text(kDefaultDaemonUrl), findsWidgets);
  });

  testWidgets(
      "editing + saving the Server URL updates daemonUrlProvider and "
      "backendConfigProvider", (tester) async {
    const newUrl = "https://newhost.tail204f0c.ts.net";
    late ProviderContainer container;

    await _growSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _baseOverrides(client),
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(home: ProfileScreen());
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    await tester.tap(find.text("Server URL"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The dialog's TextField is pre-filled with the current URL.
    final field = find.byKey(const Key("server-url-field"));
    expect(field, findsOneWidget);
    await tester.enterText(field, newUrl);
    await tester.tap(find.widgetWithText(FilledButton, "Save"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(daemonUrlProvider), newUrl);
    expect(container.read(backendConfigProvider).skchatWebuiUrl, newUrl);
  });

  testWidgets("saving an empty/whitespace field is a no-op", (tester) async {
    late ProviderContainer container;

    await _growSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _baseOverrides(client),
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(home: ProfileScreen());
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    final before = container.read(daemonUrlProvider);

    await tester.tap(find.text("Server URL"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const Key("server-url-field")), "   ");
    await tester.tap(find.widgetWithText(FilledButton, "Save"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(daemonUrlProvider), before);
  });
}
