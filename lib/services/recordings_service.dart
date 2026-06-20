import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "backend_config.dart";

/// Compile-time default base URL of the SKChat web-UI that serves the
/// /recordings API + /livekit/record controls. Only the *seed* for the
/// runtime-settable [backendConfigProvider] (see backend_config.dart); the live
/// value comes from there so instances can be repointed without a rebuild.
const kRecordingsDefaultWebuiUrl = kDefaultSkchatWebuiUrl;

/// One recording listed by GET /recordings.
class Recording {
  const Recording({
    required this.name,
    this.sizeBytes,
    this.modified,
    this.room,
  });

  /// File name (the `{name}` path segment for GET /recordings/{name}).
  final String name;

  /// File size in bytes, when the server reports it.
  final int? sizeBytes;

  /// Last-modified time (ISO-8601 or epoch string), when reported.
  final String? modified;

  /// Source room / space, when the server reports it.
  final String? room;

  factory Recording.fromJson(Map<String, dynamic> json) {
    final sizeRaw = json["size"] ?? json["size_bytes"] ?? json["bytes"];
    return Recording(
      name: (json["name"] ?? json["file"] ?? json["filename"] ?? "") as String,
      sizeBytes: sizeRaw is int
          ? sizeRaw
          : (sizeRaw is num ? sizeRaw.toInt() : null),
      modified: (json["modified"] ?? json["mtime"] ?? json["created"])
          as String?,
      room: (json["room"] ?? json["space_id"] ?? json["space"]) as String?,
    );
  }
}

/// Talks to the recordings API on the SKChat web-UI: lists recordings, builds
/// playback/download URLs, and drives the LiveKit / Spaces record controls.
class RecordingsService {
  RecordingsService({Dio? dio, String? webuiBaseUrl})
      : _dio = dio ?? Dio(),
        _base = webuiBaseUrl ?? kRecordingsDefaultWebuiUrl;

  final Dio _dio;
  final String _base;

  /// List available recordings (GET /recordings).
  ///
  /// Tolerates either `{"recordings": [...]}` or a bare top-level array, and
  /// either object entries or bare file-name strings.
  Future<List<Recording>> list() async {
    final r = await _dio.get<dynamic>("$_base/recordings");
    final data = r.data;
    final raw = data is Map<String, dynamic>
        ? (data["recordings"] as List<dynamic>? ?? const [])
        : (data as List<dynamic>? ?? const []);
    return raw.map((e) {
      if (e is String) return Recording(name: e);
      return Recording.fromJson((e as Map).cast<String, dynamic>());
    }).toList();
  }

  /// Direct playback / download URL for a recording (GET /recordings/{name}).
  ///
  /// Returned as a URL string so the UI can hand it to a media player, an
  /// `<a download>`, or `url_launcher` without streaming bytes through Dart.
  String fetchUrl(String name) =>
      "$_base/recordings/${Uri.encodeComponent(name)}";

  /// Fetch a recording's bytes (GET /recordings/{name}).
  ///
  /// Use [fetchUrl] for streaming playback / download; this is for the rare
  /// case where the caller needs the raw bytes in-process.
  Future<List<int>> fetchBytes(String name) async {
    final r = await _dio.get<List<int>>(
      fetchUrl(name),
      options: Options(responseType: ResponseType.bytes),
    );
    return r.data ?? const [];
  }

  /// Start a LiveKit room recording (POST /livekit/record/start).
  Future<void> recordStart(String room) =>
      _post("/livekit/record/start", {"room": room});

  /// Stop a LiveKit room recording (POST /livekit/record/stop).
  Future<void> recordStop(String room) =>
      _post("/livekit/record/stop", {"room": room});

  /// Start a Space recording (POST /spaces/{id}/record/start).
  Future<void> spaceRecordStart(String id, {required String requester}) =>
      _post("/spaces/$id/record/start", {"requester": requester});

  /// Stop a Space recording (POST /spaces/{id}/record/stop).
  Future<void> spaceRecordStop(String id, {required String requester}) =>
      _post("/spaces/$id/record/stop", {"requester": requester});

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final r = await _dio.post<Map<String, dynamic>>("$_base$path", data: body);
    return r.data ?? const {};
  }
}

/// Recordings service repointed live by the runtime backend config. Watching
/// [backendConfigProvider] rebuilds the service (and so the base URL) whenever
/// the user switches federation instances.
final recordingsServiceProvider = Provider<RecordingsService>((ref) {
  final base = ref.watch(
    backendConfigProvider.select((c) => c.skchatWebuiUrl),
  );
  return RecordingsService(webuiBaseUrl: base);
});
