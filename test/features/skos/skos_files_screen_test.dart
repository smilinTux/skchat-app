import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/skos/access_client.dart';
import 'package:skchat/features/skos/skos_files_screen.dart';
import 'package:skchat/features/skos/skos_models.dart';
import 'package:skchat/features/skos/skos_providers.dart';

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

Widget _app(AccessClient client) => ProviderScope(
      overrides: [
        accessClientProvider.overrideWithValue(client),
      ],
      child: const MaterialApp(home: SkosFilesScreen()),
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
}
