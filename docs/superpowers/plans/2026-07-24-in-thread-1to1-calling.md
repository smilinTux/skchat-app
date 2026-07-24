# In-Thread 1:1 Calling (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make 1:1 calling ring the peer (via the existing signed `CALL_INVITE` server path), be minimizable to a floating pill in-thread, and flow through one `CallSession` funnel, retiring the dead parallel WebRTC path.

**Architecture:** A thin `CallApiClient` wraps the server `/call/start|answer|incoming` routes. A single `CallSession` `Notifier` owns all 1:1 call state and drives the existing `LiveKitCallService` (join the server-derived room with the server-minted token) plus `CallApiClient`. An `IncomingCallWatcher` polls `/call/incoming` and drives `CallSession` into a ringing state; the app-shell ring banner and the retargeted `PiPOverlay` both read `CallSession`. The dead Path A (WebRTC `callProvider` + screens) is deleted.

**Tech Stack:** Flutter + Riverpod, Dio, `livekit_client`, `flutter_test` / `mocktail`; Python server (`skchat` FastAPI) for the pre-existing `/call/*` routes.

## Global Constraints

- **No em/en dashes** anywhere (code, comments, docs, commit messages). Commas, colons, parentheses, new sentences. Regular hyphens fine.
- **Dart package name is `skchat`**; test imports use `package:skchat/...`.
- **Reuse, do not fork:** `LiveKitCallService` (`lib/services/livekit_call_service.dart`) + its `liveKitCallServiceProvider`; `backendConfigProvider` (`lib/services/backend_config.dart`, field `skchatWebuiUrl`); the trust gate `_checkCallAllowed` / `canCall` (`lib/features/calls/call_gate.dart`); the existing `PiPOverlay` widget (`lib/features/calls/widgets/pip_overlay.dart`).
- **Server-authoritative rooms:** the caller joins the room + token that `POST /call/start` returns; the callee joins the room the invite carries via `POST /call/answer`. Do NOT derive a room name client-side (retire `sk-room-<ids>` for 1:1).
- **Trust gate unchanged:** `canCall(tier)` blocks `red`; verify-to-unblock. Applies to outgoing 1:1 only, never to group calls (`isGroup`).
- **Hang-up always tears down the LiveKit room** (`LiveKitCallService.leaveRoom()`), even on a partial/failed connect. This fixes the orphaned-call bug.
- **Flutter tests:** `cd ~/clawd/skcapstone-repos/skchat-app && flutter test <path>`. Analyze: `~/flutter/bin/flutter analyze <path>` (flutter is at `~/flutter/bin/flutter`, not on PATH by default).
- **Server tests:** run from `~` to avoid the skmemory collision: `cd ~ && ~/.skenv/bin/python -m pytest <path> -q`.

## Reference: existing signatures this plan consumes (verbatim)

- `LiveKitCallService({String? webuiBaseUrl, ...})`; `Future<void> connectWithToken({required String wsUrl, required String token})`; `Future<void> leaveRoom()`; `Future<void> setMicEnabled(bool enabled)`; `Future<void> setCameraEnabled(bool enabled, {...})`; `Stream<ConnectionState> get connectionState`.
- `final liveKitCallServiceProvider = Provider.autoDispose<LiveKitCallService>((ref) {... webuiBaseUrl: cfg.skchatWebuiUrl ...})`.
- `BackendConfig.skchatWebuiUrl` via `ref.watch(backendConfigProvider)`.
- `bool canCall(PeerTrustTier tier)` (returns `tier != PeerTrustTier.red`).
- Server `POST /call/start` -> `{room, token, livekit_url, peer_fqid, identity}`; `POST /call/answer` -> same shape (no re-ring); `GET /call/incoming` -> `{invites: [{from_fqid, room, livekit_url, topic, ts, nonce}, ...]}` (already signature-filtered + anti-spoof-checked server-side).

## File Structure

- `lib/services/call_api_client.dart` (CREATE): `CallApi` interface, `CallApiClient`, `CallStartResult`, `CallInvite`, `callApiProvider`.
- `lib/features/calls/call_session.dart` (CREATE): `CallSessionStatus`, `CallSessionState`, `CallSession`, `callSessionProvider`.
- `lib/features/calls/incoming_call_watcher.dart` (CREATE): `IncomingCallWatcher`, `incomingCallWatcherProvider`.
- `lib/features/calls/widgets/call_banner.dart` (CREATE): in-thread active-call banner.
- `lib/features/calls/widgets/incoming_call_banner.dart` (CREATE): app-shell ringing banner (Accept/Decline).
- `lib/features/conversation/conversation_screen.dart` (MODIFY): single Call app-bar button, route `_startDirectCall` through `CallSession`, mount `CallBanner`.
- `lib/features/calls/livekit_call_screen.dart` (MODIFY): chevron-down calls `CallSession.minimize()`; wire the screen to `CallSession` (or keep as the active-call surface driven by it).
- `lib/features/calls/widgets/pip_overlay.dart` (MODIFY): retarget from `callProvider` to `callSessionProvider`.
- `lib/features/shell/app_shell.dart` (MODIFY): mount `IncomingCallBanner`; retarget the incoming-call `ref.listen` to `callSessionProvider`; keep `PiPOverlay`.
- **DELETE (Task 6):** `lib/features/calls/call_provider.dart`, `lib/models/call_state.dart`, `lib/services/webrtc_service.dart`, `lib/features/calls/outgoing_call_screen.dart`, `lib/features/calls/incoming_call_screen.dart`, `lib/features/calls/in_call_screen.dart`, `lib/features/calls/widgets/call_controls.dart` (if unused after), and their routes in `lib/core/router/app_router.dart`.
- Tests: `test/services/call_api_client_test.dart`, `test/features/calls/call_session_test.dart`, `test/features/calls/incoming_call_watcher_test.dart`, `test/features/calls/call_banner_test.dart`, `test/features/calls/incoming_call_banner_test.dart`, plus an app-bar widget test.
- Server: `src/skchat/...` verification (Task 7), `tests/` if a proxy is added.

---

## Task 1: `CallApiClient` (server /call/* transport)

**Files:**
- Create: `lib/services/call_api_client.dart`
- Test: `test/services/call_api_client_test.dart`

**Interfaces:**
- Produces:
  - `class CallStartResult { final String room, token, livekitUrl, peerFqid, identity; CallStartResult.fromJson(Map) }`
  - `class CallInvite { final String fromFqid, room, livekitUrl, topic, nonce; final int ts; CallInvite.fromJson(Map) }`
  - `abstract class CallApi { Future<CallStartResult> startCall(String peer); Future<CallStartResult> answerCall(String peer); Future<List<CallInvite>> pollIncoming(); }`
  - `class CallApiClient implements CallApi` (constructed with `{required String baseUrl, Dio? dio}`).
  - `final callApiProvider = Provider<CallApi>((ref) => CallApiClient(baseUrl: ref.watch(backendConfigProvider).skchatWebuiUrl));`

