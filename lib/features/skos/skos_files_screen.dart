import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/theme.dart';
import 'access_client.dart';
import 'skos_models.dart';
import 'skos_providers.dart';
// PDF surface: native (url_launcher "Open PDF") vs web (<iframe> embed).
import 'skos_pdf_view_stub.dart'
    if (dart.library.html) 'skos_pdf_view_web.dart';
// Browser-download seam: native no-op vs web <a download> anchor.
import 'media_actions_stub.dart'
    if (dart.library.html) 'media_actions_web.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// SkosFilesScreen — the skos Files browser + corpus search (P9, on the P7
/// access plane).
/// ─────────────────────────────────────────────────────────────────────────
///
/// One sovereign disk + one sovereign brain, addressable from the app:
///   * a node picker (`.158` / `.41`) — which node's access MCP to talk to,
///   * a path breadcrumb + directory listing (tap a dir to descend),
///   * tap a file → a swipeable media viewer (PageView over the directory's
///     media) with an Edit/Save affordance that is **disabled/read-only unless
///     a write scope is granted** (default),
///   * long-press a media tile / page → an options sheet (share / open in app /
///     download / copy link / send to chat),
///   * a corpus search bar (`pg_search`) → hits tagged with `{node,path}`;
///     tap a hit to open that file on its owning node.
///
/// All data flows through [accessClientProvider] (the [AccessClient] seam). v1
/// is the [MockAccessClient]; see `access_client.dart` for the live skeleton.
/// The kind of viewer surface a file resolves to, keyed by its lowercased
/// extension. Drives [SkosFileViewer]: text/markdown go through the existing
/// `file_read` (text) path; the binary kinds (image/video/audio/pdf) stream
/// from the same-origin `/media/file` endpoint (range-capable → seek + handles
/// the 300–380 MB AI-LIFE masters; base64-over-/tool's 8 MiB cap could not).
enum MediaKind { image, video, audio, pdf, markdown, text, other }

/// Map a path to its [MediaKind] by lowercased extension.
///
/// `markdown` is split out from `text` so the viewer can choose a rendered vs
/// raw presentation; both still take the small-file `file_read` path.
@visibleForTesting
MediaKind mediaKindFor(String path) {
  final lower = path.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final ext = dot < 0 ? '' : lower.substring(dot + 1);
  switch (ext) {
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
    case 'bmp':
      return MediaKind.image;
    case 'mp4':
    case 'mov':
    case 'webm':
    case 'm4v':
    case 'mkv':
      return MediaKind.video;
    case 'mp3':
    case 'wav':
    case 'm4a':
    case 'ogg':
    case 'flac':
      return MediaKind.audio;
    case 'pdf':
      return MediaKind.pdf;
    case 'md':
    case 'markdown':
      return MediaKind.markdown;
    case 'txt':
    case 'text':
    case 'log':
    case 'json':
    case 'yaml':
    case 'yml':
    case 'toml':
    case 'ini':
    case 'cfg':
    case 'conf':
    case 'env':
    case 'csv':
    case 'tsv':
    case 'xml':
    case 'html':
    case 'htm':
    case 'css':
    case 'js':
    case 'ts':
    case 'dart':
    case 'py':
    case 'sh':
    case 'bash':
    case 'zsh':
    case 'c':
    case 'h':
    case 'cpp':
    case 'cc':
    case 'hpp':
    case 'go':
    case 'rs':
    case 'rb':
    case 'java':
    case 'kt':
    case 'swift':
    case 'sql':
    case 'lua':
    case 'pl':
    case 'r':
    case 'php':
    case 'tf':
    case 'gradle':
    case 'properties':
    case 'gitignore':
    case 'dockerfile':
      return MediaKind.text;
    case '':
      // Extensionless → treat as text (READMEs, LICENSE, Dockerfile, etc.).
      return MediaKind.text;
    default:
      return MediaKind.other;
  }
}

/// True for the swipeable-gallery kinds (image/video/audio). pdf/text/other are
/// excluded — they open standalone, not in the PageView.
@visibleForTesting
bool isGalleryKind(MediaKind kind) =>
    kind == MediaKind.image ||
    kind == MediaKind.video ||
    kind == MediaKind.audio;

