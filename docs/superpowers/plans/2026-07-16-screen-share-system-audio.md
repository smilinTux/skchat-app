# Screen-share System Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream a shared surface's system audio (e.g. Kodi) into a Space as a dedicated LiveKit `screenShareAudio` track with WebRTC processing disabled, so content audio arrives clean instead of clicking.

**Architecture:** On native Linux desktop, capture a PulseAudio `.monitor` source as its own `LocalAudioTrack` with echo cancellation, noise suppression, and auto gain control all off, and publish it as `TrackSource.screenShareAudio` tied to the screen-share lifecycle. The voice microphone path is untouched. Web keeps its existing getDisplayMedia tab-audio path; mobile does not offer the feature.

**Tech Stack:** Flutter, Riverpod, `livekit_client ^2.2.6`, `flutter_webrtc ^0.11.0`, `flutter_test` + `mocktail`.

## Global Constraints

- No em dashes or en dashes in any UI string, comment, or doc. Use commas, parentheses, or separate sentences.
- Scope is the native Linux desktop build only. Do not change the web getDisplayMedia path or add mobile capture.
- Do not modify the voice-microphone capture path (`setMicrophoneEnabled`, `switchMicDevice`) or its processing.
- Follow existing patterns: Riverpod providers, `Hardware.instance.enumerateDevices`, the `livekit_client` 2.2.6 API already in use.
- Spec: `docs/superpowers/specs/2026-07-16-screen-share-system-audio-design.md`.

## File Structure

- `lib/services/system_audio_sources.dart` (Create): pure logic to detect and auto-select PulseAudio monitor inputs from an enumerated device list, and to build the processing-off capture options. Hardware-independent, fully unit-tested.
- `lib/services/livekit_call_service.dart` (Modify): add `startScreenShareSystemAudio` / `stopScreenShareSystemAudio`, and a `hasSystemAudioSource` probe; wire start/stop into `setScreenShareEnabled`.
- `lib/features/spaces/screen_share_panel.dart` (Modify): add the "Share system audio" switch and source picker to the screen-share control.
- `lib/features/spaces/space_room_screen.dart` (Modify): plumb the system-audio choice through `toggleScreenShare`.
- `test/services/system_audio_sources_test.dart` (Create): unit tests for detection, auto-select, and capture options.
- `test/services/livekit_call_service_system_audio_test.dart` (Create): unit tests for the lifecycle bookkeeping that does not require a live room.
- `docs/superpowers/spikes/2026-07-16-native-linux-system-audio.md` (Create in Task 1): spike findings.

---

### Task 1: Spike gate, prove native Linux capture and screenShareAudio publish

**This task is a GATE. Do not start Task 2 until it passes.** It is exploratory, not TDD.

**Files:**
- Create: `docs/superpowers/spikes/2026-07-16-native-linux-system-audio.md`
- Scratch (do not commit): a throwaway branch or a temporary button in the running Linux app.

**Goal:** Resolve three unknowns on real hardware (node .41, Kodi playing):

1. Does `flutter_webrtc` native Linux honor `echoCancellation:false, noiseSuppression:false, autoGainControl:false` on a monitor-source audio track (is the received audio clean, not clicking)?
2. What is the exact `livekit_client` 2.2.6 call to publish a device-captured `LocalAudioTrack` under `TrackSource.screenShareAudio`? Candidates to test, in order:
   a. `LocalAudioTrack.create(AudioCaptureOptions(deviceId: mon, echoCancellation:false, noiseSuppression:false, autoGainControl:false))` then `localParticipant.publishAudioTrack(track, publishOptions: AudioPublishOptions(name: 'screenshare-audio'))`, and check whether the published track's `source` can be set to `TrackSource.screenShareAudio` (via a track `source` setter, a publish option, or the SDK's screen-share audio helper).
   b. If (a) cannot set the source, determine the SDK's supported path (inspect `LocalTrackPublication.source`, `AudioPublishOptions` fields, and `createScreenShareTracksWithAudio` internals in the installed `livekit_client` package).
3. Can this track coexist with a live `microphone` track, or is native limited to a single audio input?

- [ ] **Step 1: Add a temporary probe in the running Linux app**

In the running native Linux app, add a throwaway debug action that: enumerates `Hardware.instance.enumerateDevices(type: 'audioinput')`, picks the device whose `deviceId` ends with `.monitor`, creates a `LocalAudioTrack` with the processing-off `AudioCaptureOptions` from candidate 2a, publishes it, and logs the resulting `LocalTrackPublication.source` and any error.

