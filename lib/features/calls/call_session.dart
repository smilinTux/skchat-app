import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/call_api_client.dart';
import '../../services/livekit_call_service.dart';

enum CallSessionStatus { idle, ringing, connecting, active, minimized, ended, failed }

/// The single source of truth for a 1:1 call. Drives LiveKitCallService (join a
/// server-derived room with a server-minted token) and CallApiClient (ring via
/// the signed CALL_INVITE). The banner, pill, full-screen call view, and ring
/// UI all read/drive this.
class CallSessionState {
  const CallSessionState({
    required this.peer,
    required this.peerName,
    required this.status,
    this.room = '',
    this.token = '',
    this.livekitUrl = '',
    this.isVideo = false,
    this.isMicEnabled = true,
    this.isCameraEnabled = false,
    this.isMinimized = false,
    this.isIncoming = false,
    this.error,
  });

  final String peer;
  final String peerName;
  final CallSessionStatus status;
  final String room;
  final String token;
  final String livekitUrl;
  final bool isVideo;
  final bool isMicEnabled;
  final bool isCameraEnabled;
  final bool isMinimized;
  final bool isIncoming;
  final String? error;

  CallSessionState copyWith({
    String? peer,
    String? peerName,
    CallSessionStatus? status,
    String? room,
    String? token,
    String? livekitUrl,
    bool? isVideo,
    bool? isMicEnabled,
    bool? isCameraEnabled,
    bool? isMinimized,
    bool? isIncoming,
    String? error,
  }) =>
      CallSessionState(
        peer: peer ?? this.peer,
        peerName: peerName ?? this.peerName,
        status: status ?? this.status,
        room: room ?? this.room,
        token: token ?? this.token,
        livekitUrl: livekitUrl ?? this.livekitUrl,
        isVideo: isVideo ?? this.isVideo,
        isMicEnabled: isMicEnabled ?? this.isMicEnabled,
        isCameraEnabled: isCameraEnabled ?? this.isCameraEnabled,
        isMinimized: isMinimized ?? this.isMinimized,
        isIncoming: isIncoming ?? this.isIncoming,
        error: error,
      );
}

class CallSession extends Notifier<CallSessionState?> {
  @override
  CallSessionState? build() => null;

  LiveKitCallService get _lk => ref.read(liveKitCallServiceProvider);
  CallApi get _api => ref.read(callApiProvider);

  Future<void> startOutgoing({
    required String peer,
    required String peerName,
    required bool video,
  }) async {
    state = CallSessionState(
      peer: peer,
      peerName: peerName,
      status: CallSessionStatus.connecting,
      isVideo: video,
      isCameraEnabled: video,
      isIncoming: false,
    );
    try {
      final r = await _api.startCall(peer);
      await _lk.connectWithToken(wsUrl: r.livekitUrl, token: r.token);
      state = state?.copyWith(
        status: CallSessionStatus.active,
        room: r.room,
        token: r.token,
        livekitUrl: r.livekitUrl,
      );
    } catch (e) {
      await _safeLeave();
      state = state?.copyWith(status: CallSessionStatus.failed, error: '$e');
    }
  }

  /// Surface an inbound invite as a ringing state (does NOT connect yet).
  void receiveIncoming(CallInvite invite, {String? peerName}) {
    state = CallSessionState(
      peer: invite.fromFqid,
      peerName: peerName ?? invite.fromFqid,
      status: CallSessionStatus.ringing,
      room: invite.room,
      livekitUrl: invite.livekitUrl,
      isIncoming: true,
    );
  }

  Future<void> acceptIncoming() async {
    final s = state;
    if (s == null || !s.isIncoming) return;
    state = s.copyWith(status: CallSessionStatus.connecting);
    try {
      final r = await _api.answerCall(s.peer);
      await _lk.connectWithToken(wsUrl: r.livekitUrl, token: r.token);
      state = state?.copyWith(
        status: CallSessionStatus.active,
        room: r.room,
        token: r.token,
        livekitUrl: r.livekitUrl,
      );
    } catch (e) {
      await _safeLeave();
      state = state?.copyWith(status: CallSessionStatus.failed, error: '$e');
    }
  }

  Future<void> declineIncoming() async {
    await _safeLeave();
    state = null;
  }

  void minimize() {
    final s = state;
    if (s == null) return;
    state = s.copyWith(status: CallSessionStatus.minimized, isMinimized: true);
  }

  void restore() {
    final s = state;
    if (s == null) return;
    state = s.copyWith(status: CallSessionStatus.active, isMinimized: false);
  }

  Future<void> hangUp() async {
    await _safeLeave();
    state = null;
  }

  Future<void> toggleMic() async {
    final s = state;
    if (s == null) return;
    final next = !s.isMicEnabled;
    await _lk.setMicEnabled(next);
    state = s.copyWith(isMicEnabled: next);
  }

  Future<void> toggleCamera() async {
    final s = state;
    if (s == null) return;
    final next = !s.isCameraEnabled;
    await _lk.setCameraEnabled(next);
    state = s.copyWith(isCameraEnabled: next, isVideo: next ? true : s.isVideo);
  }

  Future<void> _safeLeave() async {
    try {
      await _lk.leaveRoom();
    } catch (_) {
      // Teardown is best-effort: never let a leave error strand the session.
    }
  }
}

final callSessionProvider =
    NotifierProvider<CallSession, CallSessionState?>(CallSession.new);
