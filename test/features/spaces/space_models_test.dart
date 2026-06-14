// Unit tests for the SK Spaces models (pure JSON deserialization + role logic).
//
// SpacesService exercises these via canned HTTP responses; these tests pin the
// model contract directly (defaults, role flags, missing fields).
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/space_models.dart";

void main() {
  group("SpaceSummary.fromJson", () {
    test("parses a complete summary", () {
      final s = SpaceSummary.fromJson({
        "space_id": "s1",
        "title": "Town Hall",
        "host_fqid": "chef@dk.skworld",
        "status": "live",
        "speakers": ["chef@dk.skworld", "lumina@dk.skworld"],
        "recording": true,
      });
      expect(s.spaceId, "s1");
      expect(s.title, "Town Hall");
      expect(s.hostFqid, "chef@dk.skworld");
      expect(s.status, "live");
      expect(s.speakers, ["chef@dk.skworld", "lumina@dk.skworld"]);
      expect(s.recording, isTrue);
    });

    test("applies sane defaults for missing fields", () {
      final s = SpaceSummary.fromJson({});
      expect(s.spaceId, "");
      expect(s.title, "");
      expect(s.hostFqid, "");
      expect(s.status, "open"); // default status
      expect(s.speakers, isEmpty);
      expect(s.recording, isFalse);
    });
  });

  group("SpaceJoin.fromJson + isHost", () {
    test("parses a host join (isHost true)", () {
      final j = SpaceJoin.fromJson({
        "space_id": "s1",
        "room": "sk-space-s1",
        "url": "wss://lk.test/ws",
        "identity": "chef@dk.skworld",
        "role": "host",
        "token": "jwt-host",
        "title": "Town Hall",
      });
      expect(j.role, "host");
      expect(j.isHost, isTrue);
      expect(j.room, "sk-space-s1");
      expect(j.url, "wss://lk.test/ws");
      expect(j.token, "jwt-host");
    });

    test("parses a listener join (isHost false)", () {
      final j = SpaceJoin.fromJson({
        "space_id": "s1",
        "role": "listener",
      });
      expect(j.role, "listener");
      expect(j.isHost, isFalse);
    });

    test("defaults role to listener when absent", () {
      final j = SpaceJoin.fromJson({});
      expect(j.role, "listener");
      expect(j.isHost, isFalse);
      expect(j.spaceId, "");
      expect(j.token, "");
    });
  });
}