/// A single swipeable page in the media gallery: a {node,path} plus its kind.
@visibleForTesting
class MediaItem {
  const MediaItem({required this.node, required this.path, required this.kind});
  final String node;
  final String path;
  final MediaKind kind;

  String get name => _basename(path);
}

/// Build the ordered media list for the gallery from a directory [entries]
/// listing on [node], plus the index of [openPath] within it.
///
/// The list = files (not dirs) whose [mediaKindFor] is a gallery kind
/// (image/video/audio), in listing order, each carrying its full path
/// (`currentDir + '/' + name`, or the entry's own absolute path when present).
/// If [openPath] is itself a gallery item the returned index points at it; if
/// it is NOT in the list (e.g. a pdf/text tapped, or no listing yet) the list
/// is collapsed to just that single open item at index 0 — the viewer then
/// shows it alone with no neighbours to swipe to.
@visibleForTesting
({List<MediaItem> items, int index}) buildMediaGallery({
  required String node,
  required String? currentDir,
  required List<FsEntry> entries,
  required String openPath,
}) {
  final base = (currentDir == null || currentDir.isEmpty)
      ? ''
      : currentDir.replaceAll(RegExp(r'/+$'), '');
  final items = <MediaItem>[];
  for (final e in entries) {
    if (!e.isFile) continue;
    final full = e.path.isNotEmpty
        ? e.path
        : (base.isEmpty ? e.name : '$base/${e.name}');
    final kind = mediaKindFor(full);
    if (!isGalleryKind(kind)) continue;
    items.add(MediaItem(node: node, path: full, kind: kind));
  }
  final idx = items.indexWhere((m) => m.path == openPath);
  if (idx >= 0) return (items: items, index: idx);
  // Open file isn't a gallery item (or the listing is empty / not loaded):
  // show it alone.
  return (
    items: [
      MediaItem(node: node, path: openPath, kind: mediaKindFor(openPath)),
    ],
    index: 0,
  );
}

/// Build the same-origin streaming URL for a binary file on [node].
///
/// `{origin}` is the served origin (same as the daemon base) so the request is
/// same-origin and the browser/`Image.network`/`VideoPlayerController` can do
/// HTTP range requests against the range-capable `/media/file` endpoint.
String mediaStreamUrl(String node, String path) =>
    '${_servedOrigin()}/media/file'
    '?node=${Uri.encodeQueryComponent(node)}'
    '&path=${Uri.encodeQueryComponent(path)}';

/// The origin the app is served from. On web this is the http(s) origin (same
/// as the daemon base). `Uri.base.origin` throws for non-http(s) schemes (e.g.
/// the `file:` base under the Dart VM test runner), so fall back to a relative
/// (same-origin) URL there — harmless since this surface only ships on web.
String _servedOrigin() {
  final base = Uri.base;
  if (base.scheme == 'http' || base.scheme == 'https') return base.origin;
  return '';
}

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
            // file_list entries carry only `name` (no full path), so build the
            // child path from the current dir + name. Root entries (from
            // list_roots) already have an absolute path — prefer it.
            final cur = ref.read(currentPathProvider);
            final base = (cur == null || cur.isEmpty)
                ? ''
                : cur.replaceAll(RegExp(r'/+$'), '');
            final childPath = e.path.isNotEmpty
                ? e.path
                : (base.isEmpty ? e.name : '$base/${e.name}');
            final kind = e.isFile ? mediaKindFor(childPath) : MediaKind.other;
            final isMediaTile = e.isFile && isGalleryKind(kind);
            return _EntryTile(
              entry: e,
              onTap: () {
                if (e.isDir) {
                  ref.read(currentPathProvider.notifier).state = childPath;
                } else {
                  ref.read(openFileProvider.notifier).state =
                      (node: node, path: childPath);
                  _openViewer(context);
                }
              },
              // Long-press a media tile in the grid → the same options sheet
              // the viewer uses. Non-media tiles have no long-press action.
              onLongPress: isMediaTile
                  ? () => showMediaOptionsSheet(
                        context,
                        MediaItem(node: node, path: childPath, kind: kind),
                      )
                  : null,
            );
          },
        );
      },
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.onTap,
    this.onLongPress,
  });
  final FsEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

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
      onLongPress: onLongPress,
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

