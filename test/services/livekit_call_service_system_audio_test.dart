import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/livekit_call_service.dart';

void main() {
  test('isSharingSystemAudio is false before any share', () {
    final svc = LiveKitCallService();
    expect(svc.isSharingSystemAudio, isFalse);
  });

  test('stopScreenShareSystemAudio is a safe no-op when nothing is shared', () async {
    final svc = LiveKitCallService();
    await svc.stopScreenShareSystemAudio();
    expect(svc.isSharingSystemAudio, isFalse);
  });

  test('start with no local participant does not throw and stays not-sharing',
      () async {
    final svc = LiveKitCallService();
    // No room joined, so _localParticipant is null: the method must guard.
    await svc.startScreenShareSystemAudio('sink.a.monitor');
    expect(svc.isSharingSystemAudio, isFalse);
  });
}
