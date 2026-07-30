import 'package:flutter_riverpod/flutter_riverpod.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// App feature flags.
/// ─────────────────────────────────────────────────────────────────────────
///
/// Small, explicit toggles that flip which implementation an app surface uses,
/// kept off by default so nothing changes unless a flag is deliberately turned
/// on (at build time via `--dart-define`, or in a test via a provider override).

/// Compile-time default for [useSkchatModuleForChatsTabProvider].
///
/// When true, the Chats tab renders the mounted `skchat_ui` module (the same
/// mount path as [SkchatModuleHostScreen]) instead of the bespoke native
/// [ChatsScreen]. DEFAULT FALSE: the native screen stays the default/fallback.
///
/// Flip it at build time with:
///   `flutter run --dart-define=USE_SKCHAT_MODULE_CHATS_TAB=true`
const bool kUseSkchatModuleForChatsTabDefault =
    bool.fromEnvironment('USE_SKCHAT_MODULE_CHATS_TAB', defaultValue: false);

/// Whether the Chats tab renders the mounted skchat_ui module (true) or the
/// native [ChatsScreen] (false, the default/fallback).
///
/// Seeded from the compile-time [kUseSkchatModuleForChatsTabDefault] so a build
/// can preset it, while staying a Riverpod provider so a test (or a future
/// Modules-settings toggle) can override it at runtime without a rebuild. The
/// native screen is never deleted, this only flips which one the tab shows.
final useSkchatModuleForChatsTabProvider =
    Provider<bool>((ref) => kUseSkchatModuleForChatsTabDefault);
