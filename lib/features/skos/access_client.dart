import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'skos_models.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// AccessClient, the ADAPTER SEAM for the per-node `sk-access` MCP (P7).
/// ─────────────────────────────────────────────────────────────────────────
///
/// The skos surfaces (Files browser, corpus search, control panel) talk ONLY to
/// this interface and never care whether the bytes come from a mock, a daemon
/// over the tailnet, or (later) a federated route. To go live, implement this
/// one interface ([DaemonAccessClient] is the skeleton) and swap which client
/// `accessClientProvider` returns, no UI changes required.
///
/// Backed by the access plane documented in `skcomms/docs/access-plane-p7.md`:
/// one capauth-gated `sk-access` MCP per node on the tailnet, tools:
///   `pg_search`, `pg_locate`, `file_list`, `file_read`, `file_write`,
///   `file_stat`, `list_roots`, `node_info`, `health`.
/// Calls are POST `/tool` `{"token": `SignedEnvelope`, "tool",
/// "arguments"}`; **read-only by default** (write needs a granted scope).
abstract class AccessClient {
  /// `list_roots(node)` → the exposed-root allowlist for [node]
  /// (the top-level dirs the file tools are scoped to, e.g. `~/clawd`).
  Future<List<FsEntry>> listRoots(String node);

  /// `file_list(node, path)` → the directory listing at [path] on [node].
  Future<List<FsEntry>> listDir(String node, String path);

  /// `file_read(node, path)` → the text contents of [path] on [node]
  /// (streamed over the tailnet; large/binary handling is a P7 open question).
  Future<String> readFile(String node, String path);

  /// `file_write(node, path, content)` → write [content] to [path] on [node].
  /// Requires a granted **write scope**; throws [AccessScopeException] when the
  /// caller's identity has read-only access (the default).
  Future<void> writeFile(String node, String path, String content);

  /// `pg_search(query, k)` → hybrid (vector+BM25) corpus search across the
  /// fabric; each hit is tagged with the owning `{node, path}`.
  Future<List<SearchHit>> search(String query, {int k = 10});

  /// `node_info(node)` + `health(node)` → identity + capabilities + up/down.
  Future<NodeInfo> nodeInfo(String node);

  /// Whether this client currently holds a granted **write scope**. Drives the
  /// read-only affordance in the Files viewer. Default false (read-only).
  bool get canWrite => false;

  /// Free any resources (HTTP clients, etc.).
  void dispose() {}
}

/// Thrown by [AccessClient.writeFile] when the caller lacks a write scope.
class AccessScopeException implements Exception {
  const AccessScopeException([this.message = 'Write scope not granted']);
  final String message;
  @override
  String toString() => 'AccessScopeException: $message';
}

/// ─────────────────────────────────────────────────────────────────────────
/// kAccessNodes, the node → base-URL map (tailnet `sk-access` endpoints).
/// ─────────────────────────────────────────────────────────────────────────
///
/// From the P7 deploy notes: `sk-access` is LIVE on both boxes, tailnet-only,
/// capauth-gated, on port 9386. Keyed by the short node label that also tags
/// each [SearchHit.node]. These are the **tailnet** (100.x) addresses, never
/// public / the Funnel (the Postgres + file fabric is private node-to-node).
const Map<String, String> kAccessNodes = {
  // .158 noroc2027 (PRIMARY: skmem-pg primary + access MCP)
  '.158': 'http://100.108.59.57:9386',
  // .41 cbrd21-laptop (hot-standby replica + access MCP)
  '.41': 'http://100.86.156.5:9386',
};

/// The default node a fresh skos surface points at (the corpus primary, .158).
const String kDefaultAccessNode = '.158';

/// Human label for a node key (shown in the picker / control panel).
String accessNodeLabel(String node) {
  switch (node) {
    case '.158':
      return '.158 · noroc2027 (primary)';
    case '.41':
      return '.41 · cbrd21-laptop (replica)';
    default:
      return node;
  }
}

/// ─────────────────────────────────────────────────────────────────────────
/// MockAccessClient, v1 demonstrable client (no backend / no tailnet).
/// ─────────────────────────────────────────────────────────────────────────
///
/// Serves a small fake `~/clawd` tree per node plus fake corpus hits so the
/// Files browser, viewer, search, and control panel are fully demoable and
/// widget-testable offline. Read-only by default ([canWrite] = false) so the
/// viewer's Save affordance is correctly disabled, flip [writable] true to
/// exercise the write path in a demo.
class MockAccessClient implements AccessClient {
  MockAccessClient({this.writable = false});

