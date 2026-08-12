import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'operator_auth_interceptor.dart';
import 'operator_session_service.dart';

/// Compile-time default for the skcapstone daemon (port 7777). Seed for the
/// runtime-settable [backendConfigProvider]; the live value comes from there so
/// instances can be switched without a rebuild.
const _kSKCapstoneBaseUrl = kDefaultSkcapstoneUrl;

/// Compile-time default for the skcapstone dashboard (port 7778). Seed for
/// [backendConfigProvider]; live value comes from there.
const _kSKDashboardBaseUrl = kDefaultSkcapstoneDashboardUrl;

/// Low-level HTTP client for the skcapstone daemon REST API.
class SKCapstoneClient {
  /// [sessionService] is the operator-auth handshake (same one [SKCommsClient]
  /// uses). It is nullable: when not supplied the client behaves exactly as it
  /// did before, no Bearer header is attached and no 401 retry is attempted.
  /// When supplied, an [buildOperatorAuthInterceptor] attaches the operator
  /// session Bearer to BOTH the daemon (:7777) and dashboard (:7778) Dios so
  /// `/api/board` (and other routes) pass the webui dataplane auth gate instead
  /// of 401ing to a false "Dashboard offline". The interceptor no-ops
  /// gracefully on unenrolled devices, so guest/native flows do not regress.
  SKCapstoneClient({
    String? baseUrl,
    String? dashboardUrl,
    OperatorSessionService? sessionService,
  })  : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl ?? _kSKCapstoneBaseUrl,
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 10),
          ),
        ),
        _dashDio = Dio(
          BaseOptions(
            baseUrl: dashboardUrl ?? _kSKDashboardBaseUrl,
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 10),
          ),
        ),
        _sessionService = sessionService {
    _dio.interceptors.add(
      buildOperatorAuthInterceptor(_sessionService, () => _dio),
    );
    _dashDio.interceptors.add(
      buildOperatorAuthInterceptor(_sessionService, () => _dashDio),
    );
  }

  final Dio _dio;
  final Dio _dashDio;
  final OperatorSessionService? _sessionService;

  /// GET /ping, verify the daemon is running.
  Future<bool> isAlive() async {
    try {
      final resp = await _dio.get('/ping');
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// GET /consciousness, full consciousness loop status.
  Future<Map<String, dynamic>?> getConsciousness() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>('/consciousness');
      return resp.data;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/v1/conversations/{peerId}, message history for a peer.
  /// Returns a bare list or a {messages: [...]} envelope.
  Future<List<dynamic>> getConversationHistory(String peerId) async {
    final resp =
        await _dio.get<dynamic>('/api/v1/conversations/$peerId');
    final data = resp.data;
    if (data is List) return data;
    if (data is Map && data['messages'] is List) {
      return data['messages'] as List<dynamic>;
    }
    return [];
  }

  /// GET /api/v1/household/agents, list all agents with heartbeat data.
  Future<List<AgentHeartbeat>> getHouseholdAgents() async {
    final resp =
        await _dio.get<Map<String, dynamic>>('/api/v1/household/agents');
    final agents = resp.data?['agents'] as List<dynamic>? ?? [];
    return agents
        .map((e) => AgentHeartbeat.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/board (dashboard port 7778), coordination board snapshot.
  ///
  /// Returns null when the dashboard service is unreachable.
  Future<CoordBoardData?> getCoordBoard() async {
    try {
      final resp = await _dashDio.get<Map<String, dynamic>>('/api/board');
      if (resp.data == null) return null;
      return CoordBoardData.fromJson(resp.data!);
    } catch (_) {
      return null;
    }
  }

  /// GET /api/kanban (dashboard :7778 via the webui proxy), the full kanban
  /// board: columns x swimlanes x cards. Null when the dashboard is unreachable.
  Future<KanbanBoard?> getKanban() async {
    try {
      final resp = await _dashDio.get<Map<String, dynamic>>('/api/kanban');
      if (resp.data == null) return null;
      return KanbanBoard.fromJson(resp.data!);
    } catch (_) {
      return null;
    }
  }

  /// POST /api/card/{id}/{action} card mutation (move/assign/priority/label/
  /// note). Attributes the actor and returns true on success. `body` carries the
  /// action fields (e.g. move -> {column: 'doing'}).
  Future<bool> mutateCard(
      String cardId, String action, Map<String, dynamic> body) async {
    try {
      final resp = await _dashDio.post<Map<String, dynamic>>(
        '/api/card/$cardId/$action',
        data: body,
        options: Options(headers: const {'x-sk-actor': 'skworld-app'}),
      );
      return (resp.data?['ok'] as bool?) ?? (resp.statusCode == 200);
    } catch (_) {
      return false;
    }
  }

  /// Convenience: move a card to a column.
  Future<bool> moveCard(String cardId, String column) =>
      mutateCard(cardId, 'move', {'column': column});

  /// GET /api/card/{id}/ai-suggestions, AI next-step options for a card. The
  /// LLM path can take ~15-35s, so this uses a longer receive timeout. `llm:
  /// false` returns instant heuristics. Empty list on error.
  Future<List<CardSuggestion>> getCardSuggestions(String cardId,
      {bool llm = true}) async {
    try {
      final resp = await _dashDio.get<Map<String, dynamic>>(
        '/api/card/$cardId/ai-suggestions',
        queryParameters: {'llm': llm ? '1' : '0'},
        options: Options(receiveTimeout: const Duration(seconds: 45)),
      );
      final list = resp.data?['suggestions'] as List? ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(CardSuggestion.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// POST /api/card/{id}/queue-ai, dispatch an agent to work the card with an
  /// instruction. This is the "push the button and the AI proceeds" action.
  /// Returns the run id on success, else null.
  Future<String?> queueAi(
    String cardId, {
    required String instruction,
    String mode = 'propose',
    String agent = 'lumina',
  }) async {
    try {
      final resp = await _dashDio.post<Map<String, dynamic>>(
        '/api/card/$cardId/queue-ai',
        data: {'instruction': instruction, 'mode': mode, 'agent': agent},
        options: Options(headers: const {'x-sk-actor': 'skworld-app'}),
      );
      if ((resp.data?['ok'] as bool?) == true) {
        return resp.data?['run_id'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// One AI-suggested next step for a card: a concise instruction plus the safety
/// mode it should run in.
class CardSuggestion {
  const CardSuggestion({required this.text, required this.mode});

  final String text;

  /// propose (analysis, no change) | dry-run (reversible) | execute (draft PR).
  final String mode;

  factory CardSuggestion.fromJson(Map<String, dynamic> j) => CardSuggestion(
        text: j['text'] as String? ?? '',
        mode: j['mode'] as String? ?? 'propose',
      );
}

/// Heartbeat snapshot for a single agent, sourced from
/// ~/.skcapstone/heartbeats/{name}.json.
class AgentHeartbeat {
  const AgentHeartbeat({
    required this.name,
    required this.status,
    required this.online,
    this.hostname = '',
    this.soulActive = '',
    this.consciousnessActive = false,
    this.loadedModel = '',
    this.timestamp,
  });

  final String name;

  /// "alive" | "busy" | "draining" | "offline"
  final String status;

  /// True when status == "alive" or "busy" and heartbeat is fresh.
  final bool online;
  final String hostname;
  final String soulActive;
  final bool consciousnessActive;
  final String loadedModel;
  final DateTime? timestamp;

  factory AgentHeartbeat.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'offline';
    final ts = json['timestamp'] as String?;
    DateTime? parsed;
    if (ts != null) {
      parsed = DateTime.tryParse(ts);
    }
    // Consider online if status is alive/busy AND heartbeat is < 10 min old.
    final fresh = parsed != null &&
        DateTime.now().toUtc().difference(parsed).inMinutes < 10;
    final online = fresh && (status == 'alive' || status == 'busy');

    return AgentHeartbeat(
      name: json['agent_name'] as String? ?? '',
      status: status,
      online: online,
      hostname: json['hostname'] as String? ?? '',
      soulActive: json['soul_active'] as String? ?? '',
      consciousnessActive: json['consciousness_active'] as bool? ?? false,
      loadedModel: json['loaded_model'] as String? ?? '',
      timestamp: parsed,
    );
  }
}

/// SKCapstoneClient provider, repointed live by the runtime backend config.
/// Watching [backendConfigProvider] rebuilds the client (and its base URLs)
/// whenever the user switches federation instances.
final skCapstoneClientProvider = Provider<SKCapstoneClient>((ref) {
  final cfg = ref.watch(backendConfigProvider);
  // On web, the dashboard (:7778) isn't exposed through tailscale/funnel, only
  // the webui is. Use the served ORIGIN so /api/board hits the webui same-origin
  // proxy (→ :7778 server-side), which works on localhost AND the tailscale URL.
  String dash = cfg.skcapstoneDashboardUrl;
  if (kIsWeb) {
    try {
      final o = Uri.base.origin;
      if (o.isNotEmpty && o != 'null') dash = o;
    } catch (_) {/* file: base in tests → keep config default */}
  }
  return SKCapstoneClient(
    baseUrl: cfg.skcapstoneUrl,
    dashboardUrl: dash,
    sessionService: ref.watch(operatorSessionServiceProvider),
  );
});

// ── Coordination board models ──────────────────────────────────────────────

/// A single task on the coordination board.
class CoordTask {
  const CoordTask({
    required this.id,
    required this.title,
    required this.priority,
    required this.status,
    this.claimedBy,
    this.tags = const [],
    this.description,
  });

  final String id;
  final String title;

  /// 'critical' | 'high' | 'medium' | 'low'
  final String priority;

  /// 'open' | 'claimed' | 'in_progress' | 'review' | 'done' | 'blocked'
  final String status;

  final String? claimedBy;
  final List<String> tags;
  final String? description;

  bool get isDone => status == 'done';
  bool get isActive =>
      status == 'in_progress' || status == 'claimed' || status == 'review';

  factory CoordTask.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'] as List<dynamic>? ?? [];
    return CoordTask(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? json['subject'] as String? ?? '',
      priority: json['priority'] as String? ?? 'medium',
      status: json['status'] as String? ?? 'open',
      claimedBy: json['claimed_by'] as String?,
      tags: rawTags.cast<String>(),
      description: json['description'] as String?,
    );
  }
}

/// Lightweight agent status entry from the board snapshot.
class AgentBoardStatus {
  const AgentBoardStatus({
    required this.name,
    required this.state,
    this.currentTask,
  });

  final String name;

  /// 'active' | 'idle' | 'offline'
  final String state;

  final String? currentTask;

  factory AgentBoardStatus.fromJson(Map<String, dynamic> json) {
    return AgentBoardStatus(
      name: json['name'] as String? ?? '',
      state: json['state'] as String? ?? 'offline',
      currentTask: json['current_task'] as String?,
    );
  }
}

/// Board summary counts.
class CoordSummary {
  const CoordSummary({
    required this.total,
    required this.done,
    required this.open,
    required this.inProgress,
  });

  final int total;
  final int done;
  final int open;
  final int inProgress;

  factory CoordSummary.fromJson(Map<String, dynamic> json) {
    return CoordSummary(
      total: json['total'] as int? ?? 0,
      done: json['done'] as int? ?? 0,
      open: json['open'] as int? ?? 0,
      inProgress: json['in_progress'] as int? ?? 0,
    );
  }
}

/// Full snapshot from GET /api/board.
class CoordBoardData {
  const CoordBoardData({
    required this.tasks,
    required this.agents,
    required this.summary,
  });

  final List<CoordTask> tasks;
  final List<AgentBoardStatus> agents;
  final CoordSummary summary;

  factory CoordBoardData.fromJson(Map<String, dynamic> json) {
    final rawTasks = json['tasks'] as List<dynamic>? ?? [];
    final rawAgents = json['agents'] as List<dynamic>? ?? [];
    final rawSummary = json['summary'] as Map<String, dynamic>? ?? {};

    return CoordBoardData(
      tasks: rawTasks
          .map((e) => CoordTask.fromJson(e as Map<String, dynamic>))
          .toList(),
      agents: rawAgents
          .map((e) => AgentBoardStatus.fromJson(e as Map<String, dynamic>))
          .toList(),
      summary: CoordSummary.fromJson(rawSummary),
    );
  }
}

// ── Kanban board models (GET /api/kanban) ───────────────────────────────────

/// One card on the kanban board.
class KanbanCard {
  const KanbanCard({
    required this.id,
    required this.title,
    required this.status,
    required this.swimlane,
    this.kind,
    this.priority,
    this.owner,
    this.labels = const [],
  });

  final String id;
  final String title;

  /// The column: backlog | ready | doing | review | done.
  final String status;

  /// The swimlane: feature | bug | security | expedite | change | problem.
  final String swimlane;

  final String? kind; // epic | story | task | ...
  final String? priority; // critical | high | medium | low
  final String? owner;
  final List<String> labels;

  factory KanbanCard.fromJson(Map<String, dynamic> j) => KanbanCard(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        status: j['status'] as String? ?? 'backlog',
        swimlane: (j['swimlane'] ?? j['lane']) as String? ?? '',
        kind: j['kind'] as String?,
        priority: j['priority'] as String?,
        owner: j['owner'] as String?,
        labels:
            (j['labels'] as List? ?? const []).map((e) => e.toString()).toList(),
      );
}

/// The full kanban board: the ordered columns plus every card (flattened across
/// swimlanes; each card carries its own `swimlane`).
class KanbanBoard {
  const KanbanBoard({required this.columns, required this.cards});

  final List<String> columns;
  final List<KanbanCard> cards;

  /// Cards in a given column, preserving board order.
  List<KanbanCard> inColumn(String column) =>
      cards.where((c) => c.status == column).toList();

  factory KanbanBoard.fromJson(Map<String, dynamic> j) {
    final cols = (j['columns'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    final cards = <KanbanCard>[];
    for (final lane in (j['lanes'] as List? ?? const [])) {
      if (lane is! Map<String, dynamic>) continue;
      final laneCols = lane['columns'] as Map<String, dynamic>? ?? const {};
      for (final entry in laneCols.entries) {
        for (final c in (entry.value as List? ?? const [])) {
          if (c is Map<String, dynamic>) cards.add(KanbanCard.fromJson(c));
        }
      }
    }
    return KanbanBoard(
      columns: cols.isEmpty
          ? const ['backlog', 'ready', 'doing', 'review', 'done']
          : cols,
      cards: cards,
    );
  }
}
