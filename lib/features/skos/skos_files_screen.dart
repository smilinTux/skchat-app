import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../core/router/app_router.dart';
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

    // Keep the roots list warm so swipe-up-a-folder can clamp synchronously.
    final roots = ref.watch(rootsProvider(node)).valueOrNull ?? const <String>[];

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
                  // Swipe RIGHT anywhere on the listing → go up a folder
                  // (parent dir, clamped to the exposed roots). Vertical scroll
                  // is unaffected (different gesture axis).
                  : GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragEnd: (d) {
                        if ((d.primaryVelocity ?? 0) > 250) {
                          ref.read(currentPathProvider.notifier).state =
                              parentPathWithinRoots(path, roots);
                        }
                      },
                      child: const _DirListing(),
                    ),
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

// ── Viewer (opened as a full-screen route ABOVE the tab shell) ──────────────

/// Open the media viewer as the full-screen `/skos/view` route. It is a
/// **top-level GoRouter route** (a sibling of the [ShellRoute]) so it sits ABOVE
/// the bottom nav bar AND so push/pop stay in sync with browser history.
///
/// The old implementation pushed an imperative [PageRouteBuilder] onto the root
/// Navigator, bypassing GoRouter; on web that desynced from the browser URL, so
/// closing (the ✕ → root-Navigator pop, or the phone-browser back gesture)
/// re-resolved GoRouter's own stack and dumped the user back at the root
/// listing instead of the directory they were browsing. Pushing the route
/// through GoRouter ([context.push]) means [Navigator.pop] / the back gesture
/// pop exactly this route, returning to the live `/skos/files` screen — which
/// still holds [currentPathProvider], so we land back in the SAME folder.
///
/// We do NOT touch [currentPathProvider] here; only [openFileProvider] (set by
/// the caller) changes, so the Files screen underneath is undisturbed.
void _openViewer(BuildContext context) {
  context.push(AppRoutes.skosView);
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

  // ── Immersive-viewer chrome state ──────────────────────────────────────────
  // Whether the translucent top/bottom bars are shown. Start visible so the
  // user always sees close/options/play on entry.
  bool _chromeVisible = true;
  // True while the current image page is pinch-zoomed (disables page swipe).
  bool _zoomed = false;
  // The active page's video/audio controller (null for images / while loading);
  // drives the bottom control bar + center play button.
  VideoPlayerController? _activeController;
  // Tracks the active controller's last-seen playing state so [_onActiveTick]
  // can detect the play→pause / play→end edge and re-summon the chrome.
  bool _wasPlaying = false;
  // Auto-hide timer for the chrome during video playback.
  Timer? _hideTimer;

  // ── Drag-to-dismiss state ──────────────────────────────────────────────────
  // Cumulative vertical drag offset (px) of the in-progress dismiss gesture; the
  // whole stack translates by this + fades as |offset| grows. 0 = at rest.
  double _dragOffset = 0;
  // Pixels of vertical travel past which a release/fling dismisses the viewer.
  static const double _kDismissThreshold = 120;
  // Fling velocity (px/s) that dismisses regardless of distance (a quick flick).
  static const double _kDismissFlingVelocity = 700;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _activeController?.removeListener(_onActiveTick);
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

  /// The immersive full-screen gallery for image/video/audio. Builds the media
  /// list from the current directory listing, opens at the tapped file, and
  /// lazily renders each page by its kind (off-screen video controllers are
  /// disposed by [_MediaPlayer] going out of the keep-alive window).
  ///
  /// Layout (a [Stack] over an opaque black backdrop, NO Scaffold/AppBar so the
  /// tab shell can never show through):
  ///   * the [PageView] of media fills the screen; each page fits its media with
  ///     `BoxFit.contain` in the box BETWEEN the top bar and the bottom control
  ///     bar (so nothing is ever clipped),
  ///   * a translucent **top bar** (close ✕ · filename + `node · i/total` ·
  ///     options ⋮) pinned under the top safe-area inset,
  ///   * a translucent **bottom control bar** (video/audio only:
  ///     play/pause + scrubbable progress + `m:ss / m:ss`) pinned above the
  ///     bottom safe-area inset,
  ///   * a large **center play ▶ overlay** on a paused video.
  /// Bars auto-hide after ~3s during video playback; any tap toggles them.
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

    final viewPadding = MediaQuery.viewPaddingOf(context);

    // Drag-to-dismiss visuals: as the stack is dragged up/down it translates with
    // the finger and fades toward the black backdrop (snaps back if released
    // under threshold). Opacity eases from 1 → ~0.4 across one threshold of
    // travel so the dismiss feels physical without going fully invisible mid-drag.
    final dragProgress =
        (_dragOffset.abs() / _kDismissThreshold).clamp(0.0, 1.0);
    final contentOpacity = 1.0 - (dragProgress * 0.6);

    return PopScope(
      // Default pop behaviour (back gesture / ✕ both close the route).
      canPop: true,
      child: Scaffold(
        // Opaque black backdrop. The route itself is also opaque so the shell
        // never shows through (the dragged content fades onto this black).
        backgroundColor: Colors.black,
        // Do NOT add a bottomNavigationBar / AppBar — this is the WHOLE screen.
        body: GestureDetector(
          // ONE tap on the surface toggles the chrome (top bar with ✕ + bottom
          // controls) — decoupled from play/pause, so the user can always
          // summon the close button. `deferToChild` lets taps on the actual
          // buttons (✕ / ⋮ / play) win.
          behavior: HitTestBehavior.deferToChild,
          onTap: _toggleChrome,
          // Vertical drag = drag-to-dismiss (Photos/Instagram style). HORIZONTAL
          // paging is owned by the inner PageView (orthogonal axis → no
          // conflict); the gesture is disabled while an image is pinch-zoomed so
          // panning a zoomed photo never closes the viewer.
          onVerticalDragUpdate: _zoomed ? null : _onDismissDragUpdate,
          onVerticalDragEnd: _zoomed ? null : _onDismissDragEnd,
          child: Opacity(
            opacity: contentOpacity,
            child: Transform.translate(
              offset: Offset(0, _dragOffset),
              child: Stack(
            fit: StackFit.expand,
            children: [
              // ── Media pager (fills the screen; each page insets its media to
              //    sit between the bars via the padding we pass down). ─────────
              PageView.builder(
                controller: controller,
                // Disable swipe while an image is pinch-zoomed.
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: items.length,
                onPageChanged: (i) {
                  setState(() {
                    _pageIndex = i;
                    _zoomed = false;
                    _activeController = null;
                  });
                  // Keep openFileProvider in sync so the options sheet + any
                  // external observers track the visible page.
                  ref.read(openFileProvider.notifier).state =
                      (node: items[i].node, path: items[i].path);
                  // Re-show chrome on page change so controls are findable.
                  _revealChrome(autoHide: false);
                },
                itemBuilder: (context, i) {
                  final item = items[i];
                  final active = i == _pageIndex;
                  // Long-press anywhere on the page → the options sheet (also
                  // reachable via the top bar ⋮).
                  return GestureDetector(
                    onLongPress: () => showMediaOptionsSheet(context, item),
                    behavior: HitTestBehavior.deferToChild,
                    child: _GalleryPage(
                    item: item,
                    active: active,
                    // Inset so the media's contain-box never overlaps the bars.
                    topInset: viewPadding.top + _kTopBarHeight,
                    bottomInset: viewPadding.bottom +
                        (item.kind == MediaKind.image
                            ? 0
                            : _kBottomBarHeight),
                    onTapSurface: _onSurfaceTap,
                    onZoomChanged: (z) {
                      if (z != _zoomed) setState(() => _zoomed = z);
                    },
                    onControllerReady: (c) {
                      // Track the active page's controller so the bottom bar +
                      // center play button can drive it. Wire playback auto-hide.
                      if (active) {
                        setState(() => _activeController = c);
                        c.removeListener(_onActiveTick);
                        c.addListener(_onActiveTick);
                      }
                    },
                  ),
                  );
                },
              ),

              // ── Bottom control bar (video/audio) — pinned above safe area. ──
              if (_activeController != null && current.kind != MediaKind.image)
                _AnimatedChrome(
                  visible: _chromeVisible,
                  alignment: Alignment.bottomCenter,
                  child: _BottomControlBar(
                    controller: _activeController!,
                    bottomInset: viewPadding.bottom,
                    onToggle: _togglePlayActive,
                  ),
                ),

              // ── Center play ▶ overlay (paused video only). ──────────────────
              if (_activeController != null &&
                  current.kind != MediaKind.image &&
                  !_activeController!.value.isPlaying)
                Center(
                  child: _CenterPlayButton(onTap: _togglePlayActive),
                ),

              // ── Top bar (close · title+counter · options) — over safe area. ─
              _AnimatedChrome(
                visible: _chromeVisible,
                alignment: Alignment.topCenter,
                child: _TopBar(
                  topInset: viewPadding.top,
                  title: current.name,
                  subtitle: items.length > 1
                      ? '${current.node} · ${_pageIndex + 1} / ${items.length}'
                      : '${current.node} · ${current.path}',
                  // Close via GoRouter pop so push/pop stay in sync with
                  // browser history — returns to the live /skos/files screen,
                  // which still shows the same browsed dir (currentPathProvider).
                  onClose: _closeViewer,
                  onOptions: () => showMediaOptionsSheet(context, current),
                ),
              ),
            ],
          ),
            ),
          ),
        ),
      ),
    );
  }

  /// Pop the viewer route. Prefers GoRouter's pop (keeps browser history in
  /// sync); falls back to the root Navigator if there is nothing for GoRouter
  /// to pop (e.g. the viewer was opened standalone in a test).
  void _closeViewer() {
    final router = GoRouter.maybeOf(context);
    if (router != null && router.canPop()) {
      router.pop();
    } else {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
  }

  /// Follow the finger while dragging vertically (either direction).
  void _onDismissDragUpdate(DragUpdateDetails d) {
    setState(() => _dragOffset += d.delta.dy);
  }

  /// On release: dismiss if dragged past the distance threshold OR flung fast
  /// enough (in the direction of travel); otherwise spring back to rest.
  void _onDismissDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final pastDistance = _dragOffset.abs() > _kDismissThreshold;
    final flung = v.abs() > _kDismissFlingVelocity;
    if (pastDistance || flung) {
      _closeViewer();
    } else {
      setState(() => _dragOffset = 0);
    }
  }

  /// Toggle the play/pause state of the active page's controller (the gesture
  /// that unlocks web audio — see [_MediaPlayerState._togglePlay] notes). On
  /// PLAY we start the auto-hide timer; on PAUSE we keep chrome up.
  void _togglePlayActive() {
    final c = _activeController;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
      _revealChrome(autoHide: false);
    } else {
      c.play();
      _revealChrome(autoHide: true);
    }
  }

  /// Rebuild on the active controller's ticks so the bottom bar + center play
  /// button reflect real playback state. Also re-shows the chrome whenever the
  /// video transitions to PAUSED or ENDED — so a user is never left on a stopped
  /// video with the ✕ auto-hidden (the close button is always re-summoned).
  void _onActiveTick() {
    if (!mounted) return;
    final c = _activeController;
    final playing = c?.value.isPlaying ?? false;
    final v = c?.value;
    final ended = v != null &&
        v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= v.duration;
    final stopped = !playing || ended;
    // On a play→pause / play→end transition, force the chrome back so the close
    // affordance reappears; cancel any pending auto-hide.
    if (stopped && _wasPlaying) {
      _hideTimer?.cancel();
      if (!_chromeVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _chromeVisible = true);
        });
      }
    }
    _wasPlaying = playing;
    setState(() {});
  }

  /// Show the chrome; if [autoHide] and a video is playing, schedule a fade-out.
  void _revealChrome({required bool autoHide}) {
    _hideTimer?.cancel();
    if (!_chromeVisible) setState(() => _chromeVisible = true);
    final c = _activeController;
    if (autoHide && c != null && c.value.isPlaying) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        // Only auto-hide while still playing — never strand a paused user.
        if (_activeController?.value.isPlaying ?? false) {
          setState(() => _chromeVisible = false);
        }
      });
    }
  }

  /// A single tap on the media surface TOGGLES the chrome (top bar with ✕ +
  /// bottom controls). This is fully decoupled from playback — it never
  /// plays/pauses. Toggling works the same for images and video:
  ///   * if the chrome is hidden → show it (and, if a video is playing, re-arm
  ///     the 3 s auto-hide so it can fade again),
  ///   * if the chrome is shown → hide it.
  /// The user can always bring back the ✕ with one tap, and pausing/ending a
  /// video re-shows the chrome ([_onActiveTick]) — so they are never stranded.
  void _toggleChrome() {
    if (_chromeVisible) {
      _hideTimer?.cancel();
      setState(() => _chromeVisible = false);
    } else {
      final playing = _activeController?.value.isPlaying ?? false;
      _revealChrome(autoHide: playing);
    }
  }

  /// Tap on the video/audio surface ONLY toggles the chrome — it never controls
  /// playback. Play/pause is driven exclusively by the center ▶ button and the
  /// bottom bar's play/pause button, so a tap to find the ✕ can never
  /// accidentally pause (or play) the media.
  void _onSurfaceTap() => _toggleChrome();

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

