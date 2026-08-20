import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'diag/diag_error_sink.dart';
import 'diag/diag_interceptor.dart';
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
  /// [dio] / [dashDio] may be injected (tests) to supply a canned
  /// [HttpClientAdapter], mirroring the pattern [SKCommsClient] and
  /// [DeviceListService] already use; when omitted (every real call site
  /// today) this builds its own, exactly as before this parameter existed.
  SKCapstoneClient({
    String? baseUrl,
    String? dashboardUrl,
    Dio? dio,
    Dio? dashDio,
    OperatorSessionService? sessionService,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? _kSKCapstoneBaseUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 10),
              ),
            ),
        _dashDio = dashDio ??
            Dio(
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
    // Network breadcrumbs (card 0a5b8e07): immediately after the auth
    // interceptor, on both the daemon and dashboard Dios.
    _dio.interceptors.add(buildDiagInterceptor(emitDiagEvent));
    _dashDio.interceptors.add(
      buildOperatorAuthInterceptor(_sessionService, () => _dashDio),
    );
    _dashDio.interceptors.add(buildDiagInterceptor(emitDiagEvent));
  }

  final Dio _dio;
  final Dio _dashDio;
  final OperatorSessionService? _sessionService;

  /// Cached capability-fetch (Unified Consent Plane P1.3b, coord card
  /// 280348ef). Mirrors skdashboard's `getCapability()` in
  /// static/js/api.js: fetched once from GET /api/auth/capability and
  /// cached for the client's lifetime so every mutating call after the
  /// first does not re-fetch. A fetch failure (dashboard offline, seat not
  /// configured) degrades to `{actor: "unattributed", capability: null}` --
  /// the fleet-wide convention for a claim that cannot be backed -- rather
  /// than any hardcoded actor string. Never synthesize an identity.
  Future<Map<String, dynamic>>? _capabilityFetch;

  Future<Map<String, dynamic>> _getCapability() {
    return _capabilityFetch ??= _dashDio
        .get<Map<String, dynamic>>('/api/auth/capability')
        .then((r) => r.data ?? const <String, dynamic>{})
        .catchError((_) => <String, dynamic>{});
  }

  /// Headers every mutating `_dashDio` call attaches: `x-sk-actor` (the PDP
  /// subject) and, when this seat is configured with one, `x-sk-capability`
  /// (queue_authz's staged token/pdp/both gate reads it). Mirrors
  /// skdashboard's `authHeaders()` in static/js/api.js so the two clients
  /// cannot drift.
  Future<Map<String, String>> _authHeaders() async {
    final cap = await _getCapability();
    final headers = <String, String>{
      'x-sk-actor': (cap['actor'] as String?) ?? 'unattributed',
    };
    final capability = cap['capability'] as String?;
    if (capability != null && capability.isNotEmpty) {
      headers['x-sk-capability'] = capability;
    }
    return headers;
  }

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

  /// GET /api/gtd?list=... a GTD list (next-actions/inbox/waiting-for/...). Each
  /// item carries a `cardId` (`gtd-ID`) so the AI suggest/queue actions drive the
  /// SAME card routes as kanban. Empty list on error.
  Future<List<GtdItem>> getGtdNext({String list = 'next-actions'}) async {
    try {
      final resp = await _dashDio.get<Map<String, dynamic>>(
        '/api/gtd',
        queryParameters: {'list': list},
      );
      final items = resp.data?['items'] as List? ?? const [];
      return items
          .whereType<Map<String, dynamic>>()
          .map(GtdItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
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
        options: Options(headers: await _authHeaders()),
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
        options: Options(headers: await _authHeaders()),
      );
      if ((resp.data?['ok'] as bool?) == true) {
        return resp.data?['run_id'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Change management (CM P2.5): validate / schedule / arm ────────────────
  //
  // These call the NEW skdashboard `/api/change/{id}/*` routes (design doc
  // docs/specs/2026-08-13-change-management-cab-ai-arch.md sections 6-8), on
  // the SAME `_dashDio` and `x-sk-actor` pattern as [queueAi]/[mutateCard]
  // above, so they ride the same operator-auth interceptor. Unlike those,
  // failures here carry the server's `error`/`reason` string (409 no
  // prepared_pr, 409 invalid schedule transition, 403 unauthorized) so the
  // popout can surface it verbatim instead of a generic "failed".

  /// Shared POST for a `/api/change/{id}/{action}` PEP route.
  Future<ChangeActionResult> _postChangeAction(
    String changeId,
    String action,
    Map<String, dynamic> body,
  ) async {
    try {
      final resp = await _dashDio.post<Map<String, dynamic>>(
        '/api/change/$changeId/$action',
        data: body,
        options: Options(headers: await _authHeaders()),
      );
      return ChangeActionResult(ok: true, data: resp.data ?? const {});
    } on DioException catch (e) {
      return _changeErrorResult(e);
    } catch (e) {
      return ChangeActionResult(ok: false, error: e.toString());
    }
  }

  /// Shared GET for a `/api/change/{id}/{action}` route (currently just
  /// `pir-draft`). Same [ChangeActionResult] shape and error surfacing as
  /// [_postChangeAction], so a failed fetch reports the same way a failed
  /// mutation does.
  Future<ChangeActionResult> _getChangeAction(
    String changeId,
    String action,
  ) async {
    try {
      final resp = await _dashDio.get<Map<String, dynamic>>(
        '/api/change/$changeId/$action',
        options: Options(headers: await _authHeaders()),
      );
      return ChangeActionResult(ok: true, data: resp.data ?? const {});
    } on DioException catch (e) {
      return _changeErrorResult(e);
    } catch (e) {
      return ChangeActionResult(ok: false, error: e.toString());
    }
  }

  /// Maps a failed `/api/change/{id}/*` call to a [ChangeActionResult],
  /// surfacing the server's `error`/`reason` string verbatim when present
  /// (409 no prepared_pr, 409 not deployed, 400 empty note, 403 unauthorized)
  /// instead of a generic message.
  ChangeActionResult _changeErrorResult(DioException e) {
    final data = e.response?.data;
    String? reason;
    if (data is Map) {
      final err = data['error'] ?? data['reason'];
      if (err is String) reason = err;
    }
    return ChangeActionResult(
      ok: false,
      error: reason ?? e.message ?? 'request failed',
      statusCode: e.response?.statusCode,
    );
  }

  /// POST /api/change/{id}/validate, run checks against the change's
  /// `prepared_pr` and attach the verdict. 409s (via [ChangeActionResult.ok]
  /// false, [ChangeActionResult.error] set) when the change has no
  /// `prepared_pr` yet, nothing to validate.
  Future<ChangeActionResult> validateChange(String changeId) =>
      _postChangeAction(changeId, 'validate', const {});

  /// POST /api/change/{id}/schedule, either an ASAP or a windowed schedule.
  /// `deploy_mode` is LOCKED to `"confirm"` here: the backend rejects any
  /// other value with 400 (design doc section 9, Phase 3a), so this client
  /// never sends anything else, matching the popout's locked toggle.
  Future<ChangeActionResult> scheduleChange(
    String changeId, {
    DateTime? windowStart,
    DateTime? windowEnd,
    bool asap = false,
    String note = '',
  }) =>
      _postChangeAction(
        changeId,
        'schedule',
        buildScheduleBody(
          windowStart: windowStart,
          windowEnd: windowEnd,
          asap: asap,
          note: note,
        ),
      );

  /// POST /api/change/{id}/schedule with `{unschedule: true}`, returning the
  /// change to `approved` and clearing its scheduled window.
  Future<ChangeActionResult> unscheduleChange(String changeId,
          {String note = ''}) =>
      _postChangeAction(
          changeId, 'schedule', {'unschedule': true, 'note': note});

  /// POST /api/change/{id}/arm, writes the per-agent human-arm file the
  /// (later) deploy runner requires for `deploy_mode == "confirm"`. Visible
  /// only on scheduled changes for verified operators; the server PEP is the
  /// real enforcement, this call just surfaces its verdict.
  Future<ChangeActionResult> armChangeDeploy(String changeId) =>
      _postChangeAction(changeId, 'arm', const {});

  /// GET /api/change/{id}/pir-draft, a deterministic draft post-implementation
  /// review note assembled server-side from the change's deploy record
  /// (`{"id","status","draft"}`). Used to prefill the Verify sheet; wrapped in
  /// [ChangeActionResult] just like the POST actions above so a fetch failure
  /// surfaces the same way (verbatim server error where the server gave one).
  Future<ChangeActionResult> pirDraft(String changeId) =>
      _getChangeAction(changeId, 'pir-draft');

  /// POST /api/change/{id}/verify with `{note}`, the last step of the
  /// lifecycle: `deployed -> verified`. Refuses 409 unless the change is
  /// `deployed`, refuses 400 on an empty note; both surfaced via
  /// [ChangeActionResult.error]. On success the response carries
  /// `{"verified":true,"id","status":"verified","pir_note":note}`.
  Future<ChangeActionResult> verifyChange(String changeId, String note) =>
      _postChangeAction(changeId, 'verify', {'note': note});
}

/// Body for `POST /api/change/{id}/schedule`, a pure function so the
/// `deploy_mode: "confirm"` lock is unit-testable without any HTTP mocking.
/// `asap: true` omits `window_start`/`window_end` (the server derives its own
/// ASAP window); otherwise both are sent as UTC ISO-8601 when present.
Map<String, dynamic> buildScheduleBody({
  DateTime? windowStart,
  DateTime? windowEnd,
  bool asap = false,
  String note = '',
}) {
  final body = <String, dynamic>{
    'asap': asap,
    // LOCKED: the backend 400s on any value other than "confirm" (Phase 3a).
    'deploy_mode': 'confirm',
    'note': note,
  };
  if (!asap) {
    if (windowStart != null) {
      body['window_start'] = windowStart.toUtc().toIso8601String();
    }
    if (windowEnd != null) {
      body['window_end'] = windowEnd.toUtc().toIso8601String();
    }
  }
  return body;
}

/// Result of a change.* PEP call ([SKCapstoneClient.validateChange] /
/// [SKCapstoneClient.scheduleChange] / [SKCapstoneClient.armChangeDeploy]).
/// [error] carries the server's explanation verbatim on failure (never a
/// generic message when the server supplied one), so the popout can show the
/// same reason a human operator would see.
class ChangeActionResult {
  const ChangeActionResult({required this.ok, this.data, this.error, this.statusCode});

  final bool ok;
  final Map<String, dynamic>? data;
  final String? error;
  final int? statusCode;
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

/// One GTD item (next-action / inbox / waiting-for). `cardId` is the shadow
/// card id (`gtd-ID`) that the AI suggest/queue actions attach to.
class GtdItem {
  const GtdItem({
    required this.id,
    required this.cardId,
    required this.text,
    this.context,
    this.priority,
    this.status,
    this.source,
  });

  final String id;
  final String cardId;
  final String text;
  final String? context;
  final String? priority;
  final String? status;
  final String? source;

  factory GtdItem.fromJson(Map<String, dynamic> j) => GtdItem(
        id: j['id'] as String? ?? '',
        cardId: j['card_id'] as String? ?? 'gtd-${j['id'] ?? ''}',
        text: j['text'] as String? ?? '',
        context: j['context'] as String?,
        priority: j['priority'] as String?,
        status: j['status'] as String?,
        source: j['source'] as String?,
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
    this.itilStatus,
    this.preparedPr,
    this.preparedBy,
    this.validation,
    this.scheduledWindow,
    this.chips,
    this.pirNote,
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

  /// Change-management fields (CM P2.4/P2.5). Present only on change cards
  /// (`kind == 'change'`, id `chg-*`); null on every other card, so the
  /// popout renders nothing extra for them. Sourced straight from the
  /// `/api/kanban` card brief, never refetched.
  final String? itilStatus;
  final Map<String, dynamic>? preparedPr;
  final String? preparedBy;
  final Map<String, dynamic>? validation;
  final Map<String, dynamic>? scheduledWindow;
  final ChangeChips? chips;

  /// The post-implementation review note attached by `POST
  /// /api/change/{id}/verify` (CM P3.3). Null until the change reaches
  /// `itilStatus == 'verified'`.
  final String? pirNote;

  /// True for change-management tickets: the popout's Prepare label, CAB
  /// tally/validation/window chips, and Validate/Schedule/Arm buttons apply
  /// ONLY to these cards (design doc section 8). Checked both ways (kind +
  /// id prefix) so a hand-built card in a test needs to set only one.
  bool get isChange => kind == 'change' || id.startsWith('chg-');

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
        itilStatus: j['itil_status'] as String?,
        preparedPr: (j['prepared_pr'] as Map?)?.cast<String, dynamic>(),
        preparedBy: j['prepared_by'] as String?,
        validation: (j['validation'] as Map?)?.cast<String, dynamic>(),
        scheduledWindow:
            (j['scheduled_window'] as Map?)?.cast<String, dynamic>(),
        chips: j['chips'] is Map
            ? ChangeChips.fromJson((j['chips'] as Map).cast<String, dynamic>())
            : null,
        pirNote: j['pir_note'] as String?,
      );
}

/// CAB tally chip: approve/reject/abstain counts plus the `human` voter's own
/// decision (a distinct marker, not folded into the counts), matching
/// skdashboard's `_cab_chip`.
class ChangeCabTally {
  const ChangeCabTally({
    this.approved = 0,
    this.rejected = 0,
    this.abstain = 0,
    this.humanDecision,
  });

  final int approved;
  final int rejected;
  final int abstain;

  /// 'approved' | 'rejected' | 'abstain' | null (human has not voted yet).
  final String? humanDecision;

  factory ChangeCabTally.fromJson(Map<String, dynamic> j) => ChangeCabTally(
        approved: j['approved'] as int? ?? 0,
        rejected: j['rejected'] as int? ?? 0,
        abstain: j['abstain'] as int? ?? 0,
        humanDecision: j['human_decision'] as String?,
      );
}

/// Validation verdict chip, matching skdashboard's `_validation_chip`. Null
/// on the parent [ChangeChips.validation] when the change has never been
/// validated.
class ChangeValidationVerdict {
  const ChangeValidationVerdict({
    required this.passed,
    required this.checkCount,
    required this.stale,
  });

  final bool passed;
  final int checkCount;

  /// True when the verdict's head SHA no longer matches the PR's current
  /// head: the change moved after it was validated, re-validate before CAB
  /// relies on this.
  final bool stale;

  factory ChangeValidationVerdict.fromJson(Map<String, dynamic> j) =>
      ChangeValidationVerdict(
        passed: j['passed'] as bool? ?? false,
        checkCount: j['check_count'] as int? ?? 0,
        stale: j['stale'] as bool? ?? false,
      );
}

/// Window chip, matching skdashboard's `_window_chip`. `label` is one of
/// `"ASAP"`, a formatted window start (`"Fri 02:00Z"`), `"MISSED"`, or
/// `"none"`.
class ChangeWindowChip {
  const ChangeWindowChip({required this.label, required this.asap});

  final String label;
  final bool asap;

  factory ChangeWindowChip.fromJson(Map<String, dynamic> j) =>
      ChangeWindowChip(
        label: j['label'] as String? ?? 'none',
        asap: j['asap'] as bool? ?? false,
      );
}

/// The three change-card chips a kanban brief carries under `chips`
/// (skdashboard `_change_chips`): CAB tally, validation verdict, window.
class ChangeChips {
  const ChangeChips({
    required this.cab,
    this.validation,
    required this.window,
  });

  final ChangeCabTally cab;
  final ChangeValidationVerdict? validation;
  final ChangeWindowChip window;

  factory ChangeChips.fromJson(Map<String, dynamic> j) => ChangeChips(
        cab: ChangeCabTally.fromJson(
            (j['cab'] as Map?)?.cast<String, dynamic>() ?? const {}),
        validation: j['validation'] is Map
            ? ChangeValidationVerdict.fromJson(
                (j['validation'] as Map).cast<String, dynamic>())
            : null,
        window: ChangeWindowChip.fromJson(
            (j['window'] as Map?)?.cast<String, dynamic>() ?? const {}),
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
