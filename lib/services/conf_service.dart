import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "spaces_service.dart" show kDefaultWebuiUrl;

// ── Models ──────────────────────────────────────────────────────────────────

/// Result of POST /conf/create — the newly minted conference room id.
class ConfRoom {
  const ConfRoom({required this.room, this.title = "", this.hostFqid = ""});

  final String room;
  final String title;
  final String hostFqid;

  factory ConfRoom.fromJson(Map<String, dynamic> j) => ConfRoom(
        room: j["room"] as String? ?? "",
        title: j["title"] as String? ?? "",
        hostFqid: j["host_fqid"] as String? ?? "",
      );
}

/// Role-scoped LiveKit token for a conference, returned by
/// POST /conf/{room}/token. Mirrors [SpaceJoin] but for conferences: the
/// `url` is the LiveKit ws endpoint and `token` is the role-scoped JWT.
class ConfToken {
  const ConfToken({
    required this.room,
    required this.url,
    required this.token,
    required this.identity,
    required this.role,
    this.title = "",
  });

  final String room;
  final String url;
  final String token;
  final String identity;
  final String role;
  final String title;

  bool get isHost => role == "host";

  factory ConfToken.fromJson(Map<String, dynamic> j) => ConfToken(
        room: j["room"] as String? ?? "",
        url: j["url"] as String? ?? j["livekit_url"] as String? ?? "",
        token: j["token"] as String? ?? "",
        identity: j["identity"] as String? ?? "",
        role: j["role"] as String? ?? "guest",
        title: j["title"] as String? ?? "",
      );
}

/// A conference participant (joined media room).
class ConfParticipant {
  const ConfParticipant({
    required this.identity,
    this.name = "",
    this.role = "guest",
    this.isAgent = false,
  });

  final String identity;
  final String name;
  final String role;
  final bool isAgent;

  factory ConfParticipant.fromJson(Map<String, dynamic> j) => ConfParticipant(
        identity: j["identity"] as String? ?? "",
        name: j["name"] as String? ?? "",
        role: j["role"] as String? ?? "guest",
        isAgent: j["is_agent"] as bool? ?? j["agent"] as bool? ?? false,
      );
}

/// A guest sitting in the waiting room, awaiting host admit/deny.
///
/// The server (``PendingGuest.to_dict``) serializes the chosen label under
/// ``display``; older payloads used ``name``, so both keys are accepted.
class WaitingGuest {
  const WaitingGuest({required this.identity, this.name = ""});

  final String identity;
  final String name;

  factory WaitingGuest.fromJson(Map<String, dynamic> j) => WaitingGuest(
        identity: j["identity"] as String? ?? "",
        name: j["display"] as String? ?? j["name"] as String? ?? "",
      );
}

/// Outcome of a guest POST to ``/conf/{room}/waiting``.
///
/// Tailnet callers are auto-admitted server-side ([autoAdmitted] true); a guest
/// who was previously admitted gets [admitted] true immediately. Otherwise the
/// guest sits in the lobby ([admitted] false) with a queue [position] and a
/// human-readable [message]. A host denial surfaces as [denied] (the server
/// answers a re-entry attempt with HTTP 403, which the service maps here).
class WaitingStatus {
  const WaitingStatus({
    required this.admitted,
    this.denied = false,
    this.autoAdmitted = false,
    this.position = 0,
    this.message = "",
  });

  final bool admitted;
  final bool denied;
  final bool autoAdmitted;
  final int position;
  final String message;

  factory WaitingStatus.fromJson(Map<String, dynamic> j) => WaitingStatus(
        admitted: j["admitted"] as bool? ?? false,
        denied: j["denied"] as bool? ?? false,
        autoAdmitted: j["auto_admitted"] as bool? ?? false,
        position: (j["position"] as num?)?.toInt() ?? 0,
        message: j["message"] as String? ?? "",
      );

  static const denyMessage = "The host denied your request to join.";
}

// ── Service ─────────────────────────────────────────────────────────────────