  /// When true, [writeFile] succeeds (and [canWrite] is true), used to demo
  /// the granted-write-scope path. Default false = read-only (the real default).
  final bool writable;

  @override
  bool get canWrite => writable;

  // A tiny in-memory tree rooted at /home/cbrd21/clawd, per node. Directories
  // end with '/'; files map to their (editable) contents.
  late final Map<String, Map<String, String?>> _fs = {
    '.158': {
      '/home/cbrd21/clawd': null, // root marker (dir)
      '/home/cbrd21/clawd/docs/': null,
      '/home/cbrd21/clawd/wiki/': null,
      '/home/cbrd21/clawd/notes.md':
          '# Sovereign notes\n\nThe access plane collapses the fleet into one '
              'brain + one disk.\n',
      '/home/cbrd21/clawd/docs/access-plane-p7.md':
          '# P7, The Access Plane\n\nAny agent on the tailnet can search the '
              'corpus and read/write any file on any node, capauth-gated.\n',
      '/home/cbrd21/clawd/docs/redundancy.md':
          'If you need one, get two. No single point of failure.\n',
      '/home/cbrd21/clawd/wiki/index.md':
          '# Wiki\n\nKarpathy-style sovereign knowledge base.\n',
    },
    '.41': {
      '/home/cbrd21/clawd': null,
      '/home/cbrd21/clawd/skcapstone-repos/': null,
      '/home/cbrd21/clawd/enroll.py':
          'def enroll(identity):\n    # the capauth enrollment bug lived here\n'
              '    return verify(identity)\n',
      '/home/cbrd21/clawd/skcapstone-repos/README.md':
          '# SK repos (laptop mirror)\n',
    },
  };

  Map<String, String?> _treeFor(String node) =>
      _fs[node] ?? const <String, String?>{};