/// The file viewer. For the swipeable **gallery kinds** (image/video/audio) it
/// is a [PageView] over the current directory's media (see [buildMediaGallery]),
/// opening at the tapped file; swipe left/right = next/prev media. For the
/// standalone kinds it dispatches on [mediaKindFor] of the open path:
///
///   * **image** (png/jpg/jpeg/gif/webp/bmp) → `Image.network` of the
///     same-origin stream URL, inside an [InteractiveViewer] for pinch/zoom,
///     with a loading spinner + error fallback.
///   * **video** (mp4/mov/webm/m4v/mkv) → `VideoPlayerController.networkUrl`
///     (streams + seeks on web; handles the 300–380 MB masters) with
///     play/pause + a scrubbable [VideoProgressIndicator]. Off-screen page
///     controllers are disposed so N videos never play at once.
///   * **audio** (mp3/wav/m4a/ogg/flac) → same `VideoPlayerController` (it
///     plays audio) with a play/pause + progress UI and no video surface.
///   * **pdf** → on web an `<iframe>` embed (browsers render PDF natively); on
///     native an "Open PDF" button. See [SkosPdfView].
///   * **markdown / text / code** → the existing small-file `file_read` (text)
///     path: read-only monospace, with an Edit/Save affordance that is
///     **disabled unless a write scope is granted** ([canWriteProvider]).
///   * **other / binary** → an info card (name + size), never a crash.
///
/// Everything is read-only except the text Save affordance (gated server-side).
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

  PageController? _pageController;
  int _pageIndex = 0;
  // The path of the file that was tapped to open the gallery. Captured once so
  // swiping (which mutates openFileProvider) doesn't re-seek the initial page.
  String? _initialOpenPath;
  // Whether we've jumped to the tapped file's index after the listing loaded.
  bool _seekedToInitial = false;

  @override
  void dispose() {
    _controller.dispose();
    _pageController?.dispose();
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
    final kind = open == null ? MediaKind.other : mediaKindFor(open.path);
    // Only the small-file text/markdown path is editable; binary media never.
    final isTextKind =
        kind == MediaKind.text || kind == MediaKind.markdown;

    // Gallery (swipeable) kinds use the PageView body; everything else falls
    // through to the single-surface dispatch.
    if (open != null && isGalleryKind(kind)) {
      return _buildGalleryScaffold(open);
    }

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
          // Edit/Save affordance only on the editable text path.
          if (isTextKind)
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
      body: open == null
          ? const _ErrorPanel(message: 'No file selected')
          : _buildBody(open, kind, isTextKind),
    );
  }

  /// The swipeable gallery scaffold for image/video/audio. Builds the media
  /// list from the current directory listing, opens at the tapped file, and
  /// lazily renders each page by its kind (off-screen video controllers are
  /// disposed by [_MediaPlayer] going out of the keep-alive window).
  Widget _buildGalleryScaffold(FileRef open) {
    final node = ref.watch(selectedNodeProvider);
    final currentDir = ref.watch(currentPathProvider);
    // Capture the tapped file once; swiping mutates openFileProvider, but the
    // gallery list + initial index must be computed against the ORIGINAL open
    // file so a swipe doesn't re-seek the PageView.
    _initialOpenPath ??= open.path;
    // The listing may still be loading; fall back to an empty list → the
    // tapped file shows alone (buildMediaGallery handles the collapse).
    final listing = ref.watch(dirListingProvider);
    final entries = listing.asData?.value ?? const <FsEntry>[];
    final gallery = buildMediaGallery(
      node: node,
      currentDir: currentDir,
      entries: entries,
      openPath: _initialOpenPath!,
    );
    final items = gallery.items;

    // The PageController exists for the lifetime of the viewer. Its initialPage
    // is 0 (the collapsed single item) while the listing loads; once the
    // listing resolves we jump (post-frame) to the tapped file's real index.
    final controller = _pageController ??= PageController();
    if (!_seekedToInitial && listing.hasValue) {
      _seekedToInitial = true;
      _pageIndex = gallery.index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (controller.hasClients && gallery.index != 0) {
          controller.jumpToPage(gallery.index);
        }
      });
    }
    final current = items[_pageIndex.clamp(0, items.length - 1)];

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
              current.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            Text(
              items.length > 1
                  ? '${current.node} · ${_pageIndex + 1} / ${items.length}'
                  : '${current.node} · ${current.path}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, color: SovereignColors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'Options',
            onPressed: () => showMediaOptionsSheet(context, current),
          ),
        ],
      ),
      body: PageView.builder(
        controller: controller,
        itemCount: items.length,
        onPageChanged: (i) {
          // Keep openFileProvider in sync so the options sheet + any external
          // observers track the visible page.
          setState(() => _pageIndex = i);
          ref.read(openFileProvider.notifier).state =
              (node: items[i].node, path: items[i].path);
        },
        itemBuilder: (context, i) {
          final item = items[i];
          final active = i == _pageIndex;
          return GestureDetector(
            onLongPress: () => showMediaOptionsSheet(context, item),
            // Opaque so long-press registers over the whole page area.
            behavior: HitTestBehavior.opaque,
            child: _GalleryPage(item: item, active: active),
          );
        },
      ),
    );
  }

  Widget _buildBody(FileRef open, MediaKind kind, bool isTextKind) {
    switch (kind) {
      case MediaKind.image:
        return _ImageView(url: mediaStreamUrl(open.node, open.path));
      case MediaKind.video:
        return _MediaPlayer(
          url: mediaStreamUrl(open.node, open.path),
          audioOnly: false,
        );
      case MediaKind.audio:
        return _MediaPlayer(
          url: mediaStreamUrl(open.node, open.path),
          audioOnly: true,
        );
      case MediaKind.pdf:
        return SkosPdfView(
          url: mediaStreamUrl(open.node, open.path),
          label: _basename(open.path),
        );
      case MediaKind.markdown:
      case MediaKind.text:
        return _buildTextBody();
      case MediaKind.other:
        return _BinaryInfoCard(open: open);
    }
  }

  /// The existing small-file `file_read` text path (read-only monospace + edit).
  Widget _buildTextBody() {
    final content = ref.watch(fileContentProvider);
    return content.when(
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
    );
  }
}

