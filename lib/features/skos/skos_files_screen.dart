import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import 'access_client.dart';
import 'skos_models.dart';
import 'skos_providers.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// SkosFilesScreen — the skos Files browser + corpus search (P9, on the P7
/// access plane).
/// ─────────────────────────────────────────────────────────────────────────
///
/// One sovereign disk + one sovereign brain, addressable from the app:
///   * a node picker (`.158` / `.41`) — which node's access MCP to talk to,
///   * a path breadcrumb + directory listing (tap a dir to descend),
///   * tap a file → a text viewer with an Edit/Save affordance that is
///     **disabled/read-only unless a write scope is granted** (default),
///   * a corpus search bar (`pg_search`) → hits tagged with `{node,path}`;
///     tap a hit to open that file on its owning node.
///
/// All data flows through [accessClientProvider] (the [AccessClient] seam). v1
/// is the [MockAccessClient]; see `access_client.dart` for the live skeleton.
class SkosFilesScreen extends ConsumerWidget {
  const SkosFilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = ref.watch(selectedNodeProvider);
    final path = ref.watch(currentPathProvider);
    final query = ref.watch(searchQueryProvider);
    final searching = query.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(node: node),
            const _SearchBar(),
            if (!searching) _Breadcrumb(node: node, path: path),
            Expanded(
              child: searching
                  ? const _SearchResults()
                  : const _DirListing(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Header + node picker ─────────────────────────────────────────────────────

class _Header extends ConsumerWidget {
  const _Header({required this.node});
  final String node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canWrite = ref.watch(canWriteProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.folder_special_rounded,
                color: SovereignColors.soulLumina, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'skos Files',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: SovereignColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  Text(
                    canWrite ? 'write scope granted' : 'read-only',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: canWrite
                              ? SovereignColors.accentEncrypt
                              : SovereignColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
            _NodePicker(node: node),
          ],
        ),
      ),
    );
  }
}

class _NodePicker extends ConsumerWidget {
  const _NodePicker({required this.node});
  final String node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodes = ref.watch(knownNodesProvider);
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: node,
        dropdownColor: SovereignColors.surfaceCard,
        icon: const Icon(Icons.dns_rounded,
            color: SovereignColors.textSecondary, size: 18),
        style: const TextStyle(color: SovereignColors.textPrimary),
        items: [
          for (final n in nodes)
            DropdownMenuItem(
              value: n,
              child: Text(n,
                  style: const TextStyle(
                      color: SovereignColors.textPrimary,
                      fontWeight: FontWeight.w600)),
            ),
        ],
        onChanged: (n) {
          if (n == null) return;
          ref.read(selectedNodeProvider.notifier).state = n;
          // Reset to the new node's roots.
          ref.read(currentPathProvider.notifier).state = null;
        },
      ),
    );
  }
}

// ── Search bar ───────────────────────────────────────────────────────────────

class _SearchBar extends ConsumerStatefulWidget {
  const _SearchBar();
  @override
  ConsumerState<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends ConsumerState<_SearchBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _run() => ref.read(searchQueryProvider.notifier).state =
      _controller.text.trim();

  void _clear() {
    _controller.clear();
    ref.read(searchQueryProvider.notifier).state = '';
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: [
            const Icon(Icons.travel_explore_rounded,
                color: SovereignColors.textSecondary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                onSubmitted: (_) => _run(),
                style: const TextStyle(color: SovereignColors.textPrimary),
                cursorColor: SovereignColors.soulLumina,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Search the corpus (pg_search)…',
                  hintStyle:
                      TextStyle(color: SovereignColors.textTertiary),
                ),
              ),
            ),
            if (query.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: SovereignColors.textSecondary, size: 18),
                onPressed: _clear,
                tooltip: 'Clear search',
              )
            else
              IconButton(
                icon: const Icon(Icons.search_rounded,
                    color: SovereignColors.soulLumina, size: 20),
                onPressed: _run,
                tooltip: 'Search',
              ),
          ],
        ),
      ),
    );
  }
}

// ── Breadcrumb ───────────────────────────────────────────────────────────────

class _Breadcrumb extends ConsumerWidget {
  const _Breadcrumb({required this.node, required this.path});
  final String node;
  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crumbs = <(_String label, String? target)>[
      (const _String('roots'), null),
    ];
    if (path != null) {
      final parts = path!.split('/').where((p) => p.isNotEmpty).toList();
      var acc = '';
      for (final p in parts) {
        acc = '$acc/$p';
        crumbs.add((_String(p), acc));
      }
    }
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        itemCount: crumbs.length,
        separatorBuilder: (_, _) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 2),
          child: Icon(Icons.chevron_right_rounded,
              size: 16, color: SovereignColors.textTertiary),
        ),
        itemBuilder: (context, i) {
          final crumb = crumbs[i];
          final isLast = i == crumbs.length - 1;
          return Center(
            child: InkWell(
              onTap: isLast
                  ? null
                  : () => ref.read(currentPathProvider.notifier).state =
                      crumb.$2,
              child: Text(
                crumb.$1.value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isLast ? FontWeight.w700 : FontWeight.w500,
                  color: isLast
                      ? SovereignColors.textPrimary
                      : SovereignColors.soulLumina,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Tiny wrapper so the record's first field is a distinct type (avoids the
/// analyzer flagging a String/String? record positional clash).
class _String {
  const _String(this.value);
  final String value;
}

// ── Directory listing ────────────────────────────────────────────────────────

class _DirListing extends ConsumerWidget {
  const _DirListing();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = ref.watch(selectedNodeProvider);
    final listing = ref.watch(dirListingProvider);

    return listing.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorPanel(message: e.toString()),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(
            child: Text('Empty directory',
                style: TextStyle(color: SovereignColors.textSecondary)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final e = entries[i];
            return _EntryTile(
              entry: e,
              onTap: () {
                if (e.isDir) {
                  ref.read(currentPathProvider.notifier).state = e.path;
                } else {
                  ref.read(openFileProvider.notifier).state =
                      (node: node, path: e.path);
                  _openViewer(context);
                }
              },
            );
          },
        );
      },
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap});
  final FsEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = entry.isDir
        ? Icons.folder_rounded
        : Icons.description_outlined;
    final color = entry.isDir
        ? SovereignColors.soulChef
        : SovereignColors.textSecondary;
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: SovereignColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (entry.isFile && entry.size != null)
            Text(
              _humanSize(entry.size!),
              style: const TextStyle(
                  color: SovereignColors.textTertiary, fontSize: 12),
            ),
          if (entry.isDir)
            const Icon(Icons.chevron_right_rounded,
                color: SovereignColors.textTertiary),
        ],
      ),
    );
  }
}

