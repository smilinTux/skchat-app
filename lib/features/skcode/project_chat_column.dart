import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
import '../chats/chats_provider.dart';
import '../conversation/conversation_screen.dart';

/// The host-side half of card C-12's project-chat injection seam
/// (`skcode_client`'s `SkcodeProjectChatBuilder`, spec section 10): finds
/// the skchat group carrying `meta.project = repo:<repo>` and mounts the
/// EXISTING native chat surface (`ConversationScreen`, the same widget the
/// Chats tab pushes for every other thread) scoped to it -- bare, no app
/// bar of its own (the Code pane supplies whatever chrome the current tier
/// needs around it), composer placeholder overridden to `Message #<repo>`.
///
/// ZERO new chat infrastructure (spec section 10's hard rule): this widget
/// owns no store, no model, no crypto path of its own. It is a `ref.watch`
/// over the SAME `chatsProvider` the Chats tab already reads, exactly the
/// bridge pattern `LiveChatsSurface` (`live_chats_surface.dart`) already
/// established for mounting the whole Chats list into the shell.
///
/// Degrades honestly (card C-12's own "Constraints" section) when no group
/// is bound yet: today NOTHING creates a `meta.project`-tagged group (that
/// is a skcomms/skchat daemon-side feature, out of this Flutter repo's
/// reach), so this empty state is the expected steady state until that
/// exists, not a bug -- never a crash, never a dead blank column.
class ProjectChatColumn extends ConsumerWidget {
  const ProjectChatColumn({super.key, required this.repo});

  final String repo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(chatsProvider);
    final metaKey = 'repo:$repo';
    Conversation? matched;
    for (final c in conversations) {
      if (c.metaProject == metaKey) {
        matched = c;
        break;
      }
    }

    if (matched == null) {
      return _NoProjectChatBound(repo: repo);
    }

    return ConversationScreen(
      key: ValueKey('skcode-project-chat-${matched.peerId}'),
      peerId: matched.peerId,
      showAppBar: false,
      composerHintText: 'Message #$repo',
    );
  }
}

/// The honest empty state (card C-12's "Constraints": "no project group
/// bound for this repo ... must render a clear empty state, never a crash
/// or a dead column").
class _NoProjectChatBound extends StatelessWidget {
  const _NoProjectChatBound({required this.repo});

  final String repo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const Key('skcodeNoProjectChatBound'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, color: theme.disabledColor),
            const SizedBox(height: 8),
            Text(
              'No project chat for $repo yet',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Tag a group with meta.project = repo:$repo to bind one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor),
            ),
          ],
        ),
      ),
    );
  }
}
