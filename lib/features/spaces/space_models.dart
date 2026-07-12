/// Models for SK Spaces, sovereign audio rooms.
class SpaceSummary {
  const SpaceSummary({
    required this.spaceId,
    required this.title,
    required this.hostFqid,
    required this.status,
    required this.speakers,
    required this.recording,
  });

  final String spaceId;
  final String title;
  final String hostFqid;
  final String status;
  final List<String> speakers;
  final bool recording;

  factory SpaceSummary.fromJson(Map<String, dynamic> j) => SpaceSummary(
        spaceId: j["space_id"] as String? ?? "",
        title: j["title"] as String? ?? "",
        hostFqid: j["host_fqid"] as String? ?? "",
        status: j["status"] as String? ?? "open",
        speakers:
            (j["speakers"] as List<dynamic>? ?? const []).cast<String>(),
        recording: j["recording"] as bool? ?? false,
      );
}

/// A join result: a role-scoped LiveKit token + the room + ws url.
class SpaceJoin {
  const SpaceJoin({
    required this.spaceId,
    required this.room,
    required this.url,
    required this.identity,
    required this.role,
    required this.token,
    required this.title,
  });

  final String spaceId;
  final String room;
  final String url;
  final String identity;
  final String role;
  final String token;
  final String title;

  bool get isHost => role == "host";

  factory SpaceJoin.fromJson(Map<String, dynamic> j) => SpaceJoin(
        spaceId: j["space_id"] as String? ?? "",
        room: j["room"] as String? ?? "",
        url: j["url"] as String? ?? "",
        identity: j["identity"] as String? ?? "",
        role: j["role"] as String? ?? "listener",
        token: j["token"] as String? ?? "",
        title: j["title"] as String? ?? "",
      );
}