/// One page of the swipe gallery. Renders the [item] by its kind, fitting the
/// media with `BoxFit.contain` inside the box BETWEEN the bars (the parent
/// passes [topInset] / [bottomInset]) so it is NEVER clipped or overlapped. The
/// video/audio player is only mounted when [active] (the visible page) so
/// off-screen pages never decode/play — swiping away disposes the controller.
class _GalleryPage extends StatelessWidget {
  const _GalleryPage({
    required this.item,
    required this.active,
    required this.topInset,
    required this.bottomInset,
    required this.onTapSurface,
    required this.onZoomChanged,
    required this.onControllerReady,
  });
  final MediaItem item;
  final bool active;
  final double topInset;
  final double bottomInset;
  final VoidCallback onTapSurface;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<VideoPlayerController> onControllerReady;

  @override
  Widget build(BuildContext context) {
    final url = mediaStreamUrl(item.node, item.path);
    // The fit-box: media lives between the top bar and the bottom control bar.
    final body = switch (item.kind) {
      // Image taps must toggle the chrome too — InteractiveViewer owns pan/zoom
      // gestures, so the parent's deferToChild tap never reaches it. A
      // translucent GestureDetector here catches the tap (chrome toggle) while
      // letting pinch/pan flow through to the InteractiveViewer underneath.
      MediaKind.image => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: onTapSurface,
          child: _ImageView(
            url: url,
            onZoomChanged: onZoomChanged,
          ),
        ),
      MediaKind.video || MediaKind.audio => active
          ? _MediaPlayer(
              key: ValueKey(url),
              url: url,
              audioOnly: item.kind == MediaKind.audio,
              onTapSurface: onTapSurface,
              onControllerReady: onControllerReady,
            )
          : Center(
              child: Icon(
                item.kind == MediaKind.audio
                    ? Icons.audiotrack_rounded
                    : Icons.movie_creation_outlined,
                size: 72,
                color: SovereignColors.textTertiary,
              ),
            ),
      // Not a gallery kind, but guard anyway → never crash.
      MediaKind.pdf ||
      MediaKind.markdown ||
      MediaKind.text ||
      MediaKind.other =>
        _ImageView(url: url, onZoomChanged: onZoomChanged),
    };
    return Padding(
      padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
      child: body,
    );
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

class _ImageView extends StatefulWidget {
  const _ImageView({required this.url, this.onZoomChanged});
  final String url;

