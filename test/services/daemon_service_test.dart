// Unit tests for DaemonService pure helpers + the CLI message DTO.
//
// Health/inbox/send are I/O (HTTP 9385 + dart:io Process) and are NOT unit
// tested here — they require a live skchat daemon / CLI on the host and are
// covered as device/manual use cases in the QA report.
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/daemon_service.dart";

void main() {
  group("DaemonService.peerShortName", () {
    test("strips the capauth: scheme and @domain", () {
      expect(
        DaemonService.peerShortName("capauth:lumina@skworld.io"),
        "lumina",
      );
    });

    test("handles a bare name with no scheme or domain", () {
      expect(DaemonService.peerShortName("opus"), "opus");
    });

    test("strips @domain when no scheme is present", () {
      expect(DaemonService.peerShortName("jarvis@dk.skworld"), "jarvis");
    });

    test("strips scheme when no @domain is present", () {
      expect(DaemonService.peerShortName("capauth:ava"), "ava");
    });
  });

  group("SkchatCliMessage.fromJson", () {
    test("parses a complete message and round-trips the id", () {
      final m = SkchatCliMessage.fromJson({
        "sender": "capauth:lumina@skworld.io",
        "recipient": "capauth:opus@skworld.io",
        "content": "hello",
        "thread_id": "t-1",
        "timestamp": "2026-03-03T12:00:00.000Z",
      });
      expect(m.sender, "capauth:lumina@skworld.io");
      expect(m.recipient, "capauth:opus@skworld.io");
      expect(m.content, "hello");
      expect(m.threadId, "t-1");
      expect(m.timestamp,
          DateTime.parse("2026-03-03T12:00:00.000Z"));
      // id = sender_<ms>
      expect(
        m.id,
        "capauth:lumina@skworld.io_${m.timestamp.millisecondsSinceEpoch}",
      );
    });

    test("defaults missing string fields to empty and threadId to null", () {
      final m = SkchatCliMessage.fromJson({
        "timestamp": "2026-03-03T12:00:00.000Z",
      });
      expect(m.sender, "");
      expect(m.recipient, "");
      expect(m.content, "");
      expect(m.threadId, isNull);
    });

    test("falls back to now() for a non-string timestamp", () {
      final before = DateTime.now();
      final m = SkchatCliMessage.fromJson({
        "sender": "x",
        "recipient": "y",
        "content": "z",
        "timestamp": 12345, // not a String
      });
      final after = DateTime.now();
      expect(
        m.timestamp.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        m.timestamp.isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test("falls back to now() for an unparseable timestamp string", () {
      final m = SkchatCliMessage.fromJson({
        "sender": "x",
        "recipient": "y",
        "content": "z",
        "timestamp": "not-a-date",
      });
      // Should not throw and yields a sane DateTime.
      expect(m.timestamp, isA<DateTime>());
    });
  });
}
