# Spaces "Share system audio" on Linux/PipeWire (root cause of the streaming-audio echo)

## Resolution (SHIPPED, skchat-app v1.2.0, 2026-07-19)
**Option 1 below was implemented and is live.** A PulseAudio/PipeWire monitor
capturer now records the default sink's `.monitor` and publishes it as a
distinct `TrackSource.screenShareAudio` track, decoupled from the microphone
(muting the mic leaves the content playing). It is implemented in the Linux
side of a vendored `flutter_webrtc` fork
(`linux/pulse_loopback_capturer.{h,cc}`, wired through
`CreateLoopbackCapturer` + `getDisplayMedia({audio:true})`), pinned in
`pubspec.yaml` `dependency_overrides`, and proposed upstream as
**flutter-webrtc/flutter-webrtc#2115**. Requires the `libpulse` runtime at
build time; without it the plugin still builds and simply yields no
system-audio track.

Live-verified on `.41`: a screen share produced a PulseAudio source-output
`application.name="flutter_webrtc"`, `media.name="System audio loopback"` bound
to `alsa_output.pci-...analog-stereo.monitor` (the monitor, NOT the mic).

This capturer is **desktop-native only**. Browser (web app) screen-share audio
is handled entirely by the browser's own `getDisplayMedia` and varies by
engine/OS; see the platform/browser support matrix in the server repo
`docs/SPACES.md` §2.16. The analysis below is retained as the historical root
cause.

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
> **Chosen + shipped: option 1** (see Resolution at top). Options 2 and 3 are
> retained for context and were not needed.

1. **Out-of-band capture + custom track (correct, medium/large). [IMPLEMENTED]** Capture the
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

---

# Addendum: the WEB path on Linux (2026-08-08)

The analysis above is about the NATIVE Linux app. The same symptom (listeners
hear the microphone, with the content bleeding in acoustically and out of sync)
also occurs in the BROWSER, for an unrelated reason. Keep the two apart.

## Evidence (Brave 150 on .41, captured live)

`pactl list source-outputs` during a Spaces screen share showed exactly ONE
capture stream:

    Source Output #693  Source: 87 (easyeffects_source)
      application.name = "Brave input"

That is the microphone. No monitor was being captured, so no content track
existed at all; Kodi reached listeners only as acoustic bleed into the mic.

`navigator.mediaDevices.enumerateDevices()` evaluated over CDP in the Spaces
page returned:

    Default | Built-in Audio Analog Stereo | Loopback Analog Stereo | Easy Effects Source

## Root cause

Two independent reasons `SystemAudioSources.monitors()` is always empty on web:

1. Chromium filters PulseAudio monitor sources out of `enumerateDevices`, so no
   "Monitor of ..." device is ever offered.
2. Web deviceIds are hashed opaque strings, so `deviceId.endsWith('.monitor')`
   is structurally unsatisfiable regardless.

So `autoSelect()` returned null, the panel passed `systemAudioDeviceId: null`,
and `startScreenShareSystemAudio` never ran. The "Share system audio" toggle was
inert on web. `getDisplayMedia({audio: true})` does not fill the gap either: on
Linux the portal supplies no audio track for a window/screen capture (Chromium
offers audio for tab captures only).

## Fix

Unlike native, web DOES honour `AudioCaptureOptions.deviceId`. What it needs is
a device it can actually see, so `SystemAudioSources` gained
`isLoopbackCapture` / `candidates`: an snd-aloop input or a PipeWire virtual
source is a plain input device to the browser, so it is listed and capturable.

Detection is a strict ALLOWLIST of loopback tokens, never a microphone
denylist. The physical mic on .41 is labelled "Built-in Audio Analog Stereo" and
carries no mic-ish token, so a denylist would eventually classify a microphone
as system audio and recreate the bug. Note that the pre-existing `autoSelect`
preference for `analog` / `built-in` / `speaker` applies ONLY among monitors for
exactly this reason.

## Host setup on .41 (`~/.local/bin/kodi-cast-up.sh`, unit `kodi-cast.service`)

    everything else -> easyeffects_sink -> EQ/convolver -> analog speakers
    Kodi ---------->  aloop sink (hw:Loopback,0)
                        |-> hw:Loopback,1 -> "Kodi-Cast-Loopback"  [browser captures this]
                        \-> monitor -> loopback -> speakers        [Chef still hears it]

Three traps found the hard way, all verified by measurement:

* **EasyEffects force-moves every output stream** into `easyeffects_sink` and
  emits one mix, so nothing downstream of it can be separated per app. Kodi has
  to be excluded. EasyEffects 8 keeps that in a KDE-style INI at
  `~/.config/easyeffects/db/easyeffectsrc` (`[StreamOutputs] blocklist=Kodi`);
  the `/com/github/wwmm/easyeffects/` dconf tree is dead EasyEffects 7 leftovers
  and writing to it silently does nothing.
* **snd-aloop pairs playback on device 0 with capture on device 1.** PipeWire's
  card profile puts BOTH its sink and its input on `front:0`, so the profile's
  own input ("Loopback Analog Stereo") is permanently silent: measured rms 0.0
  against a full-scale 440 Hz tone on the sink. The cast source must be a
  separate `module-alsa-source` bound to `hw:Loopback,1,0`. The profile is set
  to `output:analog-stereo` so the silent input is not even offered, since it
  would otherwise match the loopback heuristic and produce a share that looks
  correct and is silent.
* **PipeWire's `pactl` truncates module property values at the first
  whitespace**, quoted or not. `node.description=Kodi Cast (Virtual Source)`
  became "Kodi". The description is space-free (`Kodi-Cast-Loopback`) because on
  web the label is the only thing the app can match on.

Verification that the path carries audio, not just that the graph looks right:

    kodi_cast_loopback (hw:Loopback,1,0)   rms=8484.8  peak=12000  -> AUDIO PRESENT
    Loopback Analog Stereo (device 0)      rms=   0.0  peak=0      -> SILENCE
    easyeffects_source (mic)               rms=1108.0  peak=3509   -> separate

## Still true after this fix

The microphone remains an independent track (the DECOUPLE design). Sharing
content does not mute it, so for a broadcast the mic still has to be muted by
hand. That is deliberate, not a regression.