/// Talks to the sovereign conference REST surface on the SKChat web-UI.
///
/// Shares the same configurable web-UI base URL as [SpacesService] /
/// [LiveKitCallService] — the LiveKit token mint host. Override at build time
/// with `--dart-define=SKCHAT_WEBUI_URL=https://host.tail-net.ts.net`.
///
/// Endpoints wrapped:
/// - POST /conf/create
/// - POST /conf/{room}/token   {identity,name,role}
/// - GET  /conf/{room}/participants
/// - POST /conf/{room}/end
/// - POST /conf/{room}/waiting (guest enters)  / GET (host view)
/// - POST /conf/{room}/admit  / POST /conf/{room}/deny
/// - POST /conf/{room}/invite-agent / POST /conf/{room}/remove-agent
class ConfService {
  ConfService({Dio? dio, String? webuiBaseUrl})
      : _dio = dio ?? Dio(),
        _base = webuiBaseUrl ?? kDefaultWebuiUrl;

  final Dio _dio;
  final String _base;

  /// Create a new conference room.
  Future<ConfRoom> create({
    String? hostFqid,
    String? title,
    String? slug,
  }) async {
    final r = await _post("/conf/create", {
      if (hostFqid != null) "host_fqid": hostFqid,
      if (title != null) "title": title,
      if (slug != null) "slug": slug,
    });
    return ConfRoom.fromJson(r);
  }

  /// Mint a role-scoped LiveKit token for [room].
  Future<ConfToken> token(
    String room, {
    required String identity,
    String? name,
    String role = "guest",
  }) async {
    final r = await _post("/conf/$room/token", {
      "identity": identity,
      "name": name ?? identity,
      "role": role,
    });
    return ConfToken.fromJson(r);
  }

  /// List participants currently in the conference media room.
  Future<List<ConfParticipant>> participants(String room) async {
    final r = await _dio.get<Map<String, dynamic>>("$_base/conf/$room/participants");
    final list = (r.data?["participants"] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return list.map(ConfParticipant.fromJson).toList();
  }

  /// End the conference (host only).
  Future<void> end(String room, {String? requester}) =>
      _post("/conf/$room/end", {if (requester != null) "requester": requester});

  // ── Waiting room ──────────────────────────────────────────────────────────

  /// Guest enters the waiting room for [room], returning the lobby outcome.
  ///
  /// The server reads the label under ``display``. A host denial comes back as
  /// HTTP 403 on a (re-)entry attempt; that is mapped to a denied
  /// [WaitingStatus] rather than thrown, so a polling caller can react cleanly.
  Future<WaitingStatus> enterWaiting(String room,
      {required String identity, String? display}) async {
    try {
      final r = await _post("/conf/$room/waiting", {
        "identity": identity,
        "display": display ?? identity.split("@").first,
      });
      return WaitingStatus.fromJson(r);
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        return const WaitingStatus(
          admitted: false,
          denied: true,
          message: WaitingStatus.denyMessage,
        );
      }
      rethrow;
    }
  }

  /// Host view: list guests waiting to be admitted.
  Future<List<WaitingGuest>> waitingList(String room) async {
    final r = await _dio.get<Map<String, dynamic>>("$_base/conf/$room/waiting");
    final list = (r.data?["waiting"] as List<dynamic>? ??
            r.data?["guests"] as List<dynamic>? ??
            const [])
        .cast<Map<String, dynamic>>();
    return list.map(WaitingGuest.fromJson).toList();
  }

  /// Host admits a waiting guest.
  Future<void> admit(String room,
          {required String identity, String? requester}) =>
      _post("/conf/$room/admit", {
        "identity": identity,
        if (requester != null) "requester": requester,
      });

  /// Host denies a waiting guest.
  Future<void> deny(String room,
          {required String identity, String? requester}) =>
      _post("/conf/$room/deny", {
        "identity": identity,
        if (requester != null) "requester": requester,
      });

  // ── Agents ────────────────────────────────────────────────────────────────

  /// Host invites an agent into the conference.
  Future<void> inviteAgent(String room,
          {required String agent, String? requester}) =>
      _post("/conf/$room/invite-agent", {
        "agent": agent,
        if (requester != null) "requester": requester,
      });

  /// Host removes an agent from the conference.
  Future<void> removeAgent(String room,
          {required String agent, String? requester}) =>
      _post("/conf/$room/remove-agent", {
        "agent": agent,
        if (requester != null) "requester": requester,
      });

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final r = await _dio.post<Map<String, dynamic>>("$_base$path", data: body);
    return r.data ?? const {};
  }
}

final confServiceProvider = Provider<ConfService>((ref) => ConfService());
