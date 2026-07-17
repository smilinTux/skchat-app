// Z1: the Spaces tools sheet "Screen share" tile opens ScreenSharePanel,
// whose "Share my screen" button starts a LiveKit screen share. On mobile
// web that origination is impossible (no getDisplayMedia), so the button
// must detect it via isMobileWebProvider and short-circuit to the friendly
// message BEFORE ever calling setScreenShareEnabled, instead of letting
// livekit_client's own lkPlatformIsWebMobile() guard throw a raw exception.
// Desktop / native and the remote-share rendering above stay unchanged.
import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/features/call_shared/screen_share_source.dart";
import "package:skchat/features/spaces/screen_share_panel.dart";
import "package:skchat/services/livekit_call_service.dart";

class MockLiveKitCallService extends Mock implements LiveKitCallService {}

void main() {
  late MockLiveKitCallService svc;

  setUp(() {
    svc = MockLiveKitCallService();
    // The panel reads participants (stream + snapshot) and room to render
    // remote shares; keep them empty so it shows the "no one is sharing"
    // placeholder. No remote shares means room can be null.
    when(() => svc.participants)
        .thenAnswer((_) => const Stream<List<LiveKitParticipantSnapshot>>.empty());
    when(() => svc.currentParticipants)
        .thenReturn(const <LiveKitParticipantSnapshot>[]);
    when(() => svc.room).thenReturn(null);
    when(() => svc.setScreenShareEnabled(any(),
        systemAudioDeviceId: any(named: "systemAudioDeviceId"),
        sourceId: any(named: "sourceId"))).thenAnswer((_) async {});
  });

  Widget wrap({List<Override> extraOverrides = const []}) {
    return ProviderScope(
      overrides: [
        liveKitCallServiceProvider.overrideWithValue(svc),
        ...extraOverrides,
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: ScreenSharePanel(spaceId: "s1", identity: "chef@dk.skworld"),
        ),
      ),
    );
  }

  testWidgets(
      "on mobile web, tapping Share my screen shows the friendly message and "
      "never calls setScreenShareEnabled or the source resolver",
      (tester) async {
    var resolverCalls = 0;
    Future<({bool proceed, String? sourceId})> fakeResolver(
        BuildContext context) async {
      resolverCalls++;
      return (proceed: true, sourceId: null);
    }

    await tester.pumpWidget(wrap(extraOverrides: [
      isMobileWebProvider.overrideWithValue(true),
      screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text("Share my screen"));
    await tester.pump(const Duration(milliseconds: 50));

    expect(resolverCalls, 0);
    verifyNever(() => svc.setScreenShareEnabled(any(),
        systemAudioDeviceId: any(named: "systemAudioDeviceId"),
        sourceId: any(named: "sourceId")));
    expect(
      find.textContaining("Screen sharing needs the desktop app"),
      findsOneWidget,
    );
    expect(find.textContaining("Screen share failed"), findsNothing);
    expect(find.textContaining("LiveKit"), findsNothing);
    // Button stays "Share my screen", never flips to the sharing state.
    expect(find.text("Share my screen"), findsOneWidget);
    expect(find.text("Stop sharing"), findsNothing);
  });

  testWidgets(
      "on desktop (isMobileWebProvider false), Share my screen resolves the "
      "source and starts the share as before", (tester) async {
    Future<({bool proceed, String? sourceId})> fakeResolver(
            BuildContext context) async =>
        (proceed: true, sourceId: "screen:3");

    await tester.pumpWidget(wrap(extraOverrides: [
      isMobileWebProvider.overrideWithValue(false),
      screenShareSourceResolverProvider.overrideWithValue(fakeResolver),
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text("Share my screen"));
    await tester.pump(const Duration(milliseconds: 50));

    verify(() => svc.setScreenShareEnabled(true,
        systemAudioDeviceId: any(named: "systemAudioDeviceId"),
        sourceId: "screen:3")).called(1);
    expect(
      find.textContaining("Screen sharing needs the desktop app"),
      findsNothing,
    );
  });
}