  /// Notifies the gallery when the image is pinch-zoomed (scale > ~1) so it can
  /// disable page-swipe while zoomed. Optional (standalone callers omit it).
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView> {
  final _transform = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
  }

  void _onTransform() {
    // Detect zoom from the matrix scale (m[0]); report state transitions only.
    final scale = _transform.value.getMaxScaleOnAxis();
    final z = scale > 1.02;
    if (z != _zoomed) {
      _zoomed = z;
      widget.onZoomChanged?.call(z);
    }
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransform);
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InteractiveViewer(
        transformationController: _transform,
        maxScale: 6,
        // Pinch-zoom for images; double-tap-anywhere outside scaling is handled
        // by the gallery's tap-to-toggle-chrome (deferToChild).
        child: Image.network(
          widget.url,
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
  const _MediaPlayer({
    super.key,
    required this.url,
    required this.audioOnly,
    this.onTapSurface,
    this.onControllerReady,
  });
  final String url;
  final bool audioOnly;

  /// Called on a tap of the media surface (the parent toggles chrome / plays).
  final VoidCallback? onTapSurface;

  /// Reports the initialized controller up to the gallery so the immersive
  /// bottom bar + center play button can drive it. Fired once init completes.
  final ValueChanged<VideoPlayerController>? onControllerReady;

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
    //   2. attach a listener so the surface rebuilds (the active page's
    //      controls live in the parent gallery, but we still rebuild the
    //      surface on ticks for the video frame),
    //   3. await initialize() BEFORE showing controls, then report the
    //      controller up so the parent can wire the bottom bar + center play.
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
      // Hand the live controller to the gallery (post-frame so the parent's
      // setState lands after this build).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onControllerReady?.call(c);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  /// Rebuild on every controller tick so the video frame stays current. The
  /// play/pause icon + progress + position readout live in the parent gallery's
  /// bottom bar (driven by the same controller), guarded by mounted.
  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
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
              size: 120,
              color: SovereignColors.soulLumina,
            ),
          )
        : AspectRatio(
            aspectRatio:
                c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
            child: VideoPlayer(c),
          );

