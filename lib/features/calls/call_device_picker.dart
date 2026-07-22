import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../core/theme/sovereign_colors.dart';
import '../../services/livekit_call_service.dart';

// ── Persistence ──────────────────────────────────────────────────────────────
//
// The explicit device choice is persisted to the shared `settings` Hive box
// (same box backend_config uses) so it survives across calls and app restarts.
// Reuse: [CallDevicePickerButton] silently reconciles the live tracks with the
// saved choice (or the smart default when none is saved) when the control bar
// first renders (i.e. once the call is live), so the user does not have to
// re-pick every call and a fresh call avoids a phantom default device.

const _kSettingsBox = 'settings';
const _kMicDeviceKey = 'call_mic_device_id';
const _kCamDeviceKey = 'call_camera_device_id';

/// Thin Hive-backed store for the persisted mic / camera device ids. Best-effort
/// throughout: a storage error must never break a live call, so reads fall back
/// to null and writes are swallowed.
class CallDevicePrefs {
  const CallDevicePrefs._();

  static Future<Box<String>> _box() => Hive.openBox<String>(_kSettingsBox);

  static Future<String?> loadMic() async {
    try {
      return (await _box()).get(_kMicDeviceKey);
    } on Object {
      return null;
    }
  }

  static Future<String?> loadCamera() async {
    try {
      return (await _box()).get(_kCamDeviceKey);
    } on Object {
      return null;
    }
  }

  static Future<void> saveMic(String deviceId) async {
    try {
      await (await _box()).put(_kMicDeviceKey, deviceId);
    } on Object {
      // Best-effort, a persistence failure must not break device switching.
    }
  }

  static Future<void> saveCamera(String deviceId) async {
    try {
      await (await _box()).put(_kCamDeviceKey, deviceId);
    } on Object {
      // Best-effort.
    }
  }
}

// ── Control-bar button ───────────────────────────────────────────────────────

/// A single, self-contained call-control-bar button that opens the camera / mic
/// device picker sheet. Kept as a distinct widget so both control bars
/// ([conf_screen] and [livekit_call_screen]) add exactly one line and this
/// change stays out of the way of the panels work touching the same bars.
///
/// On first render (which is when the call is live) it silently reconciles the
/// live tracks with the persisted choice, or, when none is saved, the smart
/// default (first non-virtual device). So a picked mic/camera is reused across
/// calls and a fresh call auto-avoids a phantom device, without the user
/// re-opening the sheet.
class CallDevicePickerButton extends ConsumerStatefulWidget {
  const CallDevicePickerButton({super.key, this.size = 52});

  /// Diameter of the round control (matches the surrounding control bar).
  final double size;

  @override
  ConsumerState<CallDevicePickerButton> createState() =>
      _CallDevicePickerButtonState();
}

