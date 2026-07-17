import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../models/conversation.dart";
import "../../services/backend_config.dart";
import "../../services/skcomms_sync.dart";
import "../chats/chats_provider.dart";
import "space_share.dart";

/// Open the "Share Space" sheet for [spaceId] / [title]: share to an existing
/// skchat chat/group, the OS native share sheet, or plain copy-link.
///
/// The join URL is derived from the app's runtime [backendConfigProvider]
/// (`skchatWebuiUrl`, the same origin the Spaces API + LiveKit token mint use,
/// see `spaces_service.dart`), never hardcoded.
Future<void> showShareSpaceSheet(
  BuildContext context, {
  required String spaceId,
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: SovereignColors.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ShareSpaceSheetBody(spaceId: spaceId, title: title),
  );
}

class _ShareSpaceSheetBody extends ConsumerWidget {
  const _ShareSpaceSheetBody({required this.spaceId, required this.title});

  final String spaceId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(
      backendConfigProvider.select((c) => c.skchatWebuiUrl),
    );
    final url = spaceJoinUrl(base, spaceId);
    final text = spaceShareText(title, url);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grab handle, mirrors cast_sheet.dart.
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            alignment: Alignment.center,
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SovereignColors.textTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Row(
              children: [
                Icon(Icons.ios_share_rounded,
                    color: SovereignColors.soulLumina, size: 20),
                SizedBox(width: 8),
                Text(
                  "Share Space",
                  style: TextStyle(
                    color: SovereignColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _ShareOptionRow(
            icon: Icons.chat_bubble_outline_rounded,
            label: "Share to skchat chat",
            onTap: () {
              Navigator.of(context).pop();
              _showChatPicker(context, text);
            },
          ),
          _ShareOptionRow(
            icon: Icons.ios_share_rounded,
            label: "Share via...",
            onTap: () => _shareNative(context, ref, text, url),
          ),
          _ShareOptionRow(
            icon: Icons.link_rounded,
            label: "Copy link",
            onTap: () => _copyLink(context, url),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _showChatPicker(BuildContext context, String text) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SovereignColors.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ChatPickerSheetBody(text: text),
    );
  }

  /// Tries the OS native share sheet (share_plus, via [nativeShareInvokerProvider]).
  /// On Linux desktop (and any platform with no registered share target) the
  /// platform channel can throw / no-op, so any failure falls back to
  /// copy-to-clipboard with a "Link copied" snackbar, same as the Copy link row.
  Future<void> _shareNative(
    BuildContext context,
    WidgetRef ref,
    String text,
    String url,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref.read(nativeShareInvokerProvider)(text, subject: title);
      if (navigator.mounted) navigator.pop();
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      if (navigator.mounted) navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text("Link copied")));
    }
  }

  Future<void> _copyLink(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await Clipboard.setData(ClipboardData(text: url));
    if (navigator.mounted) navigator.pop();
    messenger.showSnackBar(const SnackBar(content: Text("Link copied")));
  }
}

/// A single tappable row inside the share sheet, mirrors `_OptionRow` in
/// `skos_files_screen.dart`.
class _ShareOptionRow extends StatelessWidget {
  const _ShareOptionRow({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: SovereignColors.textSecondary),
            const SizedBox(width: 16),
            Text(
              label,
              style: const TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks an existing skchat chat/group to share the Space link into. Reuses
/// [chatsProvider] (the same list backing the Chats tab) and
/// [skcommsSyncProvider]'s `sendMessage`, the exact send path the
/// conversation screen uses (see `conversation_screen.dart`), so the message
/// lands through the normal PQC-sealing / daemon-first send pipeline.
class _ChatPickerSheetBody extends ConsumerWidget {
  const _ChatPickerSheetBody({required this.text});

  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(chatsProvider);

    if (conversations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: SafeArea(
          child: Text(
            "No chats yet. Start a conversation first.",
            style: TextStyle(color: SovereignColors.textSecondary),
          ),
        ),
      );
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              alignment: Alignment.center,
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SovereignColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: [
                  Text(
                    "Send to",
                    style: TextStyle(
                      color: SovereignColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: conversations.length,
                itemBuilder: (context, i) {
                  final c = conversations[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: c.resolvedSoulColor.withValues(alpha: 0.2),
                      child: Text(
                        c.resolvedInitials,
                        style: TextStyle(color: c.resolvedSoulColor),
                      ),
                    ),
                    title: Text(
                      c.displayName,
                      style: const TextStyle(color: SovereignColors.textPrimary),
                    ),
                    subtitle: c.isGroup
                        ? const Text("Group",
                            style: TextStyle(color: SovereignColors.textTertiary))
                        : null,
                    onTap: () => _sendTo(context, ref, c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendTo(
    BuildContext context,
    WidgetRef ref,
    Conversation conversation,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final result = await ref.read(skcommsSyncProvider.notifier).sendMessage(
          peerId: conversation.peerId,
          content: text,
        );
    if (navigator.mounted) navigator.pop();
    messenger.showSnackBar(SnackBar(
      content: Text(
        result != null
            ? "Sent to ${conversation.displayName}"
            : "Failed to send",
      ),
    ));
  }
}