    // The surface fills the box BETWEEN the bars (the gallery already inset us);
    // BoxFit.contain via AspectRatio keeps the whole frame visible. A tap is a
    // user gesture (unlocks web audio) — the parent decides play vs toggle.
    return GestureDetector(
      onTap: widget.onTapSurface,
      behavior: HitTestBehavior.opaque,
      child: Center(child: surface),
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

// ── Immersive viewer chrome (top bar / bottom control bar / center play) ─────

/// Heights of the translucent bars (excluding the safe-area insets the parent
/// adds). Used both to size the bars and to inset the media's contain-box so
/// the media is shrunk to fit BETWEEN them — never overlapped.
const double _kTopBarHeight = 56;
const double _kBottomBarHeight = 96;

/// Fades + slides the chrome in/out for the auto-hide / tap-to-toggle behaviour.
/// Stays mounted (IgnorePointer when hidden) so toggling is cheap + the hit
/// area is gone while invisible.
class _AnimatedChrome extends StatelessWidget {
  const _AnimatedChrome({
    required this.visible,
    required this.alignment,
    required this.child,
  });
  final bool visible;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }
}

/// The translucent top bar over the media: close ✕ (left), filename + a
/// `node · i / total` counter (center), options ⋮ (right). Respects the top
/// safe-area inset ([topInset]) so the notch / status bar never clips it.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.topInset,
    required this.title,
    required this.subtitle,
    required this.onClose,
    required this.onOptions,
  });
  final double topInset;
  final String title;
  final String subtitle;
  final VoidCallback onClose;
  final VoidCallback onOptions;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(top: topInset),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.72),
            Colors.black.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: SizedBox(
        height: _kTopBarHeight,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close_rounded,
                  color: SovereignColors.textPrimary),
              tooltip: 'Close',
              onPressed: onClose,
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: SovereignColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: SovereignColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert_rounded,
                  color: SovereignColors.textPrimary),
              tooltip: 'Options',
              onPressed: onOptions,
            ),
          ],
        ),
      ),
    );
  }
}