- [ ] **Step 1: Write the failing test**

Create `test/services/call_api_client_test.dart`:

```dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/call_api_client.dart';

/// Minimal in-memory Dio adapter: maps "METHOD path" -> (status, json).
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.routes);
  final Map<String, (int, Object)> routes;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? _, Future<void>? __) async {
    final key = '${options.method} ${options.path}';
    final entry = routes[key];
    if (entry == null) return ResponseBody.fromString('{}', 404);
    return ResponseBody.fromString(_json(entry.$2), entry.$1,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
  static String _json(Object o) => o is String ? o : _encode(o);
  static String _encode(Object o) => o.toString();
}

Dio _dioWith(Map<String, (int, Object)> routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://webui.test'));
  dio.httpClientAdapter = _StubAdapter(routes);
  return dio;
}

void main() {
  group('CallApiClient', () {
    test('startCall posts /call/start and parses the room+token', () async {
      final dio = _dioWith({
        'POST https://webui.test/call/start':
            (200, '{"room":"call-abc","token":"tok1","livekit_url":"wss://sfu","peer_fqid":"steward@skworld.io","identity":"chef@skworld.io"}'),
      });
      final api = CallApiClient(baseUrl: 'https://webui.test', dio: dio);
      final r = await api.startCall('steward@skworld.io');
      expect(r.room, 'call-abc');
      expect(r.token, 'tok1');
      expect(r.livekitUrl, 'wss://sfu');
      expect(r.peerFqid, 'steward@skworld.io');
    });

    test('answerCall posts /call/answer and parses the same shape', () async {
      final dio = _dioWith({
        'POST https://webui.test/call/answer':
            (200, '{"room":"call-abc","token":"tok2","livekit_url":"wss://sfu","peer_fqid":"steward@skworld.io","identity":"chef@skworld.io"}'),
      });
      final api = CallApiClient(baseUrl: 'https://webui.test', dio: dio);
      final r = await api.answerCall('steward@skworld.io');
      expect(r.room, 'call-abc');
      expect(r.token, 'tok2');
    });

    test('pollIncoming parses the invites array', () async {
      final dio = _dioWith({
        'GET https://webui.test/call/incoming':
            (200, '{"invites":[{"from_fqid":"steward@skworld.io","room":"call-abc","livekit_url":"wss://sfu","topic":"","ts":123,"nonce":"n1"}]}'),
      });
      final api = CallApiClient(baseUrl: 'https://webui.test', dio: dio);
      final invites = await api.pollIncoming();
      expect(invites, hasLength(1));
      expect(invites.first.fromFqid, 'steward@skworld.io');
      expect(invites.first.room, 'call-abc');
      expect(invites.first.nonce, 'n1');
    });

    test('pollIncoming returns empty on a missing invites key', () async {
      final dio = _dioWith({'GET https://webui.test/call/incoming': (200, '{}')});
      final api = CallApiClient(baseUrl: 'https://webui.test', dio: dio);
      expect(await api.pollIncoming(), isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/services/call_api_client_test.dart`
