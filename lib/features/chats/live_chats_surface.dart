import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skchat_ui/skchat_ui.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'chats_provider.dart';

/// App-side adapter that bridges the REAL Riverpod [chatsProvider] into the pure
/// [ChatsSurface] living in the `skchat_ui` package (spec 3.2).
///
/// The import gate forbids `skchat_ui` from importing the app's service /
/// Riverpod graph, so the live feed is injected from the app side instead of
/// pulled in from the package. This `ConsumerWidget` is that seam: it
/// `ref.watch`es `chatsProvider` (Hive-backed, hydrated live from the
/// skcomms_client daemon) and hands the resulting `List<Conversation>` to
/// [ChatsSurface].
///
/// Because it is a ConsumerWidget, this is a genuinely LIVE feed: every change
/// to the conversation list (a new message, an unread bump, a delivery-status
/// or typing transition, a fresh daemon load) rebuilds this widget and
/// re-injects the current list into [ChatsSurface]. The package only ever sees
/// a plain immutable list; the reactivity lives here in the watcher.
class LiveChatsSurface extends ConsumerWidget {
  const LiveChatsSurface({super.key, this.shell});

  /// The shell surfaces when this module is mounted, or null in standalone mode.
  /// Passed straight through to [ChatsSurface] for the theme bridge + nav bus.
  final ShellContext? shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(chatsProvider);
    // A populated list renders the real rows; an empty list renders the empty
    // state. We always pass a non-null list (never null), so the sample is only
    // ever seen in standalone/unwired mode, never here.
    return ChatsSurface(shell: shell, conversations: conversations);
  }
}

/// Builds the mountable skchat module wired to the LIVE conversation feed.
///
/// This is the app-side factory the shell mounts (spec 3.2): it constructs
/// [SkchatModule] with a [bodyBuilder] that returns a [LiveChatsSurface], so the
/// module renders real conversations from `chatsProvider` while the package
/// itself stays pure. Standalone / test callers that use `const SkchatModule()`
/// directly still get the sample-backed surface.
SkchatModule buildLiveSkchatModule() => SkchatModule(
      bodyBuilder: (context, shell) => LiveChatsSurface(shell: shell),
    );