- [ ] **Step 2: Verify received audio is clean**

With Kodi playing on .41, join the Space from a second subscriber. Confirm on the server (`journalctl --user -u livekit-server.service | grep 'mediaTrack published'`) that a track with `"source": "SCREEN_SHARE_AUDIO"` (or, if the source cannot be set, an additional audio track) is published. Capture the received audio at the subscriber and measure it: RMS well above silence and no periodic-click pattern. Confirm by ear.
Expected: clean content audio at the receiver.

- [ ] **Step 3: Test microphone coexistence**

With the system-audio track live, also enable the microphone. Record whether both audio tracks publish and carry independent audio, or whether the second capture fails or steals the first.

- [ ] **Step 4: Write the findings doc and decide**

Write `docs/superpowers/spikes/2026-07-16-native-linux-system-audio.md` recording: whether processing-off is honored, the exact confirmed publish-as-screenShareAudio call (copy the working code), and the coexistence result.
Gate: if processing-off is NOT honored, STOP and escalate to the human to switch the audio capture to approach B (raw-PCM). If it IS honored, proceed; the confirmed publish call becomes the reference for Task 3. Record the coexistence limit, if any, for Task 5's UI copy.

- [ ] **Step 5: Remove the temporary probe and commit only the findings doc**

```bash
git add docs/superpowers/spikes/2026-07-16-native-linux-system-audio.md
git commit -m "docs(spike): native Linux system-audio capture findings"
```

---

### Task 2: System-audio source detection and capture options (pure logic)

**Files:**
- Create: `lib/services/system_audio_sources.dart`
- Test: `test/services/system_audio_sources_test.dart`

**Interfaces:**
- Consumes: `MediaDevice` from `package:livekit_client/livekit_client.dart` (fields `deviceId`, `label`, `kind`).
- Produces:
  - `bool SystemAudioSources.isMonitor(MediaDevice device)`
  - `List<MediaDevice> SystemAudioSources.monitors(List<MediaDevice> devices)`
  - `MediaDevice? SystemAudioSources.autoSelect(List<MediaDevice> devices)`
  - `AudioCaptureOptions SystemAudioSources.captureOptions(String deviceId)`

- [ ] **Step 1: Write the failing test**

```dart
// test/services/system_audio_sources_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:skchat/services/system_audio_sources.dart';

MediaDevice _dev(String id, String label) =>
    MediaDevice(id, label, 'audioinput');

void main() {
  group('SystemAudioSources', () {
    test('isMonitor detects PulseAudio monitor inputs', () {
      expect(SystemAudioSources.isMonitor(
          _dev('alsa_output.pci-0000_00_1f.3.analog-stereo.monitor',
              'Monitor of Built-in Analog Stereo')), isTrue);
      expect(SystemAudioSources.isMonitor(
          _dev('alsa_input.pci-0000_00_1f.3.analog-stereo', 'Built-in Microphone')),
          isFalse);
    });

    test('monitors filters to only monitor inputs, preserving order', () {
      final list = [
        _dev('mic1', 'Built-in Microphone'),
        _dev('sink.a.monitor', 'Monitor of A'),
        _dev('sink.b.monitor', 'Monitor of B'),
      ];
      final mons = SystemAudioSources.monitors(list);
      expect(mons.map((d) => d.deviceId), ['sink.a.monitor', 'sink.b.monitor']);
    });

    test('autoSelect prefers the analog/built-in monitor', () {
      final list = [
        _dev('sink.hdmi.monitor', 'Monitor of HDMI'),
        _dev('sink.analog-stereo.monitor', 'Monitor of Built-in Analog Stereo'),
      ];
      expect(SystemAudioSources.autoSelect(list)!.deviceId,
          'sink.analog-stereo.monitor');
    });

    test('autoSelect returns null when there is no monitor', () {
      expect(SystemAudioSources.autoSelect([_dev('mic1', 'Mic')]), isNull);
    });

    test('captureOptions turns all voice processing off', () {
      final o = SystemAudioSources.captureOptions('sink.a.monitor');
      expect(o.deviceId, 'sink.a.monitor');
      expect(o.echoCancellation, isFalse);
      expect(o.noiseSuppression, isFalse);
      expect(o.autoGainControl, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/system_audio_sources_test.dart`
Expected: FAIL, `system_audio_sources.dart` does not exist.

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/services/system_audio_sources.dart
import 'package:livekit_client/livekit_client.dart';

