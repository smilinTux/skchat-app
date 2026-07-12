import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daemon_config.dart';

// ── Data Transfer Objects ──────────────────────────────────────────────────

/// A message loaded from the skchat local history store via CLI.
///
/// Mirrors the JSON shape emitted by `skchat inbox --json`:
/// ```json
/// {"sender": "capauth:lumina@skworld.io", "recipient": "capauth:opus@skworld.io",
///  "content": "hello", "thread_id": null, "timestamp": "2026-03-03T..."}
/// ```
class SkchatCliMessage {
  const SkchatCliMessage({
    required this.sender,
    required this.recipient,
    required this.content,
    required this.timestamp,
    this.threadId,
  });

  final String sender;
  final String recipient;
  final String content;
  final DateTime timestamp;
  final String? threadId;

  /// Stable dedup key derived from sender + timestamp milliseconds.
  String get id => '${sender}_${timestamp.millisecondsSinceEpoch}';

  factory SkchatCliMessage.fromJson(Map<String, dynamic> json) {
    final rawTs = json['timestamp'];
    final DateTime ts;
    if (rawTs is String) {
      ts = DateTime.tryParse(rawTs) ?? DateTime.now();
    } else {
      ts = DateTime.now();
    }
    return SkchatCliMessage(
      sender: json['sender'] as String? ?? '',
      recipient: json['recipient'] as String? ?? '',
      content: json['content'] as String? ?? '',
      timestamp: ts,
      threadId: json['thread_id'] as String?,
    );
  }
}

/// Result of a `skchat send` CLI call.
class DaemonSendResult {
  const DaemonSendResult({required this.success, this.error});
  final bool success;
  final String? error;
}

// ── DaemonService ──────────────────────────────────────────────────────────

