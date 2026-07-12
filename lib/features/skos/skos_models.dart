import 'package:flutter/foundation.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// skos access-plane (P7/P9) view models.
/// ─────────────────────────────────────────────────────────────────────────
///
/// These are the app-side, transport-agnostic shapes the skos Files / corpus
/// search / control surfaces watch. They are produced by an [AccessClient]
/// adapter from whatever the per-node `sk-access` MCP returns (see
/// `skcomms/docs/access-plane-p7.md`). The JSON parsers below are deliberately
/// tolerant of the tool result shapes documented there so wiring the live
/// daemon is a drop-in:
///
///   * `file_list(dir)`  → entries with `name`/`path`/`type`/`size`/`mtime`
///   * `pg_search(q,k)`  → hits `{node, path, score, snippet}` (+ `doc_id`/`source`)
///   * `node_info()` / `health()` → identity + tool catalog + roots + up/down

/// Whether a filesystem entry is a directory or a regular file.
enum FsEntryType {
  /// A directory (tap to descend).
  dir,

  /// A regular file (tap to open the viewer).
  file,
}

FsEntryType _fsEntryTypeFromString(Object? raw) {
  final s = raw?.toString().toLowerCase().trim() ?? '';
  if (s == 'dir' ||
      s == 'directory' ||
      s == 'folder' ||
      s == 'd' ||
      s == 'tree') {
    return FsEntryType.dir;
  }
  return FsEntryType.file;
}