// ── Gallery page (one swipeable media surface) ───────────────────────────────

/// One page of the swipe gallery. Renders the [item] by its kind. The video/
/// audio player is only mounted when [active] (the visible page) so off-screen
/// pages never decode/play — swiping away disposes the previous controller.
class _GalleryPage extends StatelessWidget {
  const _GalleryPage({required this.item, required this.active});
  final MediaItem item;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final url = mediaStreamUrl(item.node, item.path);
    switch (item.kind) {
      case MediaKind.image:
        return _ImageView(url: url);
      case MediaKind.video:
      case MediaKind.audio:
        if (!active) {
          // Off-screen: a light placeholder, no VideoPlayerController alive.
          return Center(
            child: Icon(
              item.kind == MediaKind.audio
                  ? Icons.audiotrack_rounded
                  : Icons.movie_creation_outlined,
              size: 72,
              color: SovereignColors.textTertiary,
            ),
          );
        }
        // ValueKey(url) → swapping pages tears down the old controller and
        // builds a fresh one for the now-active page.
        return _MediaPlayer(
          key: ValueKey(url),
          url: url,
          audioOnly: item.kind == MediaKind.audio,
        );
      case MediaKind.pdf:
      case MediaKind.markdown:
      case MediaKind.text:
      case MediaKind.other:
        // Not a gallery kind, but guard anyway → never crash.
        return _ImageView(url: url);
    }
  }
}

// ── Options sheet (long-press: share / download / copy / send-to-chat) ───────

/// Show the Sovereign-Glass media options sheet for [item]: share/open-in-app
/// (file via `share_plus`), download (web), copy link, and a send-to-chat stub.
Future<void> showMediaOptionsSheet(BuildContext context, MediaItem item) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _MediaOptionsSheet(item: item),
  );
}

class _MediaOptionsSheet extends StatefulWidget {
  const _MediaOptionsSheet({required this.item});
  final MediaItem item;

  @override
  State<_MediaOptionsSheet> createState() => _MediaOptionsSheetState();
}

class _MediaOptionsSheetState extends State<_MediaOptionsSheet> {
  bool _busy = false;