/// Detection and capture configuration for system-audio sources.
///
/// On Linux desktop the reliable system-audio source is a PulseAudio output
/// monitor (device id ending in ".monitor", label "Monitor of ..."). This
/// helper is pure logic so it can be unit tested without hardware.
class SystemAudioSources {
  /// True when [device] is a PulseAudio output monitor input.
  static bool isMonitor(MediaDevice device) {
    final id = device.deviceId.toLowerCase();
    final label = device.label.toLowerCase();
    return id.contains('.monitor') ||
        label.contains('monitor of') ||
        label.startsWith('monitor');
  }

  /// The monitor inputs among [devices], preserving order.
  static List<MediaDevice> monitors(List<MediaDevice> devices) =>
      devices.where(isMonitor).toList(growable: false);

  /// Auto-select the best default monitor: prefer the analog / built-in output,
  /// else the first monitor, else null when none exist.
  static MediaDevice? autoSelect(List<MediaDevice> devices) {
    final mons = monitors(devices);
    if (mons.isEmpty) return null;
    for (final m in mons) {
      final s = '${m.deviceId} ${m.label}'.toLowerCase();
      if (s.contains('analog') ||
          s.contains('built-in') ||
          s.contains('speaker')) {
        return m;
      }
    }
    return mons.first;
  }