Expected: FAIL (`call_api_client.dart` does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/services/call_api_client.dart`:

```dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_config.dart';

/// Result of POST /call/start or /call/answer: the server-derived room plus a
/// minted LiveKit token for THIS caller/callee and the SFU ws URL to join.
class CallStartResult {
  const CallStartResult({
    required this.room,
    required this.token,
    required this.livekitUrl,
    required this.peerFqid,
    required this.identity,
  });

  final String room;
  final String token;
  final String livekitUrl;
  final String peerFqid;
  final String identity;

  factory CallStartResult.fromJson(Map<String, dynamic> j) => CallStartResult(
        room: j['room'] as String? ?? '',
        token: j['token'] as String? ?? '',
        livekitUrl: j['livekit_url'] as String? ?? '',
        peerFqid: j['peer_fqid'] as String? ?? '',
        identity: j['identity'] as String? ?? '',
      );
}

/// One signed, server-verified incoming CALL_INVITE addressed to self.
class CallInvite {
  const CallInvite({
    required this.fromFqid,
    required this.room,
    required this.livekitUrl,
    required this.topic,
    required this.ts,
    required this.nonce,
  });

  final String fromFqid;
  final String room;
  final String livekitUrl;
  final String topic;
  final int ts;
  final String nonce;

  factory CallInvite.fromJson(Map<String, dynamic> j) => CallInvite(
        fromFqid: j['from_fqid'] as String? ?? '',
        room: j['room'] as String? ?? '',
        livekitUrl: j['livekit_url'] as String? ?? '',
        topic: j['topic'] as String? ?? '',
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        nonce: j['nonce'] as String? ?? '',
      );
}

/// Interface so tests inject a fake instead of the real transport.
abstract class CallApi {
  Future<CallStartResult> startCall(String peer);
  Future<CallStartResult> answerCall(String peer);
  Future<List<CallInvite>> pollIncoming();
}

/// Thin client over the skchat web-UI /call/* routes (the same origin that
/// serves POST /livekit/token). Rings via the server's signed CALL_INVITE.
class CallApiClient implements CallApi {
  CallApiClient({required String baseUrl, Dio? dio})
      : _base = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _dio = dio ?? Dio();

  final String _base;
  final Dio _dio;

  @override
  Future<CallStartResult> startCall(String peer) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '$_base/call/start',
      data: {'peer': peer},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    return CallStartResult.fromJson(resp.data ?? {});
  }

  @override
  Future<CallStartResult> answerCall(String peer) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '$_base/call/answer',
      data: {'peer': peer},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    return CallStartResult.fromJson(resp.data ?? {});
  }

  @override
  Future<List<CallInvite>> pollIncoming() async {
    final resp = await _dio.get<Map<String, dynamic>>('$_base/call/incoming');
    final list = (resp.data?['invites'] as List<dynamic>?) ?? const [];
    return list
        .map((e) => CallInvite.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final callApiProvider = Provider<CallApi>(
  (ref) => CallApiClient(baseUrl: ref.watch(backendConfigProvider).skchatWebuiUrl),
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/services/call_api_client_test.dart`
Expected: PASS (4 tests). If the stub adapter's JSON encoding path needs adjusting for your Dio version, keep the passed JSON as a String (the tests already pass String bodies, so `_json` returns them verbatim).

- [ ] **Step 5: Commit**

```bash
git add lib/services/call_api_client.dart test/services/call_api_client_test.dart
git commit -m "feat(calls): CallApiClient over server /call/* ring routes"
```

---

## Task 2: `CallSession` provider (the one funnel)

**Files:**
- Create: `lib/features/calls/call_session.dart`
- Test: `test/features/calls/call_session_test.dart`

**Interfaces:**
- Consumes: `CallApi` (Task 1) via `callApiProvider`; `LiveKitCallService` via `liveKitCallServiceProvider` (methods `connectWithToken`, `leaveRoom`, `setMicEnabled`, `setCameraEnabled`).
- Produces:
  - `enum CallSessionStatus { idle, ringing, connecting, active, minimized, ended, failed }`
  - `class CallSessionState { peer, peerName, room, token, livekitUrl, status, isVideo, isMicEnabled, isCameraEnabled, isMinimized, isIncoming, error; copyWith(...) }`
  - `class CallSession extends Notifier<CallSessionState?>` with `startOutgoing({required String peer, required String peerName, required bool video})`, `receiveIncoming(CallInvite invite, {String? peerName})`, `acceptIncoming()`, `declineIncoming()`, `minimize()`, `restore()`, `hangUp()`, `toggleMic()`, `toggleCamera()`.
  - `final callSessionProvider = NotifierProvider<CallSession, CallSessionState?>(CallSession.new);`

- [ ] **Step 1: Write the failing test**

Create `test/features/calls/call_session_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' show ConnectionState;
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _FakeApi implements CallApi {
  int startCalls = 0, answerCalls = 0;
  CallStartResult result = const CallStartResult(
      room: 'call-abc', token: 'tok', livekitUrl: 'wss://sfu',
      peerFqid: 'steward@skworld.io', identity: 'chef@skworld.io');
  bool throwOnStart = false;
  @override
  Future<CallStartResult> startCall(String peer) async {
    startCalls++;
    if (throwOnStart) throw StateError('start failed');
    return result;
  }
  @override
  Future<CallStartResult> answerCall(String peer) async {
    answerCalls++;
    return result;
  }
  @override
  Future<List<CallInvite>> pollIncoming() async => const [];
}

/// Fake LiveKit service: records calls, never touches a real Room. The super
/// ctor only builds an (unused) Dio, so no network happens as long as we
/// override every method CallSession calls.
class _FakeLk extends LiveKitCallService {
  _FakeLk() : super(webuiBaseUrl: 'http://unused.test');
  int connects = 0, leaves = 0;
  bool? micSet, camSet;
  String? lastWsUrl, lastToken;
  @override
  Future<void> connectWithToken({required String wsUrl, required String token}) async {
    connects++;
    lastWsUrl = wsUrl;
    lastToken = token;
  }
  @override
  Future<void> leaveRoom() async {
    leaves++;
  }
  @override
  Future<void> setMicEnabled(bool enabled) async {
    micSet = enabled;
  }
  @override
  Future<void> setCameraEnabled(bool enabled,
      {CameraPosition? cameraPosition, String? deviceId}) async {
    camSet = enabled;
  }
}

ProviderContainer _container(_FakeApi api, _FakeLk lk) => ProviderContainer(
      overrides: [
        callApiProvider.overrideWithValue(api),
        liveKitCallServiceProvider.overrideWithValue(lk),
      ],
    );

void main() {
  test('startOutgoing rings via startCall then connects, becomes active', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);

    await s.startOutgoing(peer: 'steward@skworld.io', peerName: 'Steward', video: false);

    expect(api.startCalls, 1);
    expect(lk.connects, 1);
    expect(lk.lastToken, 'tok');
    expect(lk.lastWsUrl, 'wss://sfu');
    final st = c.read(callSessionProvider)!;
    expect(st.status, CallSessionStatus.active);
    expect(st.room, 'call-abc');
    expect(st.isIncoming, isFalse);
  });

  test('a failed start does NOT connect and lands in failed', () async {
    final api = _FakeApi()..throwOnStart = true;
    final lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);

    await s.startOutgoing(peer: 'x@y', peerName: 'X', video: false);

    expect(lk.connects, 0);
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.failed);
  });

  test('acceptIncoming answers then connects', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);

    s.receiveIncoming(
      const CallInvite(fromFqid: 'steward@skworld.io', room: 'call-abc',
          livekitUrl: 'wss://sfu', topic: '', ts: 1, nonce: 'n1'),
      peerName: 'Steward',
    );
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.ringing);
    expect(c.read(callSessionProvider)!.isIncoming, isTrue);

    await s.acceptIncoming();
    expect(api.answerCalls, 1);
    expect(lk.connects, 1);
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.active);
  });

  test('minimize/restore only flips the flag, does not leave the room', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);
    await s.startOutgoing(peer: 'a@b', peerName: 'A', video: false);

    s.minimize();
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.minimized);
    expect(c.read(callSessionProvider)!.isMinimized, isTrue);
    expect(lk.leaves, 0);

    s.restore();
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.active);
    expect(c.read(callSessionProvider)!.isMinimized, isFalse);
  });

  test('hangUp always tears down the room and ends', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);
    await s.startOutgoing(peer: 'a@b', peerName: 'A', video: false);

    await s.hangUp();
    expect(lk.leaves, 1);
    expect(c.read(callSessionProvider), isNull);
  });

  test('declineIncoming ends without connecting', () async {
    final api = _FakeApi(), lk = _FakeLk();
    final c = _container(api, lk);
    addTearDown(c.dispose);
    final s = c.read(callSessionProvider.notifier);
    s.receiveIncoming(
      const CallInvite(fromFqid: 'a@b', room: 'r', livekitUrl: 'w', topic: '', ts: 1, nonce: 'n'),
    );
    await s.declineIncoming();
    expect(lk.connects, 0);
    expect(c.read(callSessionProvider), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/calls/call_session_test.dart`
Expected: FAIL (`call_session.dart` does not exist). If `_FakeLk`'s `setCameraEnabled` override signature does not match `LiveKitCallService`, adjust the named params to match the real signature exactly (read `lib/services/livekit_call_service.dart:788`).

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/calls/call_session.dart`:

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/calls/call_session_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/calls/call_session.dart test/features/calls/call_session_test.dart
git commit -m "feat(calls): CallSession funnel (ring/connect/minimize/hangup state machine)"
```

---

## Task 3: Wire the outgoing caller through `CallSession` + single Call button

**Files:**
- Modify: `lib/features/conversation/conversation_screen.dart` (`_startDirectCall`, the app-bar call buttons)
- Test: `test/features/conversation/conversation_call_button_test.dart` (CREATE)

**Interfaces:**
- Consumes: `callSessionProvider` (Task 2), the existing `_checkCallAllowed` gate.
- Produces: a single app-bar Call `IconButton` (tap = audio, long-press = video) for a 1:1 conversation, routing through `CallSession.startOutgoing` after the gate. `_startDirectCall` no longer derives `sk-room-<ids>` nor pushes `LiveKitCallScreen` directly; it calls `CallSession.startOutgoing`. (Group path unchanged.)

- [ ] **Step 1: Write the failing test**

Create `test/features/conversation/conversation_call_button_test.dart`. It mounts just the app-bar call control in isolation with a fake `CallSession` and asserts tap starts audio, long-press starts video, and a red-tier peer is blocked. Because `conversation_screen` is large, the test targets a small extracted widget `ConversationCallButton({required Conversation conversation})` that this task introduces (keeps the control testable in isolation).

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/conversation/widgets/conversation_call_button.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/livekit_call_service.dart';
import 'package:skchat/services/peer_trust_store.dart';

class _MemStore implements PeerTrustStore {
  final Map<String, PeerTrustRecord> _m = {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => _m;
  @override
  Future<void> save(Map<String, PeerTrustRecord> r) async {
    _m..clear()..addAll(r);
  }
}

class _FakeApi implements CallApi {
  @override
  Future<CallStartResult> startCall(String p) async => const CallStartResult(
      room: 'r', token: 't', livekitUrl: 'w', peerFqid: 'p', identity: 'i');
  @override
  Future<CallStartResult> answerCall(String p) async => startCall(p);
  @override
  Future<List<CallInvite>> pollIncoming() async => const [];
}

class _FakeLk extends LiveKitCallService {
  _FakeLk() : super(webuiBaseUrl: 'http://x');
  @override
  Future<void> connectWithToken({required String wsUrl, required String token}) async {}
  @override
  Future<void> leaveRoom() async {}
}

Conversation _peer(String fp) => Conversation(
      peerId: 'steward@skworld.io',
      displayName: 'Steward',
      lastMessage: '',
      lastMessageTime: DateTime(2026),
      soulFingerprint: fp,
    );

Widget _host(Conversation c, {PeerTrustStore? store}) => ProviderScope(
      overrides: [
        callApiProvider.overrideWithValue(_FakeApi()),
        liveKitCallServiceProvider.overrideWithValue(_FakeLk()),
        peerTrustResolverProvider
            .overrideWithValue(PeerTrustResolver(store ?? _MemStore())),
      ],
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [ConversationCallButton(conversation: c)]),
        ),
      ),
    );

void main() {
  testWidgets('tap starts an audio call', (tester) async {
    final store = _MemStore();
    // Verify the peer so the gate allows the call (amber).
    await PeerTrustResolver(store).markVerifyFlow('steward@skworld.io', 'FP1');
    late ProviderContainer container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container = ProviderContainer(overrides: [
          callApiProvider.overrideWithValue(_FakeApi()),
          liveKitCallServiceProvider.overrideWithValue(_FakeLk()),
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(store)),
        ]),
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [ConversationCallButton(conversation: _peer('FP1'))]),
          ),
        ),
      ),
    );
    addTearDown(container.dispose);
    await tester.tap(find.byKey(const Key('conversation-call-button')));
    await tester.pumpAndSettle();

    final st = container.read(callSessionProvider);
    expect(st, isNotNull);
    expect(st!.isVideo, isFalse);
  });

  testWidgets('long-press starts a video call', (tester) async {
    final store = _MemStore();
    await PeerTrustResolver(store).markVerifyFlow('steward@skworld.io', 'FP1');
    final container = ProviderContainer(overrides: [
      callApiProvider.overrideWithValue(_FakeApi()),
      liveKitCallServiceProvider.overrideWithValue(_FakeLk()),
      peerTrustResolverProvider.overrideWithValue(PeerTrustResolver(store)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [ConversationCallButton(conversation: _peer('FP1'))]),
        ),
      ),
    ));
    await tester.longPress(find.byKey(const Key('conversation-call-button')));
    await tester.pumpAndSettle();

    expect(container.read(callSessionProvider)!.isVideo, isTrue);
  });

  testWidgets('a red (unverified) peer is blocked with a verify prompt', (tester) async {
    final container = ProviderContainer(overrides: [
      callApiProvider.overrideWithValue(_FakeApi()),
      liveKitCallServiceProvider.overrideWithValue(_FakeLk()),
      peerTrustResolverProvider.overrideWithValue(PeerTrustResolver(_MemStore())),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [ConversationCallButton(conversation: _peer('FP1'))]),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('conversation-call-button')));
    await tester.pumpAndSettle();

    expect(container.read(callSessionProvider), isNull); // blocked
    expect(find.text('Verify Steward before calling'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/conversation/conversation_call_button_test.dart`
Expected: FAIL (`conversation_call_button.dart` does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/conversation/widgets/conversation_call_button.dart`. It carries the gate + one-button UX (tap audio, long-press video), reusing the same trust logic `_checkCallAllowed` uses (`peerTrustResolverProvider.tierFor` + `canCall`) so a red peer shows the same verify prompt:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/conversation.dart';
import '../../../services/peer_trust_store.dart';
import '../../calls/call_gate.dart';
import '../../calls/call_session.dart';
import '../../identity/widgets/verify_peer_sheet.dart';

/// Single app-bar Call control for a 1:1 conversation: tap = audio call,
/// long-press = video call. Both route through CallSession after the
/// verify-before-call trust gate (red peer blocked, same prompt as before).
class ConversationCallButton extends ConsumerWidget {
  const ConversationCallButton({super.key, required this.conversation});

  final Conversation conversation;

  Future<void> _startGated(BuildContext context, WidgetRef ref, {required bool video}) async {
    final messenger = ScaffoldMessenger.of(context);
    final tier = await ref
        .read(peerTrustResolverProvider)
        .tierFor(conversation.peerId, conversation.soulFingerprint);
    if (!canCall(tier)) {
      messenger.showSnackBar(SnackBar(
        content: Text('Verify ${conversation.displayName} before calling'),
        action: SnackBarAction(
          label: 'Verify',
          onPressed: () {
            if (!context.mounted) return;
            showVerifyPeerSheet(
              context,
              ref,
              peerId: conversation.peerId,
              peerName: conversation.displayName,
              peerFingerprint: conversation.soulFingerprint,
            );
          },
        ),
      ));
      return;
    }
    await ref.read(callSessionProvider.notifier).startOutgoing(
          peer: conversation.peerId,
          peerName: conversation.displayName,
          video: video,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      key: const Key('conversation-call-button'),
      icon: const Icon(Icons.call_outlined),
      tooltip: 'Call (long-press for video)',
      onPressed: () => _startGated(context, ref, video: false),
      // Long-press for video: GestureDetector wrapping keeps the standard
      // IconButton tap ripple while adding the long-press affordance.
    );
  }
}
```

Because `IconButton` has no `onLongPress`, wrap it so long-press works. Replace the `build` return with:

```dart
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onLongPress: () => _startGated(context, ref, video: true),
      child: IconButton(
        key: const Key('conversation-call-button'),
        icon: const Icon(Icons.call_outlined),
        tooltip: 'Call (long-press for video)',
        onPressed: () => _startGated(context, ref, video: false),
      ),
    );
  }
```

Then in `lib/features/conversation/conversation_screen.dart`, in the app-bar `actions`, REPLACE the two 1:1 call `IconButton`s (the `Icons.call_outlined` "Voice call" at ~786 and `Icons.videocam_outlined` "Video call" at ~824) and the `Icons.meeting_room_outlined` "Agent room (LiveKit)" button (~847) with, for a NON-group conversation, a single `ConversationCallButton(conversation: conv)`. Keep the group branch (`conversation.isGroup == true`) exactly as it is (it still calls `_startGroupCall`). Import `widgets/conversation_call_button.dart`.

Also replace the body of `_startDirectCall` so any remaining caller routes through the session (delete the `sk-room-` derivation and the `context.push(AppRoutes.livekitCall, ...)`):

```dart
  void _startDirectCall(
    BuildContext context,
    WidgetRef ref,
    String displayName, {
    required bool withVideo,
  }) {
    ref.read(callSessionProvider.notifier).startOutgoing(
          peer: peerId,
          peerName: displayName,
          video: withVideo,
        );
  }
```

(`_startDirectCallGated` still gates then calls `_startDirectCall`; both stay for any non-app-bar caller. The app bar now uses `ConversationCallButton` which gates internally.)

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd ~/clawd/skcapstone-repos/skchat-app
flutter test test/features/conversation/conversation_call_button_test.dart
~/flutter/bin/flutter analyze lib/features/conversation/ lib/features/calls/call_session.dart
```
Expected: PASS (3 tests); analyze clean.

- [ ] **Step 5: Commit**

```bash
git add lib/features/conversation/widgets/conversation_call_button.dart lib/features/conversation/conversation_screen.dart test/features/conversation/conversation_call_button_test.dart
git commit -m "feat(calls): single Call app-bar control routing through CallSession"
```

---

## Task 4: `IncomingCallWatcher` + ring banner

**Files:**
- Create: `lib/features/calls/incoming_call_watcher.dart`
- Create: `lib/features/calls/widgets/incoming_call_banner.dart`
- Modify: `lib/features/shell/app_shell.dart`
- Test: `test/features/calls/incoming_call_watcher_test.dart`, `test/features/calls/incoming_call_banner_test.dart`

**Interfaces:**
- Consumes: `callApiProvider.pollIncoming`, `callSessionProvider.notifier.receiveIncoming`.
- Produces: `class IncomingCallWatcher` with `Future<void> pollOnce()` (dedupes by nonce, drives the newest unhandled invite into `CallSession`); `incomingCallWatcherProvider`. `IncomingCallBanner` widget (Accept -> `acceptIncoming`, Decline -> `declineIncoming`).

- [ ] **Step 1: Write the failing test (watcher)**

Create `test/features/calls/incoming_call_watcher_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/calls/incoming_call_watcher.dart';
import 'package:skchat/services/call_api_client.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _Api implements CallApi {
  List<CallInvite> incoming = const [];
  bool throwOnce = false;
  @override
  Future<CallStartResult> startCall(String p) async => throw UnimplementedError();
  @override
  Future<CallStartResult> answerCall(String p) async => throw UnimplementedError();
  @override
  Future<List<CallInvite>> pollIncoming() async {
    if (throwOnce) {
      throwOnce = false;
      throw StateError('poll failed');
    }
    return incoming;
  }
}

class _Lk extends LiveKitCallService {
  _Lk() : super(webuiBaseUrl: 'http://x');
  @override
  Future<void> connectWithToken({required String wsUrl, required String token}) async {}
  @override
  Future<void> leaveRoom() async {}
}

ProviderContainer _c(_Api api) => ProviderContainer(overrides: [
      callApiProvider.overrideWithValue(api),
      liveKitCallServiceProvider.overrideWithValue(_Lk()),
    ]);

CallInvite _inv(String nonce) => CallInvite(
    fromFqid: 'steward@skworld.io', room: 'r', livekitUrl: 'w', topic: '', ts: 1, nonce: nonce);

void main() {
  test('pollOnce with an invite drives CallSession into ringing', () async {
    final api = _Api()..incoming = [_inv('n1')];
    final c = _c(api);
    addTearDown(c.dispose);
    await c.read(incomingCallWatcherProvider).pollOnce();
    final st = c.read(callSessionProvider);
    expect(st?.status, CallSessionStatus.ringing);
    expect(st?.isIncoming, isTrue);
  });

  test('the same nonce does not re-ring an already-handled invite', () async {
    final api = _Api()..incoming = [_inv('n1')];
    final c = _c(api);
    addTearDown(c.dispose);
    final w = c.read(incomingCallWatcherProvider);
    await w.pollOnce();
    // User hangs up / it ends; session cleared.
    c.read(callSessionProvider.notifier).state = null;
    await w.pollOnce(); // same nonce still returned by the server
    expect(c.read(callSessionProvider), isNull); // not re-rung
  });

  test('a poll failure is swallowed (no throw, no ring)', () async {
    final api = _Api()..throwOnce = true;
    final c = _c(api);
    addTearDown(c.dispose);
    await c.read(incomingCallWatcherProvider).pollOnce(); // must not throw
    expect(c.read(callSessionProvider), isNull);
  });

  test('does not override an already-active call', () async {
    final api = _Api()..incoming = [_inv('n2')];
    final c = _c(api);
    addTearDown(c.dispose);
    // Simulate an active outgoing call.
    c.read(callSessionProvider.notifier).state = const CallSessionState(
        peer: 'x', peerName: 'X', status: CallSessionStatus.active);
    await c.read(incomingCallWatcherProvider).pollOnce();
    expect(c.read(callSessionProvider)!.status, CallSessionStatus.active);
  });
}
```

Note: the two tests that poke `callSessionProvider.notifier.state = ...` require `state` to be settable from the test; `Notifier.state` is `@protected`. To keep the test black-box, instead expose a test seam by having those tests drive state through the public API where possible. For "does not override active", start a call via a fake first; for "same nonce", call `hangUp()` instead of setting state. Adjust the two tests to:
- same-nonce: after first `pollOnce`, call `await c.read(callSessionProvider.notifier).hangUp();` then `pollOnce` again.
- active: `await c.read(callSessionProvider.notifier).startOutgoing(peer:'x',peerName:'X',video:false);` (the fake Lk/Api make this succeed) then `pollOnce`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/calls/incoming_call_watcher_test.dart`
Expected: FAIL (`incoming_call_watcher.dart` does not exist).

- [ ] **Step 3: Write minimal implementation (watcher)**

Create `lib/features/calls/incoming_call_watcher.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/call_api_client.dart';
import 'call_session.dart';

/// Polls the server /call/incoming and surfaces the newest unhandled invite as
/// a ringing CallSession. Dedupes by nonce so the same server-retained invite
/// is not re-rung after the user handled it. A poll failure is swallowed (the
/// next tick retries) so a transient error never spams a phantom ring.
class IncomingCallWatcher {
  IncomingCallWatcher(this._ref);
  final Ref _ref;
  final Set<String> _handled = {};

  Future<void> pollOnce() async {
    // Never interrupt a call already in progress.
    final cur = _ref.read(callSessionProvider);
    if (cur != null && cur.status != CallSessionStatus.idle) return;

    List<CallInvite> invites;
    try {
      invites = await _ref.read(callApiProvider).pollIncoming();
    } catch (_) {
      return; // silent retry next tick
    }
    if (invites.isEmpty) return;
    // Newest by ts; skip any nonce we already surfaced.
    invites.sort((a, b) => b.ts.compareTo(a.ts));
    final fresh = invites.where((i) => !_handled.contains(i.nonce)).toList();
    if (fresh.isEmpty) return;
    final invite = fresh.first;
    _handled.add(invite.nonce);
    _ref.read(callSessionProvider.notifier).receiveIncoming(invite);
  }
}

final incomingCallWatcherProvider =
    Provider<IncomingCallWatcher>((ref) => IncomingCallWatcher(ref));
```

- [ ] **Step 4: Run tests to verify they pass, then build the banner + wire the poll timer**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/calls/incoming_call_watcher_test.dart`
Expected: PASS (4 tests).

Then create `lib/features/calls/widgets/incoming_call_banner.dart` (a `ConsumerWidget` that watches `callSessionProvider`; when `status == ringing && isIncoming`, shows a material banner with the peer name, an Accept button (`Key('incoming-accept')` -> `acceptIncoming()`) and a Decline button (`Key('incoming-decline')` -> `declineIncoming()`); otherwise `SizedBox.shrink()`):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../call_session.dart';

class IncomingCallBanner extends ConsumerWidget {
  const IncomingCallBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(callSessionProvider);
    if (s == null || s.status != CallSessionStatus.ringing || !s.isIncoming) {
      return const SizedBox.shrink();
    }
    final notifier = ref.read(callSessionProvider.notifier);
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.call_received_rounded),
              const SizedBox(width: 10),
              Expanded(child: Text('Incoming call from ${s.peerName}')),
              TextButton(
                key: const Key('incoming-decline'),
                onPressed: notifier.declineIncoming,
                child: const Text('Decline'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                key: const Key('incoming-accept'),
                onPressed: notifier.acceptIncoming,
                child: const Text('Accept'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

In `lib/features/shell/app_shell.dart`: (a) mount `const IncomingCallBanner()` at the top of the shell body Column (above the offline banner is fine); (b) add a foreground poll: in the `AppShell` build, start a periodic poll via a small `StatefulWidget` wrapper or a `ref.listen`/`Timer` that calls `ref.read(incomingCallWatcherProvider).pollOnce()` every ~4 seconds while mounted; (c) the existing dead `ref.listen<CallState?>(callProvider, ...)` block is removed in Task 6 (leave it for now, it is inert). Import the watcher + banner.

Add the banner widget test `test/features/calls/incoming_call_banner_test.dart`: pump `IncomingCallBanner` in a `ProviderScope` whose `callSessionProvider` is overridden into a ringing-incoming state (use a small fake notifier subclass returning that state from `build()`), tap `incoming-accept`, assert `acceptIncoming` ran (fake CallApi.answerCall called); pump a non-ringing state, assert `SizedBox.shrink` (no Accept button).

- [ ] **Step 5: Commit**

```bash
git add lib/features/calls/incoming_call_watcher.dart lib/features/calls/widgets/incoming_call_banner.dart lib/features/shell/app_shell.dart test/features/calls/incoming_call_watcher_test.dart test/features/calls/incoming_call_banner_test.dart
git commit -m "feat(calls): poll /call/incoming + ringing incoming-call banner"
```

---

## Task 5: Minimize (retarget PiPOverlay) + in-thread banner + orphaned-call fix

**Files:**
- Modify: `lib/features/calls/widgets/pip_overlay.dart` (retarget to `callSessionProvider`)
- Modify: `lib/features/calls/livekit_call_screen.dart` (chevron-down -> `CallSession.minimize()`; drive the active call from `CallSession`; hang-up -> `CallSession.hangUp()`)
- Create: `lib/features/calls/widgets/call_banner.dart` (in-thread active-call banner)
- Modify: `lib/features/conversation/conversation_screen.dart` (mount `CallBanner`)
- Test: `test/features/calls/pip_overlay_test.dart`, `test/features/calls/call_banner_test.dart`

**Interfaces:**
- Consumes: `callSessionProvider`.
- Produces: `PiPOverlay` shows the draggable pill when `callSessionProvider` is `minimized`, tap -> `restore()`; `CallBanner` shows in a conversation when a call with that peer is active/minimized, tap -> `restore()` + open the call screen.

- [ ] **Step 1: Write the failing test (retargeted PiPOverlay)**

Create `test/features/calls/pip_overlay_test.dart`: pump `PiPOverlay(child: ...)` in a `ProviderScope` overriding `callSessionProvider` with a fake notifier in a `minimized` state; assert the pill is shown (find its `Key('call-pip-window')`); tapping it calls `restore()` (state flips to active, pill disappears). A `null`/`active`-non-minimized state shows no pill.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_session.dart';
import 'package:skchat/features/calls/widgets/pip_overlay.dart';

class _Fixed extends CallSession {
  _Fixed(this._seed);
  final CallSessionState? _seed;
  @override
  CallSessionState? build() => _seed;
}

Widget _host(CallSessionState? seed) => ProviderScope(
      overrides: [callSessionProvider.overrideWith(() => _Fixed(seed))],
      child: const MaterialApp(home: PiPOverlay(child: Scaffold(body: SizedBox()))),
    );

void main() {
  testWidgets('minimized session shows the pill', (tester) async {
    await tester.pumpWidget(_host(const CallSessionState(
        peer: 'a', peerName: 'A', status: CallSessionStatus.minimized, isMinimized: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsOneWidget);
  });

  testWidgets('no session shows no pill', (tester) async {
    await tester.pumpWidget(_host(null));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-pip-window')), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/calls/pip_overlay_test.dart`
Expected: FAIL (PiPOverlay still watches the old `callProvider`/`CallState`; the `Key('call-pip-window')` does not exist yet).

- [ ] **Step 3: Write minimal implementation**

In `lib/features/calls/widgets/pip_overlay.dart`: replace the `ref.listen<CallState?>(callProvider, ...)` and `_PiPWindow` logic so it watches `callSessionProvider` and shows the overlay when `state?.isMinimized == true` (or `status == minimized`). Give the pill window a `Key('call-pip-window')`. Tapping it calls `ref.read(callSessionProvider.notifier).restore()` (and optionally navigates to the call screen). The pill's hang-up button calls `hangUp()`. Match the existing draggable `_PiPWindow` structure, only swapping the provider + state fields (peer name from `CallSessionState.peerName`). Remove the `call_provider.dart` / `models/call_state.dart` imports.

In `lib/features/calls/livekit_call_screen.dart`: change the `_TopBar` back chevron `onTap` from `context.pop()` to: `ref.read(callSessionProvider.notifier).minimize(); context.pop();` so leaving the screen minimizes (keeps the room live via CallSession, no orphaned room). Ensure the screen's hang-up path calls `ref.read(callSessionProvider.notifier).hangUp()`. (The screen may still render from `liveKitCallProvider` for media; the authority for lifecycle is now `CallSession`.)

Create `lib/features/calls/widgets/call_banner.dart`: a `ConsumerWidget` taking `{required String peerId}` that watches `callSessionProvider`; when a session exists for that `peer` and is active or minimized, shows a slim tappable banner ("Tap to return to call with {peerName}") whose tap calls `restore()` and pushes the call screen; else `SizedBox.shrink()`.

In `conversation_screen.dart`, mount `CallBanner(peerId: peerId)` at the top of the conversation body.

- [ ] **Step 4: Run tests + analyze**

Run:
```bash
cd ~/clawd/skcapstone-repos/skchat-app
flutter test test/features/calls/pip_overlay_test.dart test/features/calls/call_banner_test.dart
~/flutter/bin/flutter analyze lib/features/calls/
```
Expected: PASS; analyze clean (no dangling `callProvider` import in pip_overlay).

- [ ] **Step 5: Commit**

```bash
git add lib/features/calls/widgets/pip_overlay.dart lib/features/calls/livekit_call_screen.dart lib/features/calls/widgets/call_banner.dart lib/features/conversation/conversation_screen.dart test/features/calls/pip_overlay_test.dart test/features/calls/call_banner_test.dart
git commit -m "feat(calls): minimizable call (retarget PiPOverlay) + in-thread banner + fix orphaned room"
```

---

## Task 6: Retire the dead WebRTC path (Path A)

**Files:**
- Delete: `lib/features/calls/call_provider.dart`, `lib/models/call_state.dart`, `lib/services/webrtc_service.dart`, `lib/features/calls/outgoing_call_screen.dart`, `lib/features/calls/incoming_call_screen.dart`, `lib/features/calls/in_call_screen.dart`, and `lib/features/calls/widgets/call_controls.dart` (only if now unused).
- Modify: `lib/core/router/app_router.dart` (remove the `outgoingCall` / `incomingCall` / `inCall` routes + imports; keep `livekitCall`).
- Modify: `lib/features/shell/app_shell.dart` (remove the dead `ref.listen<CallState?>(callProvider, ...)` block; `IncomingCallBanner` from Task 4 replaces it).
- Any other importer of the deleted symbols (find with grep).

**Interfaces:** none produced. Removes `CallState`/`CallStatus`/`CallType`, `callProvider`, `hasActiveCallProvider`, `WebRTCCallService`, and the three legacy call screens.

- [ ] **Step 1: Find every reference**

Run:
```bash
cd ~/clawd/skcapstone-repos/skchat-app
grep -rn "call_provider\|callProvider\|hasActiveCallProvider\|models/call_state\|CallState\b\|CallStatus\b\|CallType\b\|webrtc_service\|WebRTCCallService\|OutgoingCallScreen\|IncomingCallScreen\|InCallScreen\|call_controls\|CallControls" lib/ test/
```
Record every hit. Any references OUTSIDE the files being deleted (other than the router + app_shell already listed) must be reconciled before deletion; if one is found that this plan did not anticipate, STOP and report it (it may be a live consumer).

- [ ] **Step 2: Write/adjust the failing guard**

Ensure no test imports the deleted files. If `test/` references any (e.g. an old call test), delete or port it. Run `~/flutter/bin/flutter analyze lib/` BEFORE deleting to capture the baseline, then after deletion expect only "unused"/resolved-reference changes.

- [ ] **Step 3: Delete + reconcile**

```bash
cd ~/clawd/skcapstone-repos/skchat-app
git rm lib/features/calls/call_provider.dart lib/models/call_state.dart lib/services/webrtc_service.dart \
       lib/features/calls/outgoing_call_screen.dart lib/features/calls/incoming_call_screen.dart \
       lib/features/calls/in_call_screen.dart
# call_controls.dart + its test only if grep shows no remaining user:
# git rm lib/features/calls/widgets/call_controls.dart
```
In `app_router.dart`: remove the imports of the deleted screens and the `outgoingCall` / `incomingCall` / `inCall` `GoRoute`s and their `AppRoutes` path constants + helpers (`outgoingCallPath` / `incomingCallPath` / `inCallPath`) if now unused. In `app_shell.dart`: delete the `ref.listen<CallState?>(callProvider, ...)` block and its `CallState` import.

- [ ] **Step 4: Verify no dangling references**

Run:
```bash
cd ~/clawd/skcapstone-repos/skchat-app
~/flutter/bin/flutter analyze lib/
flutter test test/features/calls/ test/features/conversation/ test/features/shell/
```
Expected: analyze reports NO errors (no unresolved `CallState`/`callProvider`), and the calls/conversation/shell suites PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(calls): retire dead WebRTC path; CallSession is the single funnel"
```

---

## Task 7: Server: verify /call/* reachable through the app dataplane

**Files:**
- Investigate: `src/skchat/call_routes.py`, the webui app assembly (where `register_call_routes(app)` is called), and the dataplane auth wiring.
- Modify (only if needed): add a proxy/mount so `POST /call/start|answer` and `GET /call/incoming` are reachable at the same origin/base the Flutter client uses (`skchatWebuiUrl`), behind the same auth gate as `/livekit/token`.
- Test (if a proxy is added): `tests/` route test mirroring the existing call-route tests.

**Interfaces:** the client (Task 1) expects `POST {base}/call/start`, `POST {base}/call/answer`, `GET {base}/call/incoming` to be served by `skchatWebuiUrl`.

- [ ] **Step 1: Confirm the routes are mounted on the webui app**

```bash
cd ~/clawd/skcapstone-repos/skchat
grep -rn "register_call_routes\|/call/start\|/call/answer\|/call/incoming" src/skchat/ | head
```
Determine whether the app that serves `skchatWebuiUrl` (the same app serving `/livekit/token`) has `register_call_routes(app)` applied. The map found `/livekit/token` and `/call/*` on the webui already (the `/pair` page uses `/call/*`). If both are on the same app, NO server change is needed: record that finding and skip to Step 4.

- [ ] **Step 2: If NOT co-mounted, add a passthrough**

If `/call/*` is on a different app than the one serving `skchatWebuiUrl`, add a thin proxy on the webui app that forwards `POST /call/start|answer` and `GET /call/incoming` to the call app verbatim (mirroring the existing `/api/v1/inbox` federation proxy pattern in `daemon_proxy.py`), preserving auth headers. No call logic changes.

- [ ] **Step 3: Confirm the auth gate**

Verify `/call/*` is behind the same dataplane auth as `/livekit/token` (an unauth request 401s; the enrolled app succeeds). If `/call/*` is currently UNGATED while `/livekit/token` is gated, gate it to match (a call route must not be more open than token minting). Note the finding either way.

- [ ] **Step 4: Verify live**

Run the server call-route tests and a live check:
```bash
cd ~ && ~/.skenv/bin/python -m pytest /home/cbrd21/clawd/skcapstone-repos/skchat/tests/ -q -k "call"
```
Expected: PASS. Record whether a server change was needed (likely none) in the report.

- [ ] **Step 5: Commit (only if a change was made)**

```bash
cd ~/clawd/skcapstone-repos/skchat
git add -A && git commit -m "feat(call_routes): expose /call/* through the app dataplane for the client ring path"
```
If no change was needed, record "no server change required" and skip the commit.

---

## Task 8: Full-suite regression + docs

**Files:** `CHANGELOG.md`, `SECURITY.md` (skchat-app), `CHANGELOG.md` (skchat if Task 7 changed it).

- [ ] **Step 1: Run the full client suite**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test`
Expected: PASS except the known pre-existing 6 `space_share_sheet_test.dart` failures. Any NEW failure (esp. in calls/conversation/shell) is a regression: STOP and fix before proceeding.

- [ ] **Step 2: Run the full server suite (if Task 7 changed the server)**

Run: `cd ~ && ~/.skenv/bin/python -m pytest /home/cbrd21/clawd/skcapstone-repos/skchat/tests/ -q -m 'not integration'`
Expected: same pre-existing failures as documented (22 message-log, coord `0bef58d6`), no new ones. If Task 7 made no server change, skip.

- [ ] **Step 3: Docs**

`CHANGELOG.md` (skchat-app): `feat(calls): 1:1 calls now ring the peer (signed CALL_INVITE), are minimizable to a floating pill in-thread, and flow through one CallSession; the dead WebRTC path is retired.`
`SECURITY.md` (skchat-app): note that ringing rides the server's signed `CALL_INVITE` with the anti-spoof `from_fqid` cross-check, the 1:1 verify-before-call gate is unchanged, call media stays DTLS-SRTP, and retiring the `__CALL_REQUEST__` chat-sentinel path reduces surface area.

- [ ] **Step 4: Verify docs**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && grep -nP '[\x{2013}\x{2014}]' CHANGELOG.md SECURITY.md && echo "DASH FOUND" || echo "no dashes: OK"`
Expected: no dashes.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md SECURITY.md
git commit -m "docs: in-thread 1:1 calling (Phase 2) changelog + security note"
```

---

## Self-Review

**1. Spec coverage (Phase 2 design):**
- Ring via server CALL_INVITE -> Task 1 (CallApiClient) + Task 4 (watcher/banner) + Task 3 (startCall on outgoing). ✅
- Server-authoritative rooms (retire `sk-room-`) -> Task 3 (`_startDirectCall` rewritten) + Task 2 (join returned room/token). ✅
- One CallSession funnel -> Task 2, consumed by Tasks 3/4/5. ✅
- Minimizable pill + in-thread banner + orphaned-call fix -> Task 5. ✅
- Retire Path A -> Task 6. ✅
- Tidy app bar (one Call button, long-press video) -> Task 3. ✅
- Poll /call/incoming -> Task 4. ✅
- Trust gate unchanged -> Task 3 (reuses `canCall` + verify sheet). ✅
- Server verify/proxy -> Task 7. ✅
- Testing + regression + docs -> every task's tests + Task 8. ✅

**2. Placeholder scan:** New units carry complete code. Integration edits (Tasks 3/5/6) name exact methods/widgets and give the replacement code; the "match on content, not line numbers" convention (proven in Phase 1) applies. The two watcher tests that would need `@protected` `state` access are explicitly rewritten to use the public API (`hangUp`/`startOutgoing`) in Task 4 Step 1. Task 7 is investigate-then-maybe-change with a concrete decision gate, not a vague "handle the server."

**3. Type consistency:** `CallStartResult` / `CallInvite` fields (Task 1) are consumed with the same names in Tasks 2/4. `CallSession` methods (`startOutgoing`, `receiveIncoming`, `acceptIncoming`, `declineIncoming`, `minimize`, `restore`, `hangUp`, `toggleMic`, `toggleCamera`) and `callSessionProvider` are defined in Task 2 and used verbatim in Tasks 3/4/5. `CallSessionStatus` values match across tasks. `LiveKitCallService.connectWithToken({required String wsUrl, required String token})` / `leaveRoom()` / `setMicEnabled(bool)` / `setCameraEnabled(bool, {...})` match the real signatures read from `livekit_call_service.dart`.

**Risk flag for the implementer:** the exact `setCameraEnabled` named parameters and the `_TopBar`/hang-up wiring in `livekit_call_screen.dart` were not quoted verbatim into this plan; the implementer must read those two spots and match the real signatures (noted inline in Tasks 2 and 5).