  String get _url => mediaStreamUrl(widget.item.node, widget.item.path);

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Share / Open in app. Prefers sharing the actual FILE bytes (so the OS
  /// share sheet offers Save-to-Photos / open-in-a-video-app / send-to-app);
  /// falls back to a URL share if fetching the bytes is unsupported/fails.
  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final bytes = await _fetchBytes(_url);
      final mime = _mimeFor(widget.item.path);
      final xfile = XFile.fromData(
        bytes,
        name: widget.item.name,
        mimeType: mime,
      );
      await Share.shareXFiles([xfile], subject: widget.item.name);
    } catch (_) {
      // File share unsupported (or fetch failed) → URL share. NOTE: tailnet
      // /media/file URLs only resolve for devices on the tailnet.
      try {
        await Share.share(_url, subject: widget.item.name);
      } catch (e) {
        _snack('Share failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _close();
    }
  }

  Future<Uint8List> _fetchBytes(String url) async {
    final dio = Dio();
    final resp = await dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(resp.data ?? const []);
  }

  void _download() {
    // Web: anchor download of the stream URL. Native: no-op (share covers it).
    if (kIsWeb) {
      triggerBrowserDownload(_url, widget.item.name);
      _snack('Downloading ${widget.item.name}…');
    } else {
      _snack('Use Share to save on this device');
    }
    _close();
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: _url));
    _snack('Link copied');
    _close();
  }

  void _sendToChat() {
    // TODO(skchat): wire to the skchat send lane (attach this {node,path} as a
    // media message). Stubbed for now — does not block the gallery UX.
    _snack('Send to chat — coming soon');
    _close();
  }

  void _close() {
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + bottomPad),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Icon(
                    widget.item.kind == MediaKind.image
                        ? Icons.image_outlined
                        : widget.item.kind == MediaKind.audio
                            ? Icons.audiotrack_rounded
                            : Icons.movie_outlined,
                    color: SovereignColors.soulLumina,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: SovereignColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(
                height: 8, color: SovereignColors.textTertiary, thickness: 0.3),
            _OptionRow(
              icon: Icons.ios_share_rounded,
              label: _busy ? 'Sharing…' : 'Share / Open in app',
              onTap: _busy ? null : _share,
            ),
            _OptionRow(
              icon: Icons.download_rounded,
              label: 'Download',
              onTap: _busy ? null : _download,
            ),
            _OptionRow(
              icon: Icons.link_rounded,
              label: 'Copy link',
              onTap: _busy ? null : _copyLink,
            ),
            _OptionRow(
              icon: Icons.send_rounded,
              label: 'Send to chat (soon)',
              onTap: _busy ? null : _sendToChat,
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = disabled
        ? SovereignColors.textTertiary
        : SovereignColors.textPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                  color: color, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Best-effort MIME from extension for the shared [XFile]. Covers the gallery
/// kinds; defaults to `application/octet-stream`.
String _mimeFor(String path) {
  final lower = path.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final ext = dot < 0 ? '' : lower.substring(dot + 1);
  switch (ext) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'bmp':
      return 'image/bmp';
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case 'mkv':
      return 'video/x-matroska';
    case 'mp3':
      return 'audio/mpeg';
    case 'wav':
      return 'audio/wav';
    case 'm4a':
      return 'audio/mp4';
    case 'ogg':
      return 'audio/ogg';
    case 'flac':
      return 'audio/flac';
    default:
      return 'application/octet-stream';
  }
}

// ── Image surface (streaming, same-origin) ───────────────────────────────────

class _ImageView extends StatelessWidget {
  const _ImageView({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InteractiveViewer(
        maxScale: 6,
        child: Image.network(
          url,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            final total = progress.expectedTotalBytes;
            return Center(
              child: CircularProgressIndicator(
                value: total != null
                    ? progress.cumulativeBytesLoaded / total
                    : null,
              ),
            );
          },
          errorBuilder: (context, error, _) =>
              _ErrorPanel(message: 'Image failed to load: $error'),
        ),
      ),
    );
  }
}

// ── Video / audio surface (streaming + seek, same-origin) ────────────────────

/// Test seam: the function used to build the [VideoPlayerController]. Production
/// is `VideoPlayerController.networkUrl`; a widget test injects a fake so the
/// play/pause wiring (init → listener → toggle) is assertable without a platform
/// video plugin. Reset to null in tearDown.
typedef MediaControllerFactory = VideoPlayerController Function(Uri uri);