/// The translucent bottom control bar for video/audio: play/pause, a scrubbable
/// [VideoProgressIndicator], and the `m:ss / m:ss` position/duration readout.
/// Pinned ABOVE the bottom safe-area inset ([bottomInset]) so the iOS home
/// indicator / browser chrome never sits over the controls (the original bug).
class _BottomControlBar extends StatelessWidget {
  const _BottomControlBar({
    required this.controller,
    required this.bottomInset,
    required this.onToggle,
  });
  final VideoPlayerController controller;
  final double bottomInset;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    final isPlaying = v.isPlaying;
    return Container(
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.78),
            Colors.black.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 10),
        child: Row(
          children: [
            IconButton(
              key: const Key('skosBottomBarPlayPause'),
              iconSize: 34,
              tooltip: isPlaying ? 'Pause' : 'Play',
              color: SovereignColors.textPrimary,
              icon: Icon(isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded),
              onPressed: onToggle,
            ),
            Expanded(
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 12),
                colors: const VideoProgressColors(
                  playedColor: SovereignColors.soulLumina,
                  bufferedColor: SovereignColors.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${_fmtDuration(v.position)} / ${_fmtDuration(v.duration)}',
              style: const TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The large circular center play overlay shown on a paused video — the
/// standard gallery affordance. Tapping it starts playback (+ sound).
class _CenterPlayButton extends StatelessWidget {
  const _CenterPlayButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('skosCenterPlay'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.5),
          border: Border.all(
            color: SovereignColors.textPrimary.withValues(alpha: 0.85),
            width: 2,
          ),
        ),
        child: const Icon(
          Icons.play_arrow_rounded,
          size: 46,
          color: SovereignColors.textPrimary,
        ),
      ),
    );
  }
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
