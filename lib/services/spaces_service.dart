import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../features/spaces/space_models.dart";
import "backend_config.dart";

/// Compile-time default base URL of the SKChat web-UI that serves the /spaces
/// API + /livekit/token. This is now only the *seed* for the runtime-settable
/// [backendConfigProvider] (see backend_config.dart); the live value comes from
/// there so the user can repoint instances without a rebuild.
const kDefaultWebuiUrl = kDefaultSkchatWebuiUrl;

/// Talks to the sovereign SK Spaces API on the SKChat web-UI.
class SpacesService {
  SpacesService({Dio? dio, String? webuiBaseUrl})
      : _dio = dio ?? Dio(),
        _base = webuiBaseUrl ?? kDefaultWebuiUrl;

  final Dio _dio;
  final String _base;

  Future<List<SpaceSummary>> listLive() async {
    final r = await _dio.get<Map<String, dynamic>>("$_base/spaces");
    final spaces = (r.data?["spaces"] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return spaces.map(SpaceSummary.fromJson).toList();
  }

  Future<SpaceJoin> create({
    required String hostFqid,
    required String title,
    required String slug,
  }) =>
      _join("/spaces/create",
          {"host_fqid": hostFqid, "title": title, "slug": slug});

  Future<SpaceJoin> joinListener(String id,
          {required String identity, String? name}) =>
      _join("/spaces/$id/join", {"identity": identity, "name": name ?? identity});

  Future<SpaceJoin> joinHost(String id, {required String requester}) =>
      _join("/spaces/$id/join-host", {"requester": requester});

  Future<bool> raiseHand(String id, {required String identity}) async {
    final r = await _post("/spaces/$id/raise-hand", {"identity": identity});
    return r["on_stage"] as bool? ?? false;
  }

  Future<void> invite(String id,
          {required String requester, required String identity}) =>
      _post("/spaces/$id/invite", {"requester": requester, "identity": identity});

  Future<void> removeFromStage(String id,
          {required String requester, required String identity}) =>
      _post("/spaces/$id/remove-from-stage",
          {"requester": requester, "identity": identity});

  Future<void> mute(String id,
          {required String requester,
          required String identity,
          required String trackSid}) =>
      _post("/spaces/$id/mute",
          {"requester": requester, "identity": identity, "track_sid": trackSid});

  Future<void> kick(String id,
          {required String requester, required String identity}) =>
      _post("/spaces/$id/kick", {"requester": requester, "identity": identity});

  /// SHARECTL-app: host-only. Disables (`allow: false`) or restores
  /// (`allow: true`) a speaker's VIDEO sharing (camera + screen-share);
  /// their microphone is left untouched either way. Mirrors the
  /// mute/kick/invite moderation calls above. Returns the server's
  /// resulting `sharing` flag (mirrors [raiseHand]'s `on_stage` return),
  /// defaulting to the requested [allow] if the server omits it.
  Future<bool> setSharing(String id,
      {required String requester,
      required String identity,
      required bool allow}) async {
    final r = await _post("/spaces/$id/set-sharing",
        {"requester": requester, "identity": identity, "allow": allow});
    return r["sharing"] as bool? ?? allow;
  }

  Future<void> end(String id, {required String requester}) =>
      _post("/spaces/$id/end", {"requester": requester});

  Future<void> consent(String id, {required String identity}) =>
      _post("/spaces/$id/consent", {"identity": identity});

  Future<void> recordStart(String id, {required String requester}) =>
      _post("/spaces/$id/record/start", {"requester": requester});

  Future<void> recordStop(String id, {required String requester}) =>
      _post("/spaces/$id/record/stop", {"requester": requester});

  Future<SpaceJoin> _join(String path, Map<String, dynamic> body) async {
    final r = await _post(path, body);
    return SpaceJoin.fromJson(r);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await _dio.post<Map<String, dynamic>>("$_base$path", data: body);
    return r.data ?? const {};
  }
}

/// Spaces service repointed live by the runtime backend config. Watching
/// [backendConfigProvider] rebuilds the service (and so the base URL) whenever
/// the user switches federation instances.
final spacesServiceProvider = Provider<SpacesService>((ref) {
  final base = ref.watch(
    backendConfigProvider.select((c) => c.skchatWebuiUrl),
  );
  return SpacesService(webuiBaseUrl: base);
});