class _CallDevicePickerButtonState
    extends ConsumerState<CallDevicePickerButton> {
  bool _reapplied = false;
  int _reapplyAttempts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reapplySaved());
  }

  /// Reconcile the live tracks with the persisted-or-smart-default device once
  /// the call is live (best-effort).
  ///
  /// For each input the target is the explicit saved choice when it is still
  /// present in the enumeration, otherwise the smart default (first non-virtual
  /// device) so a fresh call auto-avoids a phantom / loopback device (e.g. a
  /// dead DroidCam that happens to be the OS default) at publish time, instead
  /// of waiting for the user to open the sheet and re-pick.
  ///
  /// The control bar can mount a frame before the room finishes connecting, so
  /// [switchMicDevice] / [switchCameraDevice] would no-op on a null local
  /// participant. Defer to a later frame (bounded) until the participant exists.
  ///
  /// The mic is always published on a live call, so it is always reconciled.
  /// The camera is only reconciled when a camera track is already live, so this
  /// never forces video onto an audio-only call. Capture failures are swallowed
  /// so the rest of the call keeps working when a device has disappeared.
  Future<void> _reapplySaved() async {
    if (_reapplied) return;
    // This is re-invoked from a post-frame callback until the participant
    // exists; the widget can dispose between frames, so guard ref use.
    if (!mounted) return;
    final svc = ref.read(liveKitCallServiceProvider);
    if (svc.localParticipant == null) {
      if (!mounted || _reapplyAttempts >= 30) return;
      _reapplyAttempts++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reapplySaved());
      return;
    }
    _reapplied = true;

    final savedMic = await CallDevicePrefs.loadMic();
    try {
      final mics = await svc.enumerateAudioInputs();
      final target = _pickTarget(mics, savedMic);
      if (target != null) await svc.switchMicDevice(target);
    } on Object {
      // Saved / default mic gone or unreadable, leave the current mic running.
    }

    // Only touch the camera when it is already live: never turn video ON here.
    if (svc.localParticipant?.isCameraEnabled() ?? false) {
      final savedCam = await CallDevicePrefs.loadCamera();
      try {
        final cams = await svc.enumerateVideoInputs();
        final target = _pickTarget(cams, savedCam);
        if (target != null) await svc.switchCameraDevice(target);
      } on Object {
        // Saved / default camera gone or unreadable, leave video unaffected.
      }
    }
  }

  /// The device id to apply: the persisted [saved] choice when it is still
  /// present in [list], otherwise the smart default (first non-virtual device).
  /// Returns null for an empty enumeration. Delegates to
  /// [LiveKitCallService.resolveCameraDeviceId], which is the same
  /// saved-or-smart-default logic (named for its camera go-live use, but
  /// generic over any [MediaDevice] list, mic included).
  String? _pickTarget(List<MediaDevice> list, String? saved) =>
      LiveKitCallService.resolveCameraDeviceId(list, saved);

  Future<void> _openSheet() async {
    final svc = ref.read(liveKitCallServiceProvider);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DevicePickerSheet(service: svc),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Devices',
      child: GestureDetector(
        onTap: _openSheet,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1A1D22),
                border: Border.all(color: const Color(0xFF2A2D34), width: 1.5),
              ),
              child: const Icon(
                Icons.tune_rounded,
                color: SovereignColors.textPrimary,
                size: 22,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Devices',
              style: TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 11,
                fontFamily: 'Inter',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Picker sheet ─────────────────────────────────────────────────────────────

/// Bottom sheet with a microphone + camera dropdown. Enumerates live devices,
/// selects the persisted-or-smart-default per input, switches the active
/// published track on selection (without dropping the call), and surfaces an
/// inline message when a device fails to open.
class _DevicePickerSheet extends StatefulWidget {
  const _DevicePickerSheet({required this.service});

  final LiveKitCallService service;

  @override
  State<_DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends State<_DevicePickerSheet> {
  List<MediaDevice> _mics = const [];
  List<MediaDevice> _cams = const [];
  String? _selectedMic;
  String? _selectedCam;
  bool _loading = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final mics = await widget.service.enumerateAudioInputs();
      final cams = await widget.service.enumerateVideoInputs();
      final savedMic = await CallDevicePrefs.loadMic();
      final savedCam = await CallDevicePrefs.loadCamera();
      if (!mounted) return;
      setState(() {
        _mics = mics;
        _cams = cams;
        _selectedMic = _resolveSelection(mics, savedMic);
        _selectedCam = _resolveSelection(cams, savedCam);
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = 'Could not list devices: $e';
      });
    }
  }

  /// Persisted explicit choice wins when the device is still present, otherwise
  /// fall back to the smart default that skips virtual / loopback devices.
  /// Delegates to [LiveKitCallService.resolveCameraDeviceId] (same logic as
  /// [_CallDevicePickerButtonState._pickTarget] above; the empty-`saved`-string
  /// edge case behaves identically either way since no real device enumerates
  /// with an empty deviceId).
  String? _resolveSelection(List<MediaDevice> list, String? saved) =>
      LiveKitCallService.resolveCameraDeviceId(list, saved);

  Future<void> _onMicChanged(String? deviceId) async {
    if (deviceId == null) return;
    setState(() {
      _selectedMic = deviceId;
      _message = null;
    });
    await CallDevicePrefs.saveMic(deviceId);
    try {
      await widget.service.switchMicDevice(deviceId);
    } on Object catch (e) {
      if (mounted) setState(() => _message = _deviceError('Microphone', e));
    }
  }

  Future<void> _onCamChanged(String? deviceId) async {
    if (deviceId == null) return;
    setState(() {
      _selectedCam = deviceId;
      _message = null;
    });
    await CallDevicePrefs.saveCamera(deviceId);
    try {
      await widget.service.switchCameraDevice(deviceId);
    } on Object catch (e) {
      if (mounted) setState(() => _message = _deviceError('Camera', e));
    }
  }

  /// Friendly inline message for a capture failure. A NotFound / NotReadable
  /// (a dead loopback, or a device grabbed by another app) gets the "pick
  /// another" hint; anything else surfaces the raw reason.
  String _deviceError(String label, Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('notfound') || s.contains('notreadable')) {
      return '$label unavailable, pick another from the list';
    }
    return '$label unavailable: $e';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Devices',
            style: TextStyle(
              color: SovereignColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    color: SovereignColors.soulLumina,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            )
          else ...[
            _label('Microphone'),
            const SizedBox(height: 6),
            _deviceDropdown(
              devices: _mics,
              value: _selectedMic,
              word: 'Mic',
              onChanged: _onMicChanged,
            ),
            const SizedBox(height: 16),
            _label('Camera'),
            const SizedBox(height: 6),
            _deviceDropdown(
              devices: _cams,
              value: _selectedCam,
              word: 'Camera',
              onChanged: _onCamChanged,
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: SovereignColors.accentWarning,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _message!,
                    style: const TextStyle(
                      color: SovereignColors.accentWarning,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: SovereignColors.textTertiary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _deviceDropdown({
    required List<MediaDevice> devices,
    required String? value,
    required String word,
    required ValueChanged<String?> onChanged,
  }) {
    if (devices.isEmpty) {
      return const Text(
        'No devices found',
        style: TextStyle(
          color: SovereignColors.textSecondary,
          fontSize: 13,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D22),
        border: Border.all(color: const Color(0xFF2A2D34), width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: SovereignColors.surfaceRaised,
          iconEnabledColor: SovereignColors.textSecondary,
          style: const TextStyle(
            color: SovereignColors.textPrimary,
            fontSize: 14,
          ),
          items: [
            for (var i = 0; i < devices.length; i++)
              DropdownMenuItem<String>(
                value: devices[i].deviceId,
                child: Text(
                  devices[i].label.isNotEmpty
                      ? devices[i].label
                      : '$word ${i + 1}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
