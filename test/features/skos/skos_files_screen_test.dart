import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/features/skos/access_client.dart';
import 'package:skchat/features/skos/skos_files_screen.dart';
import 'package:skchat/features/skos/skos_models.dart';
import 'package:skchat/core/theme/glass_widgets.dart';
import 'package:skchat/features/skos/skos_providers.dart';
import 'package:video_player/video_player.dart';

/// A no-plugin [VideoPlayerController]: [initialize] flips the initialized flag
/// (+ a fake duration), [play]/[pause] flip `isPlaying`. Assigning `value =`
/// goes through [ValueNotifier]'s setter, which fires listeners — exactly the
/// path the real controller uses to drive the play/pause icon — so this fake
/// exercises the real init → listener → toggle wiring inside the media player.
class _FakeVideoController extends VideoPlayerController {
  _FakeVideoController() : super.networkUrl(Uri.parse('http://x/test.mp4'));

  @override
  Future<void> initialize() async {
    value = value.copyWith(
      duration: const Duration(seconds: 30),
      isInitialized: true,
    );
  }

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    value = value.copyWith(position: position);
  }

  @override
  Future<void> dispose() async {
    // No platform texture; just drop the ValueNotifier listeners.
    super.dispose();
  }
}

/// A deterministic, no-latency client returning a fixed tree + hits so the
/// Files surface is testable offline. [writable] flips the write-scope path.
class _FixedClient implements AccessClient {
  _FixedClient({this.writable = false});

  final bool writable;

  /// Captures the last writeFile content (so the save test can assert).
  String? saved;

  @override
  bool get canWrite => writable;

  @override
  Future<List<FsEntry>> listRoots(String node) async => const [
        FsEntry(name: 'clawd', path: '/home/x/clawd', type: FsEntryType.dir),
      ];

  @override
  Future<List<FsEntry>> listDir(String node, String path) async {
    if (path == '/home/x/clawd') {
      return const [
        FsEntry(name: 'docs', path: '/home/x/clawd/docs', type: FsEntryType.dir),
        FsEntry(
            name: 'notes.md',
            path: '/home/x/clawd/notes.md',
            type: FsEntryType.file,
            size: 42),
      ];
    }
    return const [];
  }

  @override
  Future<String> readFile(String node, String path) async =>
      'hello from $path';

  @override
  Future<void> writeFile(String node, String path, String content) async {
    if (!writable) throw const AccessScopeException();
    saved = content;
  }

  @override
  Future<List<SearchHit>> search(String query, {int k = 10}) async => const [
        SearchHit(
          node: '.41',
          path: '/home/x/clawd/enroll.py',
          score: 0.91,
          snippet: 'the capauth enrollment bug lived here',
          docId: 'd1',
          source: 'code',
        ),
      ];

  @override
  Future<NodeInfo> nodeInfo(String node) async => NodeInfo(node: node, up: true);

  @override
  void dispose() {}
}

/// A minimal GoRouter that mirrors production: `/` = the Files browser, and the
/// full-screen `/skos/view` viewer route that `_openViewer` pushes. Using a
/// router (not a bare `MaterialApp(home:)`) is required now that opening a file
/// pushes the viewer through GoRouter (the close→root bugfix).
GoRouter _testRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SkosFilesScreen()),
        GoRoute(
          path: AppRoutes.skosView,
          builder: (_, _) => const SkosFileViewer(),
        ),
      ],
    );

Widget _app(AccessClient client) => ProviderScope(
      overrides: [
        accessClientProvider.overrideWithValue(client),
      ],
      child: MaterialApp.router(routerConfig: _testRouter()),
    );