/// A single entry in a directory listing returned by `file_list(dir)`.
@immutable
class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.type,
    this.size,
    this.mtime,
  });

  /// The leaf name (e.g. `enroll.py`).
  final String name;

  /// The full absolute path on the owning node (e.g. `/home/.../enroll.py`).
  final String path;

  /// Directory vs file.
  final FsEntryType type;

  /// Size in bytes (files only; null for directories / unknown).
  final int? size;

  /// Last-modified time (server clock), if reported.
  final DateTime? mtime;

  bool get isDir => type == FsEntryType.dir;
  bool get isFile => type == FsEntryType.file;

  /// Tolerant parser for the `file_list` / `file_stat` result shape. Accepts
  /// both flat `{name,path,type,size,mtime}` and the common `is_dir` boolean,
  /// and `mtime` as epoch-seconds-or-ISO spellings.
  factory FsEntry.fromJson(Map<String, dynamic> json) {
    final isDirFlag = json['is_dir'] ?? json['isDir'] ?? json['directory'];
    final type = isDirFlag is bool
        ? (isDirFlag ? FsEntryType.dir : FsEntryType.file)
        : _fsEntryTypeFromString(json['type'] ?? json['kind']);

    final path = (json['path'] ?? json['full_path'] ?? json['abspath'] ?? '')
        .toString();
    final name = (json['name'] ?? json['basename'] ?? _basename(path) ?? '')
        .toString();

    return FsEntry(
      name: name,
      path: path,
      type: type,
      size: _toInt(json['size'] ?? json['bytes']),
      mtime: _parseTime(json['mtime'] ?? json['modified'] ?? json['mtime_iso']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FsEntry &&
      other.name == name &&
      other.path == path &&
      other.type == type &&
      other.size == size &&
      other.mtime == mtime;

  @override
  int get hashCode => Object.hash(name, path, type, size, mtime);
}

/// A single corpus hit returned by `pg_search(query, k)`.
@immutable
class SearchHit {
  const SearchHit({
    required this.node,
    required this.path,
    required this.score,
    required this.snippet,
    this.docId,
    this.source,
  });

  /// Which node the source file lives on (e.g. `.158` / `.41`). The whole point
  /// of P7: results are tagged with the owning node so the file can be fetched
  /// from there without syncing.
  final String node;

  /// The path on [node] for the matched document.
  final String path;

  /// The hybrid (vector+BM25) relevance score.
  final double score;

  /// A snippet of the matched text.
  final String snippet;

  /// The skmem-pg document id, if returned (`pg_locate` key).
  final String? docId;

  /// Optional source label (e.g. `wiki`, `youtube`, `lens`).
  final String? source;

  /// Tolerant parser for the `pg_search` hit shape
  /// (`{node, path, score, snippet}` + optional `doc_id`/`source`).
  factory SearchHit.fromJson(Map<String, dynamic> json) {
    return SearchHit(
      node: (json['node'] ?? json['host'] ?? '').toString(),
      path: (json['path'] ?? json['file'] ?? '').toString(),
      score: _toDouble(json['score'] ?? json['rank'] ?? json['rrf']) ?? 0.0,
      snippet: (json['snippet'] ??
              json['text'] ??
              json['chunk'] ??
              json['content'] ??
              '')
          .toString(),
      docId: (json['doc_id'] ?? json['docId'] ?? json['id'])?.toString(),
      source: (json['source'] ?? json['source_type'])?.toString(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SearchHit &&
      other.node == node &&
      other.path == path &&
      other.score == score &&
      other.snippet == snippet &&
      other.docId == docId &&
      other.source == source;

  @override
  int get hashCode => Object.hash(node, path, score, snippet, docId, source);
}

/// A node's identity + capability snapshot, from `node_info()` + `health()`.
@immutable
class NodeInfo {
  const NodeInfo({
    required this.node,
    required this.up,
    this.hostname,
    this.toolCount = 0,
    this.exposedRoots = const <String>[],
    this.version,
    this.detail,
  });

  /// The node key (e.g. `.158` / `.41`), matches [SearchHit.node].
  final String node;

  /// Whether the node's `sk-access` MCP answered `health()`.
  final bool up;

  /// Reported hostname (e.g. `noroc2027`).
  final String? hostname;

  /// Number of MCP tools the node exposes (catalog size).
  final int toolCount;

  /// The exposed-root allowlist the file tools are scoped to (e.g. `~/clawd`).
  final List<String> exposedRoots;

  /// Optional version string of the access daemon.
  final String? version;

  /// Optional free-text status detail (e.g. an error when [up] is false).
  final String? detail;

  /// Tolerant parser merging `node_info()` + `health()` payloads. Accepts a
  /// `tools` list or a `tool_count` int; `roots`/`exposed_roots` list; and an
  /// explicit `up`/`ok`/`status` health field.
  factory NodeInfo.fromJson(String node, Map<String, dynamic> json) {
    final tools = json['tools'];
    final toolCount = tools is List
        ? tools.length
        : (_toInt(json['tool_count'] ?? json['tools_count']) ?? 0);

    final rootsRaw = json['exposed_roots'] ?? json['roots'];
    final roots = rootsRaw is List
        ? rootsRaw.map((e) => e.toString()).toList()
        : const <String>[];

    final upRaw = json['up'] ?? json['ok'] ?? json['healthy'];
    final status = json['status']?.toString().toLowerCase();
    final up = upRaw is bool
        ? upRaw
        : (status == null ? true : (status == 'ok' || status == 'up'));

    return NodeInfo(
      node: node,
      up: up,
      hostname: (json['hostname'] ?? json['host'] ?? json['name'])?.toString(),
      toolCount: toolCount,
      exposedRoots: roots,
      version: (json['version'] ?? json['ver'])?.toString(),
      detail: (json['detail'] ?? json['error'] ?? json['message'])?.toString(),
    );
  }

  /// A "down" snapshot used when a node's health call fails entirely.
  factory NodeInfo.down(String node, {String? detail}) =>
      NodeInfo(node: node, up: false, detail: detail);

  @override
  bool operator ==(Object other) =>
      other is NodeInfo &&
      other.node == node &&
      other.up == up &&
      other.hostname == hostname &&
      other.toolCount == toolCount &&
      listEquals(other.exposedRoots, exposedRoots) &&
      other.version == version &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(
        node,
        up,
        hostname,
        toolCount,
        Object.hashAll(exposedRoots),
        version,
        detail,
      );
}

// ── parse helpers ────────────────────────────────────────────────────────────

String? _basename(String path) {
  if (path.isEmpty) return null;
  final trimmed =
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final idx = trimmed.lastIndexOf('/');
  return idx < 0 ? trimmed : trimmed.substring(idx + 1);
}

int? _toInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

double? _toDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

/// Parse a timestamp that may arrive as ISO-8601, epoch-seconds/millis, or null.
DateTime? _parseTime(Object? raw) {
  if (raw is String && raw.isNotEmpty) {
    final p = DateTime.tryParse(raw);
    if (p != null) return p.toUtc();
  }
  if (raw is num) {
    final v = raw.toInt();
    return v > 100000000000
        ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true)
        : DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true);
  }
  return null;
}