  String _normalize(String path) {
    var p = path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  @override
  Future<List<FsEntry>> listRoots(String node) async {
    await _latency();
    final tree = _treeFor(node);
    if (tree.isEmpty) return const [];
    // The single exposed root is ~/clawd for both nodes (P7 allowlist).
    const root = '/home/cbrd21/clawd';
    if (!tree.containsKey(root)) return const [];
    return [
      FsEntry(name: 'clawd', path: root, type: FsEntryType.dir),
    ];
  }

  @override
  Future<List<FsEntry>> listDir(String node, String path) async {
    await _latency();
    final tree = _treeFor(node);
    final dir = _normalize(path);
    final prefix = dir.endsWith('/') ? dir : '$dir/';

    final seen = <String>{};
    final entries = <FsEntry>[];
    for (final key in tree.keys) {
      final norm = key.endsWith('/') ? key.substring(0, key.length - 1) : key;
      if (norm == dir) continue; // the dir itself
      if (!norm.startsWith(prefix)) continue;
      final rest = norm.substring(prefix.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash >= 0) {
        // Nested → surface the immediate child directory once.
        final childName = rest.substring(0, slash);
        if (seen.add(childName)) {
          entries.add(FsEntry(
            name: childName,
            path: '$prefix$childName',
            type: FsEntryType.dir,
          ));
        }
      } else {
        // Immediate child (file or explicit dir marker key).
        if (!seen.add(rest)) continue;
        final isDir = key.endsWith('/');
        entries.add(FsEntry(
          name: rest,
          path: '$prefix$rest',
          type: isDir ? FsEntryType.dir : FsEntryType.file,
          size: isDir ? null : (tree[key]?.length ?? 0),
          mtime: DateTime.now().toUtc(),
        ));
      }
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<String> readFile(String node, String path) async {
    await _latency();
    final tree = _treeFor(node);
    final key = _normalize(path);
    final content = tree[key];
    if (content == null) {
      throw AccessScopeException('No such file: $node:$key');
    }
    return content;
  }

  @override
  Future<void> writeFile(String node, String path, String content) async {
    await _latency();
    if (!writable) throw const AccessScopeException();
    final tree = _fs[node];
    if (tree == null) throw AccessScopeException('Unknown node: $node');
    tree[_normalize(path)] = content;
  }

  @override
  Future<List<SearchHit>> search(String query, {int k = 10}) async {
    await _latency();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits = <SearchHit>[];
    for (final node in _fs.keys) {
      _fs[node]!.forEach((path, content) {
        if (content == null) return; // dir
        final hay = '$path\n$content'.toLowerCase();
        if (q.split(RegExp(r'\s+')).any((t) => t.isNotEmpty && hay.contains(t))) {
          final idx = content.toLowerCase().indexOf(q.split(' ').first);
          final start = idx < 0 ? 0 : (idx - 20).clamp(0, content.length);
          final end = (start + 120).clamp(0, content.length);
          hits.add(SearchHit(
            node: node,
            path: path,
            score: 0.9 - hits.length * 0.07,
            snippet: content.substring(start, end).replaceAll('\n', ' ').trim(),
            docId: 'mock-${hits.length}',
            source: path.endsWith('.md') ? 'wiki' : 'code',
          ));
        }
      });
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(k).toList();
  }

  @override
  Future<NodeInfo> nodeInfo(String node) async {
    await _latency();
    if (!_fs.containsKey(node)) {
      return NodeInfo.down(node, detail: 'Unknown node (mock)');
    }
    return NodeInfo(
      node: node,
      up: true,
      hostname: node == '.158' ? 'noroc2027' : 'cbrd21-laptop',
      toolCount: 12, // 10 + node_info + health (per P7 deploy)
      exposedRoots: const ['/home/cbrd21/clawd'],
      version: 'mock-0.1.0',
      detail: node == '.158'
          ? 'skmem-pg primary · read-only access'
          : 'hot-standby replica · read-only access',
    );
  }

  Future<void> _latency() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  @override
  void dispose() {}
}

/// ─────────────────────────────────────────────────────────────────────────
/// DaemonAccessClient, LIVE-CLIENT SKELETON (the integration point).
/// ─────────────────────────────────────────────────────────────────────────
///
/// POSTs to each node's `sk-access` `/tool` endpoint over the tailnet. This is
/// the ONLY file that needs to change to go live. There is exactly ONE thing to
/// wire, the capauth token (see [tokenForCall]), flagged with a single clear
/// TODO below. Everything else (base-URL map, request envelope, result parsing)
/// is done.
///
/// Wire it in by editing `accessClientProvider` in `skos_providers.dart`:
/// ```dart
/// final accessClientProvider = Provider<AccessClient>((ref) {
///   final signer = ref.watch(pgpCapauthSignerProvider); // existing app identity
///   return DaemonAccessClient(
///     dio: Dio(),
///     tokenForCall: (node, tool, args) => signer.signAccessEnvelope(
///       node: node, tool: tool, arguments: args,        // capauth SignedEnvelope
///     ),
///     canWriteOverride: false, // flip once a write scope is granted to this id
///   );
/// });
/// ```
class DaemonAccessClient implements AccessClient {
  DaemonAccessClient({
    required this.tokenForCall,
    Dio? dio,
    Map<String, String> nodes = kAccessNodes,
    bool canWriteOverride = false,
  })  : _dio = dio ?? Dio(),
        _nodes = nodes,
        _canWrite = canWriteOverride;

  /// ▶▶ THE ONE THING TO WIRE ◀◀
  ///
  /// Produces the **capauth SignedEnvelope** string that authorizes a single
  /// `/tool` call. The token comes from the app's own identity/daemon, the
  /// PGP/capauth signer already in the app (`pgp_capauth_signer.dart` /
  /// `capauth_service.dart`), NOT from any crypto invented here in Dart.
  ///
  /// TODO(P9-live): replace the `accessClientProvider` mock with a
  /// [DaemonAccessClient] and pass a real `tokenForCall` that asks the app's
  /// capauth signer to sign an access-plane envelope binding {node, tool,
  /// arguments} for the local identity. Read-only by default; a write scope
  /// must be granted server-side (`python -m skcomms.access.grants`) and
  /// reflected via [canWriteOverride].
  final Future<String> Function(
    String node,
    String tool,
    Map<String, dynamic> arguments,
  ) tokenForCall;

  final Dio _dio;
  final Map<String, String> _nodes;
  final bool _canWrite;

  @override
  bool get canWrite => _canWrite;

  String _baseUrl(String node) {
    final base = _nodes[node];
    if (base == null) {
      throw AccessScopeException('No sk-access base URL for node $node');
    }
    return base;
  }

  /// The `/tool` endpoint. On web, route through the same-origin webui proxy
  /// (`/access/tool`) so the app works over ANY origin, localhost, the https
  /// funnel, a cloudflared tunnel, with no mixed-content and without the
  /// browser needing to reach a tailnet IP directly. Native talks to the
  /// node's sk-access endpoint directly.
  String _toolUrl(String node) {
    if (kIsWeb) {
      try {
        return '${Uri.base.origin}/access/tool';
      } catch (_) {
        // file: base (test runner), fall through to the direct node URL.
      }
    }
    return '${_baseUrl(node)}/tool';
  }

  /// POST `/tool` `{"token", "tool", "arguments"}` to [node]'s sk-access MCP and
  /// return the decoded result payload.
  Future<dynamic> _callTool(
    String node,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final token = await tokenForCall(node, tool, arguments);
    final resp = await _dio.post<dynamic>(
      _toolUrl(node),
      data: {
        'node': node,
        'token': token,
        'tool': tool,
        'arguments': arguments,
      },
      options: Options(contentType: 'application/json'),
    );
    final data = resp.data;
    // Tolerate either a bare result or `{result: ...}` / `{content: ...}` wrap.
    if (data is Map && data.containsKey('result')) return data['result'];
    if (data is Map && data.containsKey('content')) return data['content'];
    return data;
  }

  List<Map<String, dynamic>> _asList(dynamic raw) {
    if (raw is List) return raw.whereType<Map>().map(_asMap).toList();
    if (raw is Map) {
      for (final key in ['entries', 'items', 'results', 'hits', 'roots']) {
        final v = raw[key];
        if (v is List) return v.whereType<Map>().map(_asMap).toList();
      }
    }
    return const [];
  }

  Map<String, dynamic> _asMap(dynamic m) =>
      (m as Map).map((k, v) => MapEntry(k.toString(), v));

  @override
  Future<List<FsEntry>> listRoots(String node) async {
    final raw = await _callTool(node, 'list_roots', const {});
    // list_roots returns a list of path STRINGS (not objects like file_list),
    // so map each path → a dir entry. Fall back to object parsing if a server
    // ever returns structured roots.
    if (raw is List) {
      return raw.map<FsEntry>((e) {
        if (e is String) {
          final parts = e.split('/').where((s) => s.isNotEmpty);
          final name = parts.isEmpty ? e : parts.last;
          return FsEntry(name: name, path: e, type: FsEntryType.dir);
        }
        return FsEntry.fromJson(_asMap(e));
      }).toList();
    }
    return _asList(raw).map(FsEntry.fromJson).toList();
  }

  @override
  Future<List<FsEntry>> listDir(String node, String path) async {
    final raw = await _callTool(node, 'file_list', {'dir': path});
    return _asList(raw).map(FsEntry.fromJson).toList();
  }

  @override
  Future<String> readFile(String node, String path) async {
    final raw = await _callTool(node, 'file_read', {'path': path});
    if (raw is String) return raw;
    if (raw is Map) {
      return (raw['content'] ?? raw['text'] ?? raw['data'] ?? '').toString();
    }
    return raw?.toString() ?? '';
  }

  @override
  Future<void> writeFile(String node, String path, String content) async {
    if (!_canWrite) throw const AccessScopeException();
    await _callTool(node, 'file_write', {'path': path, 'content': content});
  }

  @override
  Future<List<SearchHit>> search(String query, {int k = 10}) async {
    // pg_search runs on the corpus primary; results are tagged with the owning
    // node so cross-node fetches route correctly (P7 A5 federation routing).
    final raw = await _callTool(
      kDefaultAccessNode,
      'pg_search',
      {'query': query, 'k': k},
    );
    return _asList(raw).map(SearchHit.fromJson).toList();
  }

  @override
  Future<NodeInfo> nodeInfo(String node) async {
    try {
      final info = await _callTool(node, 'node_info', const {});
      final infoMap = info is Map ? _asMap(info) : <String, dynamic>{};
      // Fold in health() (up/down) when available.
      try {
        final health = await _callTool(node, 'health', const {});
        if (health is Map) infoMap.addAll(_asMap(health));
      } catch (_) {/* node_info alone is enough to render */}
      return NodeInfo.fromJson(node, infoMap);
    } catch (e) {
      return NodeInfo.down(node, detail: e.toString());
    }
  }

  @override
  void dispose() => _dio.close(force: true);
}