// ── Search results ───────────────────────────────────────────────────────────

class _SearchResults extends ConsumerWidget {
  const _SearchResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchResultsProvider);
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorPanel(message: e.toString()),
      data: (hits) {
        if (hits.isEmpty) {
          return const Center(
            child: Text('No corpus matches',
                style: TextStyle(color: SovereignColors.textSecondary)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          itemCount: hits.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final h = hits[i];
            return _HitTile(
              hit: h,
              onTap: () {
                ref.read(openFileProvider.notifier).state =
                    (node: h.node, path: h.path);
                _openViewer(context);
              },
            );
          },
        );
      },
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.hit, required this.onTap});
  final SearchHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _NodeChip(node: hit.node),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hit.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SovereignColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              Text(
                hit.score.toStringAsFixed(2),
                style: const TextStyle(
                    color: SovereignColors.soulLumina, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            hit.snippet,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: SovereignColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _NodeChip extends StatelessWidget {
  const _NodeChip({required this.node});
  final String node;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: SovereignColors.soulJarvis.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        node,
        style: const TextStyle(
            color: SovereignColors.soulJarvis,
            fontSize: 11,
            fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ── Viewer (opened as a route-less modal page) ──────────────────────────────

void _openViewer(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const SkosFileViewer(),
      fullscreenDialog: true,
    ),
  );
}

/// The text viewer + read-only/edit affordance. Save is **disabled** unless the
/// active client reports a granted write scope ([canWriteProvider]).
class SkosFileViewer extends ConsumerStatefulWidget {
  const SkosFileViewer({super.key});

  @override
  ConsumerState<SkosFileViewer> createState() => _SkosFileViewerState();
}

class _SkosFileViewerState extends ConsumerState<SkosFileViewer> {
  final _controller = TextEditingController();
  bool _editing = false;
  bool _saving = false;
  bool _loaded = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final open = ref.read(openFileProvider);
    if (open == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(accessClientProvider)
          .writeFile(open.node, open.path, _controller.text);
      // Refresh content from source.
      ref.invalidate(fileContentProvider);
      if (mounted) {
        setState(() {
          _editing = false;
          _saving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(openFileProvider);
    final canWrite = ref.watch(canWriteProvider);
    final content = ref.watch(fileContentProvider);

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceCard,
        foregroundColor: SovereignColors.textPrimary,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              open == null ? 'File' : _basename(open.path),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (open != null)
              Text(
                '${open.node} · ${open.path}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11, color: SovereignColors.textSecondary),
              ),
          ],
        ),
        actions: [
          if (!canWrite)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Tooltip(
                message: 'Read-only — no write scope granted',
                child: Icon(Icons.lock_outline_rounded,
                    color: SovereignColors.textSecondary, size: 20),
              ),
            )
          else if (_editing)
            _saving
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    icon: const Icon(Icons.save_rounded),
                    tooltip: 'Save',
                    onPressed: _save,
                  )
          else
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              tooltip: 'Edit',
              onPressed: () => setState(() => _editing = true),
            ),
        ],
      ),
      body: content.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorPanel(message: e.toString()),
        data: (text) {
          if (!_loaded) {
            _controller.text = text;
            _loaded = true;
          }
          return Padding(
            padding: const EdgeInsets.all(16),
            child: _editing
                ? TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                        color: SovereignColors.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 13),
                    cursorColor: SovereignColors.soulLumina,
                    decoration: const InputDecoration(border: InputBorder.none),
                  )
                : SingleChildScrollView(
                    child: SelectableText(
                      text.isEmpty ? '(empty file)' : text,
                      style: const TextStyle(
                          color: SovereignColors.textPrimary,
                          fontFamily: 'monospace',
                          fontSize: 13),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

// ── Shared bits ──────────────────────────────────────────────────────────────

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  color: SovereignColors.accentWarning, size: 32),
              const SizedBox(height: 8),
              const Text('Access plane unavailable',
                  style: TextStyle(
                      color: SovereignColors.textPrimary,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: SovereignColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _basename(String path) {
  final trimmed =
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final idx = trimmed.lastIndexOf('/');
  return idx < 0 ? trimmed : trimmed.substring(idx + 1);
}
