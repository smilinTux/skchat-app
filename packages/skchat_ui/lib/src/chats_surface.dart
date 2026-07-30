import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

/// The initial body [SkchatModule.build] renders inside the shell (and
/// standalone).
///
/// BOUNDED-INCREMENT NOTE (reconciled spec 3.2 step 2): the real chats surface
/// is `lib/features/chats/chats_screen.dart` in the app. It cannot move into
/// this package yet because it is entangled with `lib/core` (router, theme),
/// `lib/models`, `lib/services` (skcomms_client, peer_trust_store) and
/// `lib/data` (conversation_repository), plus a live Riverpod / GoRouter / Hive
/// provider graph. Pulling those in wholesale would either drag the whole app
/// into this package or force it to import shell/app packages, which the import
/// gate (spec 3.2 step 4) forbids. So this increment ships a REAL, compiling
/// module whose body is a self-contained surface, and leaves a clear TODO for
/// wider wiring.
///
/// TODO(skchat-ui-extraction): once `lib/core`, `lib/models` and `lib/services`
/// are extracted into this package (later increments of spec 3.2 step 2), swap
/// this placeholder for the real `ChatsScreen` and wire it to the mounted
/// [ShellContext] (theme bridge, audience-scoped auth, deep-link nav via the
/// [ShellBus]).
class ChatsSurface extends StatelessWidget {
  const ChatsSurface({super.key, this.shell});

  /// The shell surfaces when mounted, or null in standalone mode. Kept on the
  /// widget so the eventual real ChatsScreen can consume the theme/auth/bus.
  final ShellContext? shell;

  @override
  Widget build(BuildContext context) {
    final mounted = shell != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        // In mounted mode the shell already frames the module, so no back arrow.
        automaticallyImplyLeading: !mounted,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.chat_bubble_outline, size: 48),
            const SizedBox(height: 12),
            Text(
              mounted ? 'skchat (mounted in shell)' : 'skchat (standalone)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Chats surface. Full ChatsScreen wiring lands in a later '
              'workspace-extraction increment.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