  /// Capture options for a raw system-audio track: all WebRTC voice processing
  /// off, so music and video content is not gated or pumped into artifacts.
  static AudioCaptureOptions captureOptions(String deviceId) =>
      AudioCaptureOptions(
        deviceId: deviceId,
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
      );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/services/system_audio_sources_test.dart`
Expected: PASS (5 tests). If `MediaDevice`'s constructor signature differs in the installed version, adjust the `_dev` helper in the test to match; do not change the production API.

- [ ] **Step 5: Commit**

```bash
git add lib/services/system_audio_sources.dart test/services/system_audio_sources_test.dart
git commit -m "feat(spaces): system-audio source detection + processing-off capture options"
```

---

### Task 3: Service methods to start/stop the system-audio track

**Files:**
- Modify: `lib/services/livekit_call_service.dart` (add methods near `switchMicDevice` ~line 928 and the `_screenShare*` area ~line 618; the class fields block is ~line 167)
- Test: `test/services/livekit_call_service_system_audio_test.dart`

**Interfaces:**
- Consumes: `SystemAudioSources` from Task 2; the spike's confirmed publish-as-screenShareAudio call from Task 1.
- Produces on `LiveKitCallService`:
  - `Future<bool> hasSystemAudioSource()` returns true when at least one monitor input exists.
  - `Future<MediaDevice?> defaultSystemAudioSource()` returns the auto-selected monitor or null.
  - `Future<void> startScreenShareSystemAudio(String deviceId)` creates the processing-off track and publishes it as screen-share audio; stores it in `LocalTrack? _systemAudioTrack`.
  - `Future<void> stopScreenShareSystemAudio()` unpublishes and stops `_systemAudioTrack`, then nulls it.
  - `bool get isSharingSystemAudio => _systemAudioTrack != null`.

- [ ] **Step 1: Write the failing test (bookkeeping without a live room)**

```dart
// test/services/livekit_call_service_system_audio_test.dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/livekit_call_service_system_audio_test.dart`
Expected: FAIL, the methods and getter do not exist.

- [ ] **Step 3: Write the implementation**

Add a field to the fields block (near `LocalParticipant? _localParticipant;`):

```dart
  /// The dedicated system-audio (screen-share audio) track, when publishing
  /// system audio. Kept separate from the voice mic so mic processing is
  /// untouched. Null when not sharing system audio.
  LocalTrack? _systemAudioTrack;
```

Add these methods (near `switchMicDevice`), using the publish call confirmed by the Task 1 spike. The reference implementation, to be reconciled with the spike findings:

```dart
  /// True when at least one PulseAudio monitor input is available to capture
  /// system audio (Linux desktop). Returns false on platforms without one.
  Future<bool> hasSystemAudioSource() async =>
      (await defaultSystemAudioSource()) != null;

  /// The auto-selected default system-audio source, or null when none exists.
  Future<MediaDevice?> defaultSystemAudioSource() async {
    final inputs = await Hardware.instance.enumerateDevices(type: 'audioinput');
    return SystemAudioSources.autoSelect(inputs);
  }

  bool get isSharingSystemAudio => _systemAudioTrack != null;

  /// Capture [deviceId] (a monitor source) with all voice processing off and
  /// publish it as the screen-share audio track. Best-effort: a failure here
  /// must never abort the video share, so callers wrap it. Guards when there is
  /// no room.
  Future<void> startScreenShareSystemAudio(String deviceId) async {
    final lp = _localParticipant;
    if (lp == null || _systemAudioTrack != null) return;
    final track = await LocalAudioTrack.create(
      SystemAudioSources.captureOptions(deviceId),
    );
    // Publish as screen-share audio per the Task 1 spike's confirmed call.
    await lp.publishAudioTrack(
      track,
      publishOptions: const AudioPublishOptions(
        name: 'screenshare-audio',
        stream: 'screenshare',
      ),
    );
    _systemAudioTrack = track;
    _emitParticipants();
  }

  /// Unpublish and stop the system-audio track only. Safe no-op when not sharing.
  Future<void> stopScreenShareSystemAudio() async {
    final track = _systemAudioTrack;
    _systemAudioTrack = null;
    if (track == null) return;
    try {
      await _localParticipant?.removePublishedTrack(track.sid ?? '');
    } catch (_) {}
    try {
      await track.stop();
    } catch (_) {}
    _emitParticipants();
  }
```

Note for the implementer: the exact publish call (setting `TrackSource.screenShareAudio`) and the exact unpublish call (`removePublishedTrack` vs `unpublishTrack`) MUST match the Task 1 spike findings and the installed `livekit_client` 2.2.6 API. Adjust the two calls above to the spike's confirmed code; keep the method names, the guard, and the `_systemAudioTrack` bookkeeping exactly as written so tests and later tasks hold.

Ensure `SystemAudioSources` is imported at the top of the file:

```dart
import 'system_audio_sources.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/services/livekit_call_service_system_audio_test.dart`
Expected: PASS (3 tests). Also run `flutter analyze lib/services/livekit_call_service.dart` and confirm no new errors.

- [ ] **Step 5: Commit**

```bash
git add lib/services/livekit_call_service.dart test/services/livekit_call_service_system_audio_test.dart
git commit -m "feat(spaces): start/stop dedicated system-audio track (processing off)"
```

---

### Task 4: Wire system audio into the screen-share lifecycle

**Files:**
- Modify: `lib/services/livekit_call_service.dart` (`setScreenShareEnabled` ~line 618)
- Modify: `lib/features/spaces/space_room_screen.dart` (`toggleScreenShare` ~line 127)

**Interfaces:**
- Consumes: `startScreenShareSystemAudio`, `stopScreenShareSystemAudio` from Task 3.
- Produces: `setScreenShareEnabled(bool enabled, {bool withAudio, String? systemAudioDeviceId})`; `toggleScreenShare(bool enabled, {String? systemAudioDeviceId})`.

- [ ] **Step 1: Extend `setScreenShareEnabled`**

Change the signature and body so that when disabling, the system-audio track is stopped, and when enabling with a `systemAudioDeviceId`, it is started after the video publishes (best-effort, never aborts the video share):

```dart
  Future<void> setScreenShareEnabled(bool enabled,
      {bool withAudio = true, String? systemAudioDeviceId}) async {
    final lp = _localParticipant;
    if (lp == null) return;

    if (!enabled) {
      await stopScreenShareSystemAudio();
      await lp.setScreenShareEnabled(false);
      _emitParticipants();
      return;
    }
    // ... existing capture + publishVideoTrack logic unchanged ...
    // After the existing publish loop, before the trailing _emitParticipants():
    if (systemAudioDeviceId != null) {
      try {
        await startScreenShareSystemAudio(systemAudioDeviceId);
      } catch (e) {
        // Best-effort: keep the video share alive if system audio fails.
      }
    }
    _emitParticipants();
  }
```

- [ ] **Step 2: Thread the choice through `toggleScreenShare`**

In `space_room_screen.dart`:

```dart
  Future<void> toggleScreenShare(bool enabled, {String? systemAudioDeviceId}) async {
    await ref.read(liveKitCallServiceProvider).setScreenShareEnabled(
          enabled,
          systemAudioDeviceId: systemAudioDeviceId,
        );
  }
```

- [ ] **Step 3: Run analyzer + existing tests**

Run: `flutter analyze lib/services/livekit_call_service.dart lib/features/spaces/space_room_screen.dart`
Run: `flutter test test/services/`
Expected: no new analyzer errors; existing service tests still pass.

- [ ] **Step 4: Commit**

```bash
git add lib/services/livekit_call_service.dart lib/features/spaces/space_room_screen.dart
git commit -m "feat(spaces): tie system-audio track to the screen-share lifecycle"
```

---

### Task 5: UI, the "Share system audio" switch and source picker

**Files:**
- Modify: `lib/features/spaces/screen_share_panel.dart`

**Interfaces:**
- Consumes: `hasSystemAudioSource`, `defaultSystemAudioSource`, `SystemAudioSources.monitors`, and the extended `setScreenShareEnabled` / `toggleScreenShare`.

- [ ] **Step 1: Add state and load sources**

In `_ScreenSharePanelState`, add `bool _shareSystemAudio = true;`, `String? _systemAudioDeviceId;`, `List<MediaDevice> _monitors = const [];`, and in `initState`/a load method call `Hardware.instance.enumerateDevices(type: 'audioinput')`, set `_monitors = SystemAudioSources.monitors(list)`, and default `_systemAudioDeviceId = SystemAudioSources.autoSelect(list)?.deviceId`.

- [ ] **Step 2: Render the switch + picker**

Above the existing share toggle, add a `SwitchListTile` labeled "Share system audio" bound to `_shareSystemAudio`, and when on and `_monitors.length > 1`, a `DropdownButton<String>` of `_monitors` (value `deviceId`, text from `label`) bound to `_systemAudioDeviceId`. When `_monitors.isEmpty`, disable the switch and show the hint text "No system-audio source found on this device." (no dashes).

- [ ] **Step 3: Pass the choice on share**

In `_toggleShare`, pass `systemAudioDeviceId: (_shareSystemAudio && next) ? _systemAudioDeviceId : null` into `setScreenShareEnabled`.

- [ ] **Step 4: Analyze**

Run: `flutter analyze lib/features/spaces/screen_share_panel.dart`
Expected: no new errors. (This widget is verified live in Task 7; no widget test is required for the picker wiring.)

- [ ] **Step 5: Commit**

```bash
git add lib/features/spaces/screen_share_panel.dart
git commit -m "feat(spaces): Share system audio switch + monitor-source picker"
```

---

### Task 6: Receiver playback check and retire the mic-monitor hint

**Files:**
- Modify: `lib/services/livekit_call_service.dart` and/or track-render logic (only if it filters audio by source)
- Modify: any UI string instructing users to set their mic to a monitor source (search the repo)

- [ ] **Step 1: Confirm remote screen-share audio plays**

Search for any place that filters or attaches audio by `TrackSource` (`grep -rn "TrackSource" lib/`). LiveKit auto-plays subscribed audio tracks, so no change is expected. If a filter excludes `screenShareAudio`, include it. If nothing filters audio, make no change and note it in the commit body.

- [ ] **Step 2: Remove the stale mic-monitor guidance**

Search: `grep -rniE "monitor of|monitor source|pick a monitor|system audio.*mic" lib/`. Rewrite or remove any instruction telling users to set their microphone to a monitor source, since the dedicated path supersedes it. Keep copy dash-free.

- [ ] **Step 3: Analyze + commit**

Run: `flutter analyze lib/`
Expected: no new errors.

```bash
git add -A
git commit -m "chore(spaces): retire mic-monitor hint; confirm screenShareAudio playback"
```

---

### Task 7: Build, deploy to .41, and manual E2E verification

**Files:** none (build + verify)

- [ ] **Step 1: Full analyze + test**

Run: `flutter analyze` and `flutter test`
Expected: clean analyze; all tests pass.

- [ ] **Step 2: Build and relaunch on .41**

Build the native Linux app per `scripts/launch-linux.sh` and relaunch it on .41.

- [ ] **Step 3: E2E with Kodi**

Play a video with sound in Kodi on .41. Share the screen in a Space with "Share system audio" on. From a second subscriber, confirm via `journalctl --user -u livekit-server.service | grep 'mediaTrack published'` that a `"source": "SCREEN_SHARE_AUDIO"` track publishes, and confirm the received audio is clean (measure RMS on a second-subscriber capture and confirm by ear that there is no clicking).

- [ ] **Step 4: Confirm the mic is untouched**

Verify a normal voice call still applies echo cancellation and noise suppression (voice quality unchanged).

- [ ] **Step 5: Update the coord issue**

Mark coord task `cf4c4344` resolved with a note pointing at the shipped fix and this plan.