@visibleForTesting
MediaControllerFactory? debugMediaControllerFactory;

class _MediaPlayer extends StatefulWidget {
  const _MediaPlayer({super.key, required this.url, required this.audioOnly});
  final String url;
  final bool audioOnly;

  @override
  State<_MediaPlayer> createState() => _MediaPlayerState();
}

class _MediaPlayerState extends State<_MediaPlayer> {
  VideoPlayerController? _controller;
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // VideoPlayerController decodes BOTH video and audio. networkUrl streams
    // from the range-capable endpoint (no full download → the 300 MB masters
    // seek fine). We:
    //   1. build the controller,
    //   2. attach a listener so the play/pause icon + progress + position
    //      readout track ACTUAL playback state (the old code never did this, so
    //      the controls looked dead — they never reflected play/pause/seek),
    //   3. await initialize() BEFORE showing controls, then setState so the UI
    //      rebuilds with the ready controller.
    final uri = Uri.parse(widget.url);
    final factory = debugMediaControllerFactory;
    final c =
        factory != null ? factory(uri) : VideoPlayerController.networkUrl(uri);
    _controller = c;
    c.addListener(_onTick);
    try {
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  /// Rebuild on every controller tick so the icon/progress/position reflect the
  /// real state (play, pause, seek, buffering, completion). Guarded by mounted.
  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  /// Toggle play/pause. On web the browser blocks UNMUTED autoplay without a
  /// user gesture — but this runs from a tap (button or surface), which IS the
  /// gesture, so calling play() here both starts playback and produces sound.
  /// We never rely on autoplay; the explicit tap is required. The listener
  /// (_onTick) drives the icon flip — we do NOT wrap the async play()/pause() in
  /// setState (that was the old bug: it set state before the state had changed).
  void _togglePlay() {
    final c = _controller;
    if (c == null || !_ready) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorPanel(message: 'Media failed to load: $_error');
    }
    final c = _controller;
    if (!_ready || c == null) {
      // Spinner until initialize() completes.
      return const Center(child: CircularProgressIndicator());
    }

    final isPlaying = c.value.isPlaying;
    final surface = widget.audioOnly
        ? Center(
            child: Icon(
              isPlaying ? Icons.graphic_eq_rounded : Icons.audiotrack_rounded,
              size: 96,
              color: SovereignColors.soulLumina,
            ),
          )
        : AspectRatio(
            aspectRatio:
                c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
            child: VideoPlayer(c),
          );

    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            // Tapping the surface toggles play/pause too — also a user gesture,
            // so it unlocks web audio just like the button.
            onTap: _togglePlay,
            behavior: HitTestBehavior.opaque,
            child: Center(child: surface),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: VideoProgressIndicator(
            c,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: SovereignColors.soulLumina,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Text(
                _fmtDuration(c.value.position),
                style: const TextStyle(
                    color: SovereignColors.textSecondary, fontSize: 12),
              ),
              const Spacer(),
              Text(
                _fmtDuration(c.value.duration),
                style: const TextStyle(
                    color: SovereignColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 16),
          child: IconButton.filled(
            iconSize: 32,
            tooltip: isPlaying ? 'Pause' : 'Play',
            icon: Icon(isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded),
            onPressed: _togglePlay,
          ),
        ),
      ],
    );
  }
}

/// `m:ss` (or `h:mm:ss`) for the position/duration readout.
String _fmtDuration(Duration d) {
  final neg = d.isNegative;
  final abs = d.abs();
  final s = abs.inSeconds.remainder(60).toString().padLeft(2, '0');
  final m = abs.inMinutes.remainder(60);
  final h = abs.inHours;
  final body =
      h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  return neg ? '-$body' : body;
}

// ── Other / unknown binary ───────────────────────────────────────────────────

class _BinaryInfoCard extends StatelessWidget {
  const _BinaryInfoCard({required this.open});
  final FileRef open;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file_outlined,
                  color: SovereignColors.textSecondary, size: 40),
              const SizedBox(height: 12),
              Text(
                _basename(open.path),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: SovereignColors.textPrimary,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'No inline preview for this file type',
                style: TextStyle(
                    color: SovereignColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
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
