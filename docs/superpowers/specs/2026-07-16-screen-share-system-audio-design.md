# Screen-share System Audio (dedicated ScreenShareAudio track) Design

**Date:** 2026-07-16
**Component:** skchat-app (Flutter)
**Status:** Approved, pending implementation

## Goal

When a user shares their screen or a video (e.g. Kodi) in a Space, the shared
surface's audio must stream to viewers as clean audio. Today it does not: the
shared video's audio is either absent or arrives as repetitive clicking.

## Background and confirmed root cause

Root cause was diagnosed with live evidence on node .41 (a native Linux desktop
running the app):

- The LiveKit server received only two tracks from the sharer: a `SCREEN_SHARE`
  video track (VP8) and a `MICROPHONE` audio track (Opus). There was **no**
  `SCREEN_SHARE_AUDIO` track. The app's `setScreenShareEnabled`
  (`lib/services/livekit_call_service.dart`) calls
  `createScreenShareTracksWithAudio`, but on Linux desktop `getDisplayMedia`
  system audio is unreliable and it falls back to video-only, so no
  screen-share audio track is ever published.
- To get any audio out, the user routed system audio through the microphone
  (the PulseAudio default source on .41 is already
  `alsa_output.pci-0000_00_1f.3.analog-stereo.monitor`, a monitor of the output
  sink). Measured directly, that monitor carries the clean Kodi audio (RMS ~6000
  while playing; a test tone loopback captured cleanly at RMS ~8000).
- The app publishes the mic with LiveKit's default `AudioCaptureOptions`, which
  enable `echoCancellation`, `noiseSuppression`, and `autoGainControl`. Those are
  built for a human voice. Applied to music/video content they gate and pump the
  signal into artifacts, which is the "clicking" the receiver hears. `RoomOptions`
  in `livekit_call_service.dart` sets `defaultAudioPublishOptions` but **no**
  `defaultAudioCaptureOptions`, so the destructive processing is on by default.
- The web client (`skchat/src/skchat/static/livekit.html`) explicitly sets
  `echoCancellation:false, noiseSuppression:false, autoGainControl:false` on its
  share audio and publishes it as `Track.Source.ScreenShareAudio`, which is why
  the web path works.

So the fault is WebRTC voice-processing destroying content audio, not a codec or
sample-rate problem (everything is a consistent 48 kHz).

## Scope

- **In scope:** the native Linux desktop app (the platform the user shares from).
  A dedicated system-audio capture path from a PulseAudio `.monitor` source,
  published as a `screenShareAudio` track with WebRTC processing disabled, tied
  to the screen-share lifecycle. The real voice microphone stays a separate,
  voice-optimized concern and is not modified.
- **Unchanged:** the web build keeps its existing, working getDisplayMedia
  tab-audio path.
- **Out of scope:** mobile (Android/iOS) system-audio capture. No reliable
  system-audio source exists there; the switch is simply not offered.

## Chosen approach: A (getUserMedia on the monitor source, processing off)

Extend the existing device enumeration (`lib/features/calls/call_device_picker.dart`)
to expose PulseAudio `.monitor` sources, create a dedicated `LocalAudioTrack`
from the chosen monitor with `echoCancellation/noiseSuppression/autoGainControl`
set false, and publish it as `Track.Source.screenShareAudio`, started and stopped
with the screen share. This is the closest analogue to the proven web pattern and
the smallest change; it reuses the app's existing device-picker infrastructure.

Rejected alternatives:

- **B, raw-PCM bypass** (a native Linux plugin captures the monitor's PCM and
  feeds a custom audio source, bypassing libwebrtc's processing entirely):
  guaranteed clean but far more native code to write and maintain. Kept as the
  fallback if the spike shows A cannot get clean audio on native.
- **C, disable the global audio processing while sharing:** simplest code, but it
  degrades real voice calls (echo/feedback) and is a blunt instrument. Rejected.

## Central risk and the spike gate (Task 0)

On native libwebrtc there is historically a single audio input pipeline with a
global audio processing module, so two things are unproven until tested:

1. whether flutter_webrtc on Linux honors per-track "processing off", and
2. whether a system-audio track can coexist with a real voice-mic track.

**Task 0 is a gate.** On .41 with Kodi playing, create a monitor-source audio
track with processing off and publish it as `screenShareAudio`, then verify the
received audio is clean. Nothing else is built until this passes.

- **Pass criteria:** a second subscriber receives a `SCREEN_SHARE_AUDIO` track
  whose decoded audio matches the source (high RMS, no periodic click pattern),
  confirmed both by measurement and by the operator's ear test.
- **Fail path:** if native does not honor processing-off, switch the capture
  implementation to approach B for the audio track only; the rest of the design
  (enumeration, lifecycle, UI) is unchanged.
- **Coexistence:** if the spike shows a voice mic and a system-audio track cannot
  be captured simultaneously on native, the primary case (system audio only)
  still ships; simultaneous voice narration is documented as a known limit.

## Components

All paths are in `skchat-app` unless noted.

1. **Monitor-source enumeration** (`lib/features/calls/call_device_picker.dart`
   plus a small helper): from `enumerateDevices`, identify audio inputs that are
   PulseAudio monitors (name/label contains "monitor", or the platform marks them
   as output monitors) and expose them as selectable "System audio" sources.
   Provide an auto-select that picks the monitor of the current default output.

2. **Capture, publish, and lifecycle** (`lib/services/livekit_call_service.dart`):
   - `startScreenShareAudio(String? deviceId)`: build a `LocalAudioTrack` with
     `AudioCaptureOptions(deviceId: <monitor>, echoCancellation: false,
     noiseSuppression: false, autoGainControl: false)` and publish it with
     `AudioPublishOptions(source: TrackSource.screenShareAudio, ...)`.
   - `stopScreenShareAudio()`: unpublish and stop that track only.
   - Wire both into the screen-share toggle so the system-audio track starts when
     the share starts (with system audio enabled) and stops when the share stops.
   - The voice-mic path (`setMicrophoneEnabled`) is untouched.

3. **UI** (`lib/features/spaces/space_room_screen.dart` and
   `lib/features/spaces/screen_share_panel.dart`): a "Share system audio" switch
   in the screen-share control plus a source picker (extends
   `call_device_picker.dart`), defaulting to auto-detect. When no monitor source
   exists, the switch is disabled with an explanatory hint.

4. **Receiver playback** (`lib/services/livekit_call_service.dart` and any track
   render/filter logic): confirm a remote `screenShareAudio` track is
   auto-subscribed and played. A standard audio track should already play; if the
   app filters audio tracks by source anywhere, include `screenShareAudio`.

5. **Retire the mic-monitor hint**: remove or rewrite any UX that instructs the
   user to set their microphone to a monitor source, since the dedicated path
   supersedes it.

## Data flow

User starts screen share in a Space with "Share system audio" on. The app
auto-selects (or the user picks) a PulseAudio monitor source, creates a raw
processing-off audio track from it, and publishes it as `screenShareAudio`
alongside the existing `SCREEN_SHARE` video track. LiveKit routes both to viewers;
the video renders and the system audio plays cleanly. The user's voice mic, if
enabled, remains a separate `MICROPHONE` track with normal voice processing.

## Error handling

- No monitor source found: disable the switch, show a short hint.
- Track creation or publish fails: surface a visible error (consistent with the
  existing screen-share publish diagnostics) but never abort the video share.
- Share stop or room leave: always unpublish and stop the system-audio track.

## Testing strategy

- **Unit tests** (hardware-independent): monitor-source detection and filtering,
  auto-select of the default output's monitor, the capture-options builder
  (asserts processing flags are all false and the publish source is
  `screenShareAudio`), and the start/stop lifecycle (a stopped share leaves no
  system-audio track).
- **Manual E2E** on .41: the operator shares Kodi to a second viewer and confirms
  clean audio by ear. Automated support: server-side confirmation via LiveKit
  logs that a `SCREEN_SHARE_AUDIO` track is now published, and an optional
  second-subscriber capture that measures received-audio RMS and checks for the
  absence of the periodic-click pattern.

## Deploy

Native Linux build (`flutter build linux` via `scripts/launch-linux.sh` flow) and
relaunch on .41. The web build is unaffected; rebuild it only if shared UI files
change.

## Global constraints

- No em dashes or en dashes in any UI string, comment, or doc (the repo has a
  standing dashsweep convention). Use commas, parentheses, or separate sentences.
- Follow existing app patterns: Riverpod providers, the existing device-picker
  and screen-share control structure, and the `livekit_client` 2.2.6 /
  `flutter_webrtc` 0.11.0 APIs already in `pubspec.yaml`.
- Do not modify the voice-microphone capture path or its processing.