void main() {
  testWidgets('Files screen renders the mock root listing', (tester) async {
    await tester.pumpWidget(_app(_FixedClient()));
    await tester.pumpAndSettle();

    // The header + the root entry render.
    expect(find.text('skos Files'), findsOneWidget);
    expect(find.text('clawd'), findsOneWidget);
    // Default node is the corpus primary.
    expect(find.text(kDefaultAccessNode), findsWidgets);
  });

  testWidgets('Tapping a directory descends into it', (tester) async {
    await tester.pumpWidget(_app(_FixedClient()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('clawd'));
    await tester.pumpAndSettle();

    // Descended → the dir's children show.
    expect(find.text('docs'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
  });

  testWidgets('Tapping a file opens the viewer', (tester) async {
    await tester.pumpWidget(_app(_FixedClient()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('clawd'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();

    // The viewer shows the file contents.
    expect(find.textContaining('hello from /home/x/clawd/notes.md'),
        findsOneWidget);
  });

  testWidgets('Viewer is read-only (lock, no edit) without write scope',
      (tester) async {
    await tester.pumpWidget(_app(_FixedClient(writable: false)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('clawd'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();

    // Read-only lock present, edit action absent.
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.edit_rounded), findsNothing);
  });

  testWidgets('Viewer exposes Edit when a write scope is granted',
      (tester) async {
    await tester.pumpWidget(_app(_FixedClient(writable: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('clawd'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.edit_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
  });

  testWidgets('Search shows corpus hits tagged with the owning node',
      (tester) async {
    await tester.pumpWidget(_app(_FixedClient()));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField).first, 'capauth enrollment');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The hit + its owning-node chip render.
    expect(find.textContaining('enrollment bug'), findsOneWidget);
    expect(find.text('.41'), findsWidgets);
  });

  testWidgets('Tapping a search hit opens that file', (tester) async {
    final client = _FixedClient();
    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField).first, 'capauth enrollment');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('enrollment bug'));
    await tester.pumpAndSettle();

    // Viewer opened for the hit's {node,path}.
    expect(find.textContaining('hello from /home/x/clawd/enroll.py'),
        findsOneWidget);
  });

  group('model parsers', () {
    test('FsEntry.fromJson tolerates type + is_dir spellings', () {
      final dir = FsEntry.fromJson({
        'name': 'docs',
        'path': '/home/x/clawd/docs',
        'type': 'dir',
      });
      expect(dir.isDir, isTrue);

      final file = FsEntry.fromJson({
        'path': '/home/x/clawd/notes.md',
        'is_dir': false,
        'size': 100,
        'mtime': '2026-06-22T12:00:00Z',
      });
      expect(file.isFile, isTrue);
      expect(file.name, 'notes.md'); // derived from path
      expect(file.size, 100);
      expect(file.mtime, isNotNull);
    });

    test('SearchHit.fromJson parses {node,path,score,snippet}', () {
      final h = SearchHit.fromJson({
        'node': '.158',
        'path': '/a/b.md',
        'score': 0.83,
        'snippet': 'matched text',
        'doc_id': 'x1',
        'source': 'wiki',
      });
      expect(h.node, '.158');
      expect(h.score, 0.83);
      expect(h.docId, 'x1');
    });

    test('NodeInfo.fromJson merges tools + roots + health', () {
      final info = NodeInfo.fromJson('.158', {
        'hostname': 'noroc2027',
        'tools': List.filled(12, {}),
        'exposed_roots': ['/home/x/clawd'],
        'ok': true,
      });
      expect(info.toolCount, 12);
      expect(info.exposedRoots, ['/home/x/clawd']);
      expect(info.up, isTrue);
      expect(NodeInfo.down('.41', detail: 'x').up, isFalse);
    });
  });

  test('MockAccessClient: read-only default + search + node info', () async {
    final c = MockAccessClient();
    expect(c.canWrite, isFalse);
    final roots = await c.listRoots('.158');
    expect(roots, isNotEmpty);
    final hits = await c.search('access plane');
    expect(hits, isNotEmpty);
    expect(() => c.writeFile('.158', '/x', 'y'),
        throwsA(isA<AccessScopeException>()));
    final info = await c.nodeInfo('.158');
    expect(info.up, isTrue);
    expect(info.exposedRoots, contains('/home/cbrd21/clawd'));
  });

  test('node→URL map covers both tailnet nodes', () {
    expect(kAccessNodes['.158'], contains('100.108.59.57:9386'));
    expect(kAccessNodes['.41'], contains('100.86.156.5:9386'));
  });

  group('mediaKindFor (extension → viewer surface)', () {
    test('image extensions', () {
      for (final p in [
        '/x/a.png',
        '/x/a.JPG',
        '/x/a.jpeg',
        '/x/a.gif',
        '/x/a.webp',
        '/x/a.bmp',
      ]) {
        expect(mediaKindFor(p), MediaKind.image, reason: p);
      }
    });

    test('video extensions (incl. the AI-LIFE masters)', () {
      for (final p in [
        '/x/master.mp4',
        '/x/clip.MOV',
        '/x/clip.webm',
        '/x/clip.m4v',
        '/x/clip.mkv',
      ]) {
        expect(mediaKindFor(p), MediaKind.video, reason: p);
      }
    });

    test('audio extensions', () {
      for (final p in [
        '/x/a.mp3',
        '/x/a.wav',
        '/x/a.m4a',
        '/x/a.ogg',
        '/x/a.flac',
      ]) {
        expect(mediaKindFor(p), MediaKind.audio, reason: p);
      }
    });

    test('pdf', () {
      expect(mediaKindFor('/x/doc.pdf'), MediaKind.pdf);
      expect(mediaKindFor('/x/DOC.PDF'), MediaKind.pdf);
    });

    test('markdown is distinct from plain text', () {
      expect(mediaKindFor('/x/readme.md'), MediaKind.markdown);
      expect(mediaKindFor('/x/notes.markdown'), MediaKind.markdown);
      expect(mediaKindFor('/x/notes.txt'), MediaKind.text);
    });

    test('code + config + extensionless resolve to text', () {
      for (final p in [
        '/x/main.dart',
        '/x/app.py',
        '/x/conf.yaml',
        '/x/data.json',
        '/x/LICENSE',
        '/x/Dockerfile',
      ]) {
        expect(mediaKindFor(p), MediaKind.text, reason: p);
      }
    });

    test('unknown binary falls through to other', () {
      expect(mediaKindFor('/x/blob.bin'), MediaKind.other);
      expect(mediaKindFor('/x/archive.zip'), MediaKind.other);
    });
  });

  test('mediaStreamUrl builds a same-origin /media/file URL', () {
    // NOTE: `Uri.base` is a `file:` URL under the Dart VM test runner (no
    // origin), so we assert the path/node query encoding — the part that does
    // not depend on origin. In the browser (the only runtime this ships on)
    // `Uri.base.origin` is the served http(s) origin.
    final url = mediaStreamUrl('.158', '/home/x/AI LIFE/master.mp4');
    expect(url, contains('/media/file?'));
    expect(url, contains('node=.158'));
    // The path is query-encoded (space + slashes survive a round-trip).
    final parsed = Uri.parse(url);
    expect(parsed.queryParameters['path'], '/home/x/AI LIFE/master.mp4');
    expect(parsed.queryParameters['node'], '.158');
  });

  // ── Swipe gallery + long-press options ──────────────────────────────────

  group('buildMediaGallery', () {
    const node = '.158';
    const dir = '/home/x/AI LIFE';
    final entries = <FsEntry>[
      const FsEntry(name: 'notes.md', path: '', type: FsEntryType.file),
      const FsEntry(name: 'a.png', path: '', type: FsEntryType.file),
      const FsEntry(name: 'sub', path: '', type: FsEntryType.dir),
      const FsEntry(name: 'b.mp4', path: '', type: FsEntryType.file),
      const FsEntry(name: 'c.mp3', path: '', type: FsEntryType.file),
      const FsEntry(name: 'd.pdf', path: '', type: FsEntryType.file),
    ];

    test('keeps only image/video/audio files, in listing order', () {
      final g = buildMediaGallery(
        node: node,
        currentDir: dir,
        entries: entries,
        openPath: '$dir/a.png',
      );
      expect(g.items.map((m) => m.name).toList(),
          ['a.png', 'b.mp4', 'c.mp3']);
      // dirs, markdown and pdf are excluded.
      expect(g.items.map((m) => m.kind).toList(),
          [MediaKind.image, MediaKind.video, MediaKind.audio]);
    });

    test('opens at the index of the tapped media file', () {
      final g = buildMediaGallery(
        node: node,
        currentDir: dir,
        entries: entries,
        openPath: '$dir/b.mp4',
      );
      expect(g.index, 1);
      expect(g.items[g.index].name, 'b.mp4');
    });

    test('non-media open path collapses to a single standalone item', () {
      final g = buildMediaGallery(
        node: node,
        currentDir: dir,
        entries: entries,
        openPath: '$dir/d.pdf',
      );
      expect(g.items.length, 1);
      expect(g.items.single.name, 'd.pdf');
      expect(g.index, 0);
    });

    test('builds full paths from currentDir + name when entry.path empty', () {
      final g = buildMediaGallery(
        node: node,
        currentDir: dir,
        entries: entries,
        openPath: '$dir/a.png',
      );
      expect(g.items.first.path, '$dir/a.png');
    });
  });

  testWidgets(
      'Immersive viewer is full-screen: no bottom-nav in its tree, opaque '
      'black backdrop, top bar with close + options', (tester) async {
    final entries = <FsEntry>[
      const FsEntry(name: 'a.png', path: '/m/a.png', type: FsEntryType.file),
      const FsEntry(name: 'b.png', path: '/m/b.png', type: FsEntryType.file),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessClientProvider.overrideWithValue(_FixedClient()),
          currentPathProvider.overrideWith((ref) => '/m'),
          dirListingProvider.overrideWith((ref) async => entries),
          openFileProvider
              .overrideWith((ref) => (node: '.158', path: '/m/a.png')),
        ],
        child: const MaterialApp(home: SkosFileViewer()),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The immersive viewer renders NO tab bottom-nav (it opens ABOVE the shell
    // on the root navigator, so the Chats/Spaces/Activity/Ops/Me bar — the
    // GlassNavBar — must never appear in its widget tree).
    expect(find.byType(GlassNavBar), findsNothing);

    // Opaque black backdrop (immersive). The viewer Scaffold is black.
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, const Color(0xFF000000));
    // No AppBar — the chrome is the custom translucent top bar instead.
    expect(scaffold.appBar, isNull);

    // Top bar affordances: close ✕ + options ⋮ (+ the counter).
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    expect(find.textContaining('1 / 2'), findsOneWidget);
  });

  testWidgets(
      'Viewer builds a PageView over the directory media list', (tester) async {
    final entries = <FsEntry>[
      const FsEntry(
          name: 'a.png', path: '/m/a.png', type: FsEntryType.file),
      const FsEntry(
          name: 'b.png', path: '/m/b.png', type: FsEntryType.file),
      const FsEntry(
          name: 'c.png', path: '/m/c.png', type: FsEntryType.file),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessClientProvider.overrideWithValue(_FixedClient()),
          currentPathProvider.overrideWith((ref) => '/m'),
          dirListingProvider.overrideWith((ref) async => entries),
          openFileProvider
              .overrideWith((ref) => (node: '.158', path: '/m/b.png')),
        ],
        child: const MaterialApp(home: SkosFileViewer()),
      ),
    );
    await tester.pump(); // build
    await tester.pump(); // let the async dirListing future resolve

    // The gallery surface is a PageView, opened on the tapped file's index.
    expect(find.byType(PageView), findsOneWidget);
    // Counter reflects 3 media, opened at index 1 (b.png -> "2 / 3").
    expect(find.textContaining('2 / 3'), findsOneWidget);
  });

  testWidgets('Long-press on a media page opens the options sheet',
      (tester) async {
    final entries = <FsEntry>[
      const FsEntry(
          name: 'a.png', path: '/m/a.png', type: FsEntryType.file),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessClientProvider.overrideWithValue(_FixedClient()),
          currentPathProvider.overrideWith((ref) => '/m'),
          dirListingProvider.overrideWith((ref) async => entries),
          openFileProvider
              .overrideWith((ref) => (node: '.158', path: '/m/a.png')),
        ],
        child: const MaterialApp(home: SkosFileViewer()),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byType(PageView));
    await tester.pumpAndSettle();

    // The Sovereign-Glass options sheet surfaces all four actions.
    expect(find.text('Share / Open in app'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Copy link'), findsOneWidget);
    expect(find.text('Send to chat (soon)'), findsOneWidget);
  });

  testWidgets(
      'Viewer routes an image file to the streaming image surface '
      '(no text edit affordance)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessClientProvider.overrideWithValue(_FixedClient(writable: true)),
          openFileProvider
              .overrideWith((ref) => (node: '.158', path: '/x/pic.png')),
        ],
        child: const MaterialApp(home: SkosFileViewer()),
      ),
    );
    await tester.pump(); // initState/build (network image load stays pending)

    // The binary-media path never exposes the text Save/Edit affordance, even
    // with a write scope granted; the lock (text read-only) is also absent.
    expect(find.byIcon(Icons.edit_rounded), findsNothing);
    expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.save_rounded), findsNothing);
    // Image kind → InteractiveViewer-wrapped streaming Image surface.
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  // ── Playback: the play/pause button actually toggles the controller ───────

  group('media playback controls', () {
    late _FakeVideoController fake;

    setUp(() {
      fake = _FakeVideoController();
      // Route _MediaPlayer through the fake so we can assert the real
      // init → listener → toggle wiring without a platform video plugin.
      debugMediaControllerFactory = (_) => fake;
    });

    tearDown(() {
      debugMediaControllerFactory = null;
    });

    testWidgets('play/pause button toggles isPlaying on the controller',
        (tester) async {
      final entries = <FsEntry>[
        const FsEntry(name: 'clip.mp4', path: '/m/clip.mp4', type: FsEntryType.file),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accessClientProvider.overrideWithValue(_FixedClient()),
            currentPathProvider.overrideWith((ref) => '/m'),
            dirListingProvider.overrideWith((ref) async => entries),
            openFileProvider
                .overrideWith((ref) => (node: '.158', path: '/m/clip.mp4')),
          ],
          child: const MaterialApp(home: SkosFileViewer()),
        ),
      );
      // build → dirListing future resolves → initialize() completes →
      // onControllerReady (post-frame) → the immersive bottom control bar +
      // center play button mount.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Initialized but not playing → the bottom-bar Play button + the
      // prominent center play overlay are both present; isPlaying false.
      expect(fake.value.isPlaying, isFalse);
      final bottomBtn = find.byKey(const Key('skosBottomBarPlayPause'));
      expect(bottomBtn, findsOneWidget);
      expect(find.byKey(const Key('skosCenterPlay')), findsOneWidget);

      // Tap the bottom-bar Play button → controller starts; the listener flips
      // the icon to Pause and the center overlay fades out.
      await tester.tap(bottomBtn);
      await tester.pump();
      expect(fake.value.isPlaying, isTrue);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byKey(const Key('skosCenterPlay')), findsNothing);

      // Tap Pause → controller pauses; the play icon comes back.
      await tester.tap(bottomBtn);
      await tester.pump();
      expect(fake.value.isPlaying, isFalse);
    });

    testWidgets('center play overlay starts playback (paused video affordance)',
        (tester) async {
      final entries = <FsEntry>[
        const FsEntry(name: 'clip.mp4', path: '/m/clip.mp4', type: FsEntryType.file),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accessClientProvider.overrideWithValue(_FixedClient()),
            currentPathProvider.overrideWith((ref) => '/m'),
            dirListingProvider.overrideWith((ref) async => entries),
            openFileProvider
                .overrideWith((ref) => (node: '.158', path: '/m/clip.mp4')),
          ],
          child: const MaterialApp(home: SkosFileViewer()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The big center play button is shown while paused → tapping it plays.
      final center = find.byKey(const Key('skosCenterPlay'));
      expect(center, findsOneWidget);
      await tester.tap(center);
      await tester.pump();
      expect(fake.value.isPlaying, isTrue);
      // Once playing, the center overlay is gone (standard gallery behaviour).
      expect(find.byKey(const Key('skosCenterPlay')), findsNothing);
    });

    testWidgets('audio shows a scrubbable progress + play/pause that works',
        (tester) async {
      final entries = <FsEntry>[
        const FsEntry(name: 'song.mp3', path: '/m/song.mp3', type: FsEntryType.file),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accessClientProvider.overrideWithValue(_FixedClient()),
            currentPathProvider.overrideWith((ref) => '/m'),
            dirListingProvider.overrideWith((ref) async => entries),
            openFileProvider
                .overrideWith((ref) => (node: '.158', path: '/m/song.mp3')),
          ],
          child: const MaterialApp(home: SkosFileViewer()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Audio surface: a real scrubbable progress indicator + working toggle.
      expect(find.byType(VideoProgressIndicator), findsOneWidget);
      await tester.tap(find.byKey(const Key('skosBottomBarPlayPause')));
      await tester.pump();
      expect(fake.value.isPlaying, isTrue);
    });
  });

  // ── New UX fixes: drag-to-dismiss, tap-toggles-chrome, close preserves dir ──

  /// True when the top-bar chrome (the ✕ row) is currently shown. The chrome is
  /// hidden by fading to opacity 0 (it stays mounted), so presence of the ✕ icon
  /// is NOT a reliable signal — read the wrapping AnimatedOpacity instead.
  bool chromeShown(WidgetTester tester) {
    final close = find.byIcon(Icons.close_rounded);
    if (close.evaluate().isEmpty) return false;
    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: close, matching: find.byType(AnimatedOpacity)).first,
    );
    return opacity.opacity > 0.5;
  }


  /// Build the viewer behind a real GoRouter at a NON-root browsed dir, so we
  /// can drag/close it and assert what we return to. Returns the container so
  /// tests can read currentPathProvider after the pop.
  ProviderContainer viewerContainer(List<FsEntry> entries, FileRef open,
      {String dir = '/home/x/clawd/our-pics/lumina-portraits'}) {
    return ProviderContainer(overrides: [
      accessClientProvider.overrideWithValue(_FixedClient()),
      currentPathProvider.overrideWith((ref) => dir),
      dirListingProvider.overrideWith((ref) async => entries),
      openFileProvider.overrideWith((ref) => open),
    ]);
  }

  GoRouter viewerRouter() => GoRouter(
        initialLocation: '/skos/files',
        routes: [
          GoRoute(
            path: '/skos/files',
            builder: (_, _) => const SkosFilesScreen(),
          ),
          GoRoute(
            path: AppRoutes.skosView,
            builder: (_, _) => const SkosFileViewer(),
          ),
        ],
      );

  testWidgets('drag-to-dismiss: a downward drag past threshold pops the viewer',
      (tester) async {
    final entries = <FsEntry>[
      const FsEntry(name: 'a.png', path: '/m/a.png', type: FsEntryType.file),
      const FsEntry(name: 'b.png', path: '/m/b.png', type: FsEntryType.file),
    ];
    final container = viewerContainer(
      entries,
      (node: '.158', path: '/m/a.png'),
    );
    addTearDown(container.dispose);
    final router = viewerRouter();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.pump();
    // Drive onto the viewer route.
    router.push(AppRoutes.skosView);
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    // Drag the media surface DOWN well past the 120px dismiss threshold.
    await tester.drag(find.byType(PageView), const Offset(0, 320));
    await tester.pumpAndSettle();

    // The viewer route popped — we are back on the Files browser, no viewer.
    expect(find.byType(SkosFileViewer), findsNothing);
    expect(find.byType(PageView), findsNothing);
    expect(find.text('skos Files'), findsOneWidget);
  });

  testWidgets('drag-to-dismiss: an UPWARD drag past threshold also pops',
      (tester) async {
    final entries = <FsEntry>[
      const FsEntry(name: 'a.png', path: '/m/a.png', type: FsEntryType.file),
    ];
    final container = viewerContainer(
      entries,
      (node: '.158', path: '/m/a.png'),
    );
    addTearDown(container.dispose);
    final router = viewerRouter();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.pump();
    router.push(AppRoutes.skosView);
    await tester.pumpAndSettle();
    expect(find.byType(PageView), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(0, -320));
    await tester.pumpAndSettle();

    expect(find.byType(SkosFileViewer), findsNothing);
    expect(find.text('skos Files'), findsOneWidget);
  });

  testWidgets('drag-to-dismiss: a small drag under threshold snaps back (stays)',
      (tester) async {
    final entries = <FsEntry>[
      const FsEntry(name: 'a.png', path: '/m/a.png', type: FsEntryType.file),
    ];
    final container = viewerContainer(
      entries,
      (node: '.158', path: '/m/a.png'),
    );
    addTearDown(container.dispose);
    final router = viewerRouter();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.pump();
    router.push(AppRoutes.skosView);
    await tester.pumpAndSettle();

    // A short, slow drag (under the 120px threshold) must NOT dismiss.
    await tester.drag(find.byType(PageView), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(find.byType(SkosFileViewer), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  group('tap toggles chrome (decoupled from play)', () {
    late _FakeVideoController fake;
    setUp(() {
      fake = _FakeVideoController();
      debugMediaControllerFactory = (_) => fake;
    });
    tearDown(() {
      debugMediaControllerFactory = null;
    });

    testWidgets(
        'a tap on the surface toggles the chrome ✕ without changing playback',
        (tester) async {
      final entries = <FsEntry>[
        const FsEntry(
            name: 'clip.mp4', path: '/m/clip.mp4', type: FsEntryType.file),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accessClientProvider.overrideWithValue(_FixedClient()),
            currentPathProvider.overrideWith((ref) => '/m'),
            dirListingProvider.overrideWith((ref) async => entries),
            openFileProvider
                .overrideWith((ref) => (node: '.158', path: '/m/clip.mp4')),
          ],
          child: const MaterialApp(home: SkosFileViewer()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Chrome starts visible; nothing is playing.
      expect(chromeShown(tester), isTrue);
      expect(fake.value.isPlaying, isFalse);

      // Start playback via the bottom-bar button (the ONLY play path), then let
      // the 3 s auto-hide fade the chrome out.
      await tester.tap(find.byKey(const Key('skosBottomBarPlayPause')));
      await tester.pump();
      expect(fake.value.isPlaying, isTrue);
      await tester.pump(const Duration(seconds: 4)); // auto-hide elapses
      await tester.pump(const Duration(milliseconds: 300)); // fade out
      expect(chromeShown(tester), isFalse);

      // ONE tap on the surface brings the chrome back — and does NOT pause.
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(chromeShown(tester), isTrue);
      expect(fake.value.isPlaying, isTrue); // playback untouched by the tap

      // Tapping again hides the chrome (still playing) — a true toggle.
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(chromeShown(tester), isFalse);
      expect(fake.value.isPlaying, isTrue);
    });
  });

  testWidgets(
      'tap toggles chrome on an IMAGE (✕ hides then re-shows on next tap)',
      (tester) async {
    final entries = <FsEntry>[
      const FsEntry(name: 'a.png', path: '/m/a.png', type: FsEntryType.file),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessClientProvider.overrideWithValue(_FixedClient()),
          currentPathProvider.overrideWith((ref) => '/m'),
          dirListingProvider.overrideWith((ref) async => entries),
          openFileProvider
              .overrideWith((ref) => (node: '.158', path: '/m/a.png')),
        ],
        child: const MaterialApp(home: SkosFileViewer()),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Chrome visible on entry.
    expect(chromeShown(tester), isTrue);
    // One tap on the surface hides it…
    await tester.tapAt(tester.getCenter(find.byType(PageView)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(chromeShown(tester), isFalse);
    // …another tap brings the ✕ back (never stranded).
    await tester.tapAt(tester.getCenter(find.byType(PageView)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(chromeShown(tester), isTrue);
  });

  testWidgets(
      'closing the viewer preserves currentPathProvider (returns to same dir)',
      (tester) async {
    const dir = '/home/x/clawd/our-pics/lumina-portraits';
    final entries = <FsEntry>[
      const FsEntry(name: 'a.png', path: '$dir/a.png', type: FsEntryType.file),
    ];
    final container = viewerContainer(
      entries,
      (node: '.158', path: '$dir/a.png'),
      dir: dir,
    );
    addTearDown(container.dispose);
    final router = viewerRouter();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.pump();

    expect(container.read(currentPathProvider), dir);
    router.push(AppRoutes.skosView);
    await tester.pumpAndSettle();
    // Opening the viewer must NOT change the browsed dir.
    expect(container.read(currentPathProvider), dir);

    // Close via the ✕ — pops back to the Files screen.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    // Back on the Files browser, STILL in the same folder (not root).
    expect(find.byType(SkosFileViewer), findsNothing);
    expect(find.text('skos Files'), findsOneWidget);
    expect(container.read(currentPathProvider), dir);
  });
}