/// Bridges the Flutter UI to the local skchat daemon.
///
/// Two channels:
/// - **HTTP**, health check at `<daemonHost>:9385/health` (daemon's built-in
///   server).  The host is derived from the configured SKComm daemon URL so a
///   tailnet daemon is reachable from a remote web client.
/// - **CLI** , `skchat inbox --json` / `skchat send` via dart:io [Process].
///
/// The CLI channel is **native-only**.  On the web there is no local process to
/// spawn, so every CLI method is a no-op there and the app relies entirely on
/// the HTTP [SKCommClient].  All CLI calls run from [workingDir] (default:
/// `$HOME`) to avoid the skmemory namespace collision that occurs when CWD is
/// the project root.
class DaemonService {
  DaemonService({
    String? healthBaseUrl,
    String? workingDir,
    String? identity,
  })  : _healthBaseUrl = healthBaseUrl ?? 'http://127.0.0.1:9385',
        _identity = identity ?? _resolveIdentity(),
        _workingDir = workingDir ??
            (kIsWeb
                ? ''
                : (Platform.environment['HOME'] ??
                    '/home/${Platform.environment['USER'] ?? 'user'}')),
        _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 5),
          ),
        );

  final String _healthBaseUrl;
  final String _identity;
  final String _workingDir;
  final Dio _dio;

  /// Absolute path to the `skchat` CLI. The app may be launched without
  /// `~/.skenv/bin` on PATH (e.g. from a desktop launcher), which would make a
  /// bare `Process.run('skchat', …)` fail silently, sends never go out and the
  /// agent never replies. Prefer the known install path, fall back to PATH.
  static final String skchatBin = (() {
    if (kIsWeb) return 'skchat';
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final candidate = '$home/.skenv/bin/skchat';
      if (File(candidate).existsSync()) return candidate;
    }
    return 'skchat';
  })();

  /// Resolve the operator identity for CLI calls and outbound detection.
  /// Precedence: build-time `LOCAL_IDENTITY` → `SKCHAT_IDENTITY` env (native)
  /// → `chef@skworld.io`.  Crucially NOT the `.active` agent default, which
  /// would attribute the operator's messages to whatever agent is active
  /// (e.g. "architect").
  static String _resolveIdentity() {
    const compileTime = String.fromEnvironment('LOCAL_IDENTITY');
    if (compileTime.isNotEmpty) return compileTime;
    if (!kIsWeb) {
      final env = Platform.environment['SKCHAT_IDENTITY'];
      if (env != null && env.isNotEmpty) return env;
    }
    return 'chef@skworld.io';
  }

  /// The local skchat identity URI from the environment, e.g.
  /// `capauth:opus@skworld.io`.  Used to classify messages as outbound.
  /// Always null on the web (no process environment).
  String? get localIdentity => _identity;

  /// Extract the short peer name from a CapAuth URI.
  /// `capauth:lumina@skworld.io` → `lumina`
  static String peerShortName(String uri) {
    // Strip scheme prefix if present.
    var s = uri.startsWith('capauth:') ? uri.substring('capauth:'.length) : uri;
    // Take only the local part before '@'.
    return s.split('@').first;
  }

  // ── Health ────────────────────────────────────────────────────────────────

  /// Returns `true` if the skchat daemon health endpoint is reachable.
  Future<bool> isAlive() async {
    try {
      final resp = await _dio.get('$_healthBaseUrl/health');
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Full health payload from the daemon (`GET /health`).
  Future<Map<String, dynamic>?> getHealth() async {
    try {
      final resp =
          await _dio.get<Map<String, dynamic>>('$_healthBaseUrl/health');
      return resp.data;
    } catch (_) {
      return null;
    }
  }

  // ── Inbox ─────────────────────────────────────────────────────────────────

  /// Fetch all messages from the local skchat history store via CLI.
  ///
  /// Runs: `skchat inbox --json --limit <limit>` from `$HOME`.
  ///
  /// Returns an empty list on error (daemon not running, CLI not in PATH, etc.).
  /// On the web there is no local CLI, so this always returns an empty list.
  Future<List<SkchatCliMessage>> getInbox({int limit = 100}) async {
    if (kIsWeb) return [];
    try {
      final result = await Process.run(
        skchatBin,
        ['inbox', '--json', '--limit', '$limit'],
        workingDirectory: _workingDir,
        environment: {'SKCHAT_IDENTITY': _identity},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return [];

      final stdout = result.stdout as String;
      if (stdout.trim().isEmpty) return [];

      final decoded = jsonDecode(stdout);
      if (decoded is! List) return [];

      return decoded
          .whereType<Map<String, dynamic>>()
          .map(SkchatCliMessage.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Fetch messages exchanged with a specific peer from the local store.
  ///
  /// Filters the full inbox client-side by sender/recipient matching [peerId].
  /// [peerId] may be a short name (`lumina`) or full URI
  /// (`capauth:lumina@skworld.io`).
  Future<List<SkchatCliMessage>> getConversation(
    String peerId, {
    int limit = 100,
  }) async {
    if (kIsWeb) return [];
    // Use `skchat history <peer>` (BOTH directions), not `inbox`, which only
    // returns messages RECEIVED by the identity (so the operator's own sent
    // messages would be missing → they'd render only as optimistic copies and
    // everything else as inbound). Run as the operator identity so history
    // resolves the correct "me ↔ peer" conversation.
    try {
      final result = await Process.run(
        skchatBin,
        ['history', peerShortName(peerId), '--json', '--limit', '$limit'],
        workingDirectory: _workingDir,
        environment: {'SKCHAT_IDENTITY': _identity},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return [];
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return [];
      final decoded = jsonDecode(out);
      if (decoded is! List) return [];
      final msgs = decoded
          .whereType<Map<String, dynamic>>()
          .map(SkchatCliMessage.fromJson)
          .toList();
      msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return msgs;
    } catch (_) {
      return [];
    }
  }

  // ── Send ──────────────────────────────────────────────────────────────────

  /// Send a message via `skchat send <recipient> <content>` CLI.
  ///
  /// Stores the message in the local skchat history AND delivers it via the
  /// configured SKComm transport.  Runs from `$HOME`.
  Future<DaemonSendResult> sendMessage({
    required String recipient,
    required String content,
    String? threadId,
    String? replyTo,
  }) async {
    if (kIsWeb) {
      // No local CLI on the web, caller falls back to the HTTP SKComm client.
      return const DaemonSendResult(
        success: false,
        error: 'CLI unavailable on web',
      );
    }
    try {
      final args = <String>['send', recipient, content];
      if (threadId != null && threadId.isNotEmpty) {
        args.addAll(['--thread', threadId]);
      }
      if (replyTo != null && replyTo.isNotEmpty) {
        args.addAll(['--reply-to', replyTo]);
      }
      final result = await Process.run(
        skchatBin,
        args,
        workingDirectory: _workingDir,
        environment: {'SKCHAT_IDENTITY': _identity},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode == 0) {
        return const DaemonSendResult(success: true);
      }
      return DaemonSendResult(
        success: false,
        error: (result.stderr as String).trim(),
      );
    } catch (e) {
      return DaemonSendResult(success: false, error: e.toString());
    }
  }
}

// ── Riverpod provider ──────────────────────────────────────────────────────

/// [DaemonService] bound to the configured daemon host.
///
/// The skchat daemon's health endpoint lives on port 9385 of the same host
/// that serves the SKComm REST API (port 9384).  We rewrite the configured
/// SKComm URL's port to 9385 so a remote web client checks the right host.
final daemonServiceProvider = Provider<DaemonService>((ref) {
  final daemonUrl = ref.watch(daemonUrlProvider);
  return DaemonService(healthBaseUrl: _healthUrlFromDaemonUrl(daemonUrl));
});

/// Derive the skchat health URL (port 9385) from the SKComm daemon URL.
///
/// `http://host:9384` → `http://host:9385`.  If the URL can't be parsed,
/// fall back to the local default.
String _healthUrlFromDaemonUrl(String daemonUrl) {
  final normalized = normalizeDaemonUrl(daemonUrl);
  final uri = Uri.tryParse(normalized);
  if (uri == null || uri.host.isEmpty) return 'http://127.0.0.1:9385';
  return uri.replace(port: 9385).toString();
}
