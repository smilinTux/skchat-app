import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/theme.dart';
import '../../../core/chat_text.dart';
import '../../../models/attachment_ref.dart';
import '../../../models/chat_message.dart';

/// Per-conversation scoped sub-views: Media / Files / Links / Pinned.
///
/// Derived client-side from the already-loaded [messages] window (the same data
/// the conversation view shows), so it works offline and needs no extra
/// endpoint. Backend `search_messages` / `list_transfers` / `list_threads`
/// can later supersede this with full-history scope.
Future<void> showConversationSubviews({
  required BuildContext context,
  required List<ChatMessage> messages,
  required Color soulColor,
  int initialIndex = 0,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _SubviewsSheet(
        messages: messages,
        soulColor: soulColor,
        initialIndex: initialIndex,
      ),
    ),
  );
}

final _kUrlRe = RegExp(r'https?://[^\s]+');

class _SubviewsSheet extends StatelessWidget {
  const _SubviewsSheet({
    required this.messages,
    required this.soulColor,
    required this.initialIndex,
  });

  final List<ChatMessage> messages;
  final Color soulColor;
  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    // Classify messages into the four scoped buckets.
    final media = <_AttachItem>[];
    final files = <_AttachItem>[];
    final links = <_LinkItem>[];
    final pinned = <ChatMessage>[]; // reserved; pin flag arrives in a later phase

    for (final m in messages) {
      final att = AttachmentRef.parse(m.content);
      if (att != null) {
        final item = _AttachItem(att, m.timestamp);
        if (att.isImage) {
          media.add(item);
        } else {
          files.add(item);
        }
        continue;
      }
      final text = displayTextFor(m.content);
      if (text != null) {
        for (final match in _kUrlRe.allMatches(text)) {
          links.add(_LinkItem(match.group(0)!, m.timestamp));
        }
      }
    }

    return DefaultTabController(
      length: 4,
      initialIndex: initialIndex.clamp(0, 3),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Container(
          color: SovereignColors.surfaceBase,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: SovereignColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              TabBar(
                indicatorColor: soulColor,
                labelColor: soulColor,
                unselectedLabelColor: SovereignColors.textSecondary,
                tabs: [
                  Tab(text: 'Media (${media.length})'),
                  Tab(text: 'Files (${files.length})'),
                  Tab(text: 'Links (${links.length})'),
                  Tab(text: 'Pinned (${pinned.length})'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _MediaGrid(items: media, soulColor: soulColor),
                    _FileList(items: files, soulColor: soulColor),
                    _LinkList(items: links, soulColor: soulColor),
                    _EmptyHint(
                      icon: Icons.push_pin_outlined,
                      text: 'No pinned messages',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachItem {
  _AttachItem(this.ref, this.ts);
  final AttachmentRef ref;
  final DateTime ts;
}

class _LinkItem {
  _LinkItem(this.url, this.ts);
  final String url;
  final DateTime ts;
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({required this.items, required this.soulColor});
  final List<_AttachItem> items;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _EmptyHint(icon: Icons.photo_library_outlined, text: 'No media');
    }
    // Media reuses the skos gallery viewer when wired; for now show file cards.
    return GridView.count(
      padding: const EdgeInsets.all(12),
      crossAxisCount: 3,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: items
          .map((i) => Container(
                decoration: BoxDecoration(
                  color: SovereignColors.surfaceGlass,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: soulColor.withValues(alpha: 0.25)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.image_outlined, color: soulColor, size: 28),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        i.ref.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: SovereignColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ))
          .toList(),
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({required this.items, required this.soulColor});
  final List<_AttachItem> items;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _EmptyHint(icon: Icons.insert_drive_file_outlined, text: 'No files');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final it = items[i];
        return ListTile(
          leading: Icon(Icons.insert_drive_file_outlined, color: soulColor),
          title: Text(
            it.ref.filename,
            style: const TextStyle(color: SovereignColors.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            DateFormat('MMM d, h:mm a').format(it.ts.toLocal()),
            style: const TextStyle(color: SovereignColors.textTertiary),
          ),
          tileColor: SovereignColors.surfaceGlass,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        );
      },
    );
  }
}

class _LinkList extends StatelessWidget {
  const _LinkList({required this.items, required this.soulColor});
  final List<_LinkItem> items;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _EmptyHint(icon: Icons.link, text: 'No links');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final it = items[i];
        return ListTile(
          leading: Icon(Icons.link, color: soulColor),
          title: Text(
            it.url,
            style: const TextStyle(color: SovereignColors.textPrimary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            DateFormat('MMM d, h:mm a').format(it.ts.toLocal()),
            style: const TextStyle(color: SovereignColors.textTertiary),
          ),
          tileColor: SovereignColors.surfaceGlass,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        );
      },
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: SovereignColors.textTertiary),
          const SizedBox(height: 8),
          Text(text,
              style: const TextStyle(color: SovereignColors.textTertiary)),
        ],
      ),
    );
  }
}
