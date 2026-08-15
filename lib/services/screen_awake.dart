import "package:wakelock_plus/wakelock_plus.dart";

/// Holds the screen awake while at least one room is connected.
///
/// Chef, after sitting in a Space: "is there a way to force keep the screen
/// on?" A watch party is the one thing a phone's idle timer gets exactly
/// wrong: you are watching, so you are not touching, so the OS decides you are
/// away and blanks the screen mid-scene.
///
/// REFCOUNTED, not a boolean. A 1:1 call can be answered from inside a Space,
/// and a plain `disable()` on either teardown would blank the screen while the
/// other is still running. Only the last release actually drops the lock.
///
/// EVERY operation is best-effort. Browsers gate the Screen Wake Lock API on a
/// secure context and can refuse or silently drop it, and desktop platforms may
/// have no implementation at all. Keeping a screen awake is a convenience;
/// failing to do it must never take a call down with it, so nothing here
/// rethrows.
///
/// The web half survives the exact case that prompted this: the Screen Wake
/// Lock API releases the lock whenever the document becomes hidden, so a screen
/// that blanks (or a tab that backgrounds) loses it. The vendored `no_sleep.js`
/// behind `wakelock_plus` listens for `visibilitychange` and re-requests when
/// the page comes back, so returning to the tab restores the lock rather than
/// leaving it quietly off, which is the failure that would look identical to
/// working.
class ScreenAwake {
  ScreenAwake({ScreenAwakeBackend? backend})
      : _backend = backend ?? const WakelockPlusBackend();

  final ScreenAwakeBackend _backend;

  int _holders = 0;

  /// Rooms currently asking for the screen to stay awake.
  int get holders => _holders;

  /// Take a hold. The first one turns the lock on.
  Future<void> acquire() async {
    _holders++;
    if (_holders != 1) return;
    try {
      await _backend.toggle(true);
    } on Object {
      // Refused, unsupported, or insecure context: the room keeps working and
      // the screen simply dims as it always did.
    }
  }

  /// Drop a hold. The last one turns the lock off.
  ///
  /// Clamped at zero so an unbalanced release (a teardown path that runs twice,
  /// which is exactly what a disconnect racing a manual leave produces) cannot
  /// drive the count negative and leave the NEXT acquire unable to reach 1.
  Future<void> release() async {
    if (_holders == 0) return;
    _holders--;
    if (_holders != 0) return;
    try {
      await _backend.toggle(false);
    } on Object {
      // Best-effort, same as acquire.
    }
  }
}

/// Seam over the plugin so a test can assert the lock is taken and dropped
/// without a platform channel (which is unimplemented under `flutter test` and
/// would throw MissingPluginException).
abstract class ScreenAwakeBackend {
  Future<void> toggle(bool enable);
}

class WakelockPlusBackend implements ScreenAwakeBackend {
  const WakelockPlusBackend();

  @override
  Future<void> toggle(bool enable) => WakelockPlus.toggle(enable: enable);
}
