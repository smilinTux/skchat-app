import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/livekit_call_screen.dart';
import 'package:skchat/services/livekit_call_service.dart';

/// A notifier that exposes a fixed [LiveKitCallState] without touching a live
/// LiveKit Room — lets us verify the multi-party grid + screenshare control
/// render. (WebRTC media itself cannot run headless; this asserts the UI shape
/// around it.)
class _FixedCallNotifier extends LiveKitCallNotifier {
  _FixedCallNotifier(this._fixed);
  final LiveKitCallState _fixed;

  @override
  LiveKitCallState? build() => _fixed;

  // The screen calls join() in a post-frame callback; no-op so the test never
  // touches a live LiveKit service (which would pull Hive-backed config).
  @override
  Future<void> join({
    required String roomName,
    required String identity,
    bool withVideo = false,
  }) async {}

  @override
  Future<void> joinWithToken({
    required String roomName,
    required String identity,
    required String wsUrl,
    required String token,
    bool withVideo = false,
  }) async {}
}

LiveKitCallState _state({
  required int participants,
  bool screenSharing = false,
}) {
  return LiveKitCallState(
    roomName: 'gcall-test',
    identity: 'chef@skworld.io',
    participants: List.generate(
      participants,
      (i) => LiveKitParticipantSnapshot(
        identity: i == 0 ? 'chef@skworld.io' : 'member$i',
        isLocal: i == 0,
        isMuted: false,
        isCameraEnabled: false,
        isSpeaking: i == 1, // second tile is the active speaker
      ),
    ),
    isMicEnabled: true,
    isCameraEnabled: false,
    isConnected: true,
    isScreenSharing: screenSharing,
  );
}

Widget _harness(LiveKitCallState state) {
  return ProviderScope(
    overrides: [
      liveKitCallProvider.overrideWith(() => _FixedCallNotifier(state)),
      // Override the service so the grid's `ref.read(...).room` does not pull
      // the Hive-backed backendConfig provider (unavailable in unit tests).
      liveKitCallServiceProvider.overrideWith(
        (ref) => LiveKitCallService(
          webuiBaseUrl: 'https://test.local',
          livekitUrl: 'wss://test.local',
        ),
      ),
    ],
    child: const MaterialApp(
      home: LiveKitCallScreen(
        args: LiveKitCallArgs(
          roomName: 'gcall-test',
          identity: 'chef@skworld.io',
          displayName: 'Squad',
          withVideo: true,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('group call screen renders the screenshare toggle', (t) async {
    await t.pumpWidget(_harness(_state(participants: 3)));
    await t.pump();
    // The screenshare control is present (label "Share" when not sharing).
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Mute'), findsOneWidget);
    expect(find.text('Leave'), findsOneWidget);
  });

  testWidgets('screenshare toggle shows "Stop share" while sharing', (t) async {
    await t.pumpWidget(_harness(_state(participants: 2, screenSharing: true)));
    await t.pump();
    expect(find.text('Stop share'), findsOneWidget);
    expect(find.byIcon(Icons.stop_screen_share_rounded), findsOneWidget);
  });

  testWidgets('multi-party grid renders all participant tiles', (t) async {
    await t.pumpWidget(_harness(_state(participants: 4)));
    await t.pump();
    // Each tile shows its identity label; the local one is suffixed "(you)".
    expect(find.text('chef@skworld.io (you)'), findsOneWidget);
    expect(find.text('member1'), findsOneWidget);
    expect(find.text('member3'), findsOneWidget);
    // Top bar reflects the participant count.
    expect(find.textContaining('4 participants'), findsOneWidget);
  });
}
