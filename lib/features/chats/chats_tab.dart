import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/feature_flags.dart';
import '../shell/module_host_screen.dart';
import 'chats_screen.dart';

/// What the primary Chats tab renders, chosen by a flag.
///
/// This is the single switch behind the Chats destination: it watches
/// [useSkchatModuleForChatsTabProvider] and renders EITHER
///   * the mounted `skchat_ui` module (flag ON) via [SkchatModuleHostScreen],
///     the exact same mount path (concrete `AppShellContext` + `AppShellBus`)
///     used by the `/module/skchat` host route, reused here rather than
///     duplicated, or
///   * the bespoke native [ChatsScreen] (flag OFF, the default/fallback).
///
/// Because it renders inside the shell's `ShellRoute` subtree, the module's
/// `AppShellBus.navigate` resolves `context.go` against the shell's own
/// GoRouter, so a tapped row / the compose FAB deep-link drives the real Chats
/// routes (`/chats/:peerId`, `/chats/new`) exactly as the native screen does.
/// The flag defaults false, so by default the tab renders [ChatsScreen]
/// unchanged and the module path stays dark.
class ChatsTab extends ConsumerWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useModule = ref.watch(useSkchatModuleForChatsTabProvider);
    return useModule
        ? const SkchatModuleHostScreen()
        : const ChatsScreen();
  }
}
