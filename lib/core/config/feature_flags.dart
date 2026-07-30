import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// App feature flags.
/// ─────────────────────────────────────────────────────────────────────────
///
/// Small, explicit toggles that flip which implementation an app surface uses,
/// kept off by default so nothing changes unless a flag is deliberately turned
/// on (at build time via `--dart-define`, in a test via a provider override, or
/// at runtime via the Modules settings screen, persisted in Hive).

/// Compile-time default for [useSkchatModuleForChatsTabProvider].
///
/// When true, the Chats tab renders the mounted `skchat_ui` module (the same
/// mount path as [SkchatModuleHostScreen]) instead of the bespoke native
/// [ChatsScreen]. DEFAULT FALSE: the native screen stays the default/fallback.
///
/// This is only the *seed*: it sets the value when nothing is persisted yet.
/// A user toggle (persisted below) overrides it at runtime.
///
/// Flip the seed at build time with:
///   `flutter run --dart-define=USE_SKCHAT_MODULE_CHATS_TAB=true`
const bool kUseSkchatModuleForChatsTabDefault =
    bool.fromEnvironment('USE_SKCHAT_MODULE_CHATS_TAB', defaultValue: false);

/// Hive box + key used to persist the runtime override of the Chats-tab module
/// flag. A dedicated box (not the typed `settings` box) so there is no
/// open-with-a-different-type collision with other settings notifiers.
const _kFeatureFlagsBox = 'feature_flags';
const _kUseSkchatModuleChatsTabKey = 'use_skchat_module_chats_tab';

/// Runtime, persisted holder for the Chats-tab module flag.
///
/// Seeded synchronously from the compile-time [kUseSkchatModuleForChatsTabDefault]
/// so the value is correct on the very first frame, then asynchronously
/// reconciled with any persisted override the user has set. Writes go straight
/// back to Hive, so a flip survives app restarts / web reloads.
///
/// When nothing is persisted, the compile-time default is the fallback, so an
/// untouched install behaves exactly as before this toggle landed.
class ChatsTabModuleFlagNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Seed from the compile-time default now; load any persisted override
    // asynchronously (Hive may not be open yet on first build).
    _loadPersisted();
    return kUseSkchatModuleForChatsTabDefault;
  }

  Future<void> _loadPersisted() async {
    try {
      final box = await Hive.openBox<dynamic>(_kFeatureFlagsBox);
      final saved = box.get(_kUseSkchatModuleChatsTabKey);
      if (saved is bool && saved != state) state = saved;
    } catch (_) {
      // Hive unavailable, keep the compile-time default.
    }
  }

  /// Set the flag and persist it so the choice survives restarts.
  Future<void> set(bool value) async {
    state = value;
    try {
      final box = await Hive.openBox<dynamic>(_kFeatureFlagsBox);
      await box.put(_kUseSkchatModuleChatsTabKey, value);
    } catch (_) {
      // Best-effort persistence; in-memory state already updated.
    }
  }

  /// Clear the persisted override; the next read falls back to the compile-time
  /// default.
  Future<void> reset() async {
    state = kUseSkchatModuleForChatsTabDefault;
    try {
      final box = await Hive.openBox<dynamic>(_kFeatureFlagsBox);
      await box.delete(_kUseSkchatModuleChatsTabKey);
    } catch (_) {
      // best-effort
    }
  }
}

/// The persisted Chats-tab module flag. Watch/read this from the settings UI to
/// flip it; the value survives restarts. Defaults to
/// [kUseSkchatModuleForChatsTabDefault] until the user changes it.
final chatsTabModuleFlagProvider =
    NotifierProvider<ChatsTabModuleFlagNotifier, bool>(
  ChatsTabModuleFlagNotifier.new,
);

/// Whether the Chats tab renders the mounted skchat_ui module (true) or the
/// native [ChatsScreen] (false, the default/fallback).
///
/// A thin read-only view over [chatsTabModuleFlagProvider], kept as a plain
/// `Provider<bool>` so existing consumers ([ChatsTab]) and test overrides
/// (`overrideWithValue`) keep working unchanged. The native screen is never
/// deleted, this only flips which one the tab shows.
final useSkchatModuleForChatsTabProvider =
    Provider<bool>((ref) => ref.watch(chatsTabModuleFlagProvider));
