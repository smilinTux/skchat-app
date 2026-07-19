# Spaces "Share system audio" on Linux/PipeWire (root cause of the streaming-audio echo)

## Symptom
On Linux desktop the screen-share panel shows **"No system-audio source found on
this device"**, even though PipeWire clearly exposes output monitors
(`pactl list sources short` shows `alsa_output.pci-...analog-stereo.monitor`,
`easyeffects_sink.monitor`, both RUNNING). Because no monitor is ever selected,
content audio (music/video) never captures. The only audio that reaches other
participants is the microphone, which picks up the content acoustically. That
loopback is the echo/delay the operator heard.

## Root cause: the media stack does not expose (or select) audio devices on Linux (cause B)
This is **not** an app-filter bug. It is a `flutter_webrtc` / bundled `libwebrtc`
Audio Device Module (ADM) limitation on Linux. Verified live on the .41 box
(main `7bc8388`, `flutter run -d linux`, instrumented enumeration):

Enumeration returns **zero** audio devices, input and output:

```
SYSAUD_PROBE RAW count=2
SYSAUD_PROBE raw kind=<<videoinput>>  id=<<platform:v4l2loopback_dc-000>>   label=<<Droidcam>>
SYSAUD_PROBE raw kind=<<videoinput>>  id=<<usb-0000:00:14.0-7>>            label=<<Laptop Camera>>
SYSAUD_PROBE PRE-MIC  audioinput count=0
SYSAUD_PROBE mic acquired tracks=1          <- getUserMedia(audio) DOES work (default device)
SYSAUD_PROBE POST-MIC audioinput  count=0   <- still 0, even with the ADM live
SYSAUD_PROBE POST-MIC audiooutput count=0
```

Video devices enumerate fine; audio input and audio output both come back empty.
`livekit_client`'s `Hardware.enumerateDevices()` is a thin wrapper over
`flutter_webrtc`'s `navigator.mediaDevices.enumerateDevices()`
(`hardware.dart:102`, no extra filtering), which maps to the native
`FlutterMediaStream::GetSources()` -> `audio_device_->RecordingDevices()` /
`PlayoutDevices()`. Those return 0 on this build/box, so **there is nothing for
`SystemAudioSources.monitors()` to find**. The `isMonitor` filter and the panel
are correct; the list handed to them is empty.

### The deviceId constraint is a no-op on this stack (do NOT "fix" it that way)
`getUserMedia({'audio': {'deviceId': '<monitor pulse name>'}})` does **not**
throw and returns a track, which is tempting to read as "capture by name works".
It does not. Held the by-name monitor track open for 20s and inspected which
PulseAudio source WebRTC actually attached to:

```
Source Output #3787
    Source: 997                          <- easyeffects_source == the MICROPHONE
    application.name = "WEBRTC VoiceEngine"
    media.name       = "recStream"
```

The monitor name passed as `deviceId` was
`alsa_output.pci-0000_00_1f.3.analog-stereo.monitor` (source 56), but WebRTC
captured from source **997 (the default mic)**. This matches the native
selection logic in `flutter_media_stream.cc`: it only calls
`SetRecordingDevice(i)` for an `i` whose `RecordingDeviceName(i)` matches the
requested id; with `RecordingDevices() == 0` that loop body never runs, so the
ADM stays on its default device (the mic).

**Consequence:** shipping "enumerate a monitor via pactl, then pass its name as
`deviceId`" would silently capture the mic under a "system audio" label and
recreate the exact echo. That path is a dead end and must not be taken.

## Options (real fixes, ranked)
1. **Out-of-band capture + custom track (correct, medium/large).** Capture the
   chosen monitor directly from PipeWire/PulseAudio (`pw-record` / `parec`, or
   `libpipewire`) and push the PCM into a WebRTC audio source published as a
   distinct `TrackSource.screenShareAudio`. `flutter_webrtc` on Linux does not
   currently expose a raw-PCM-to-track API, so this needs a small native plugin
   (or a livekit custom-audio-source seam). This is the only option that keeps a
   real, separate SCREEN_SHARE_AUDIO track alongside the voice mic.
2. **Patch/rebuild the bundled libwebrtc ADM (upstream-correct, heavy).** Fix
   the PulseAudio ADM so `RecordingDevices()` enumerates sources (monitors
   included) and `SetRecordingDevice`-by-name works, then the existing app path
   (`AudioCaptureOptions(deviceId: ...)`) works as designed. Requires building
   libwebrtc and shipping a custom `flutter_webrtc`.
3. **OS-level PipeWire loopback (pragmatic, no separate track).** A
   `module-loopback` from the monitor into a virtual/combined source that is the
   default WebRTC records, so the single voice track carries voice + system
   audio. Fixes "listeners hear the content" and (with headphones / muted local
   speakers) removes the acoustic echo, but it merges into the voice track
   instead of a dedicated SCREEN_SHARE_AUDIO track, and it is host config, not
   app code.

Recommended: option 1 for the product, option 3 as an immediate operator
workaround.

## Why the current UI copy is actually honest on Linux
`_loadSystemAudioSources()` correctly finds no monitors (enumeration is empty),
so "No system-audio source found on this device" is truthful here. The bug is
the platform capability, not the panel. The fix belongs in the capture layer
(options above), not in the enumeration/filter code.
