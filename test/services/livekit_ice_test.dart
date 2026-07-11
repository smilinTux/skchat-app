import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:skchat/services/livekit_call_service.dart";

void main() {
  group("parseIceServers", () {
    test("maps a full sovereign TURN entry (list urls + creds)", () {
      final servers = LiveKitCallService.parseIceServers([
        {
          "urls": ["turn:noroc2027.tail204f0c.ts.net:3478?transport=udp"],
          "username": "1720000000:chef",
          "credential": "abc123",
        },
      ]);
      expect(servers, hasLength(1));
      expect(servers.first.urls,
          ["turn:noroc2027.tail204f0c.ts.net:3478?transport=udp"]);
      expect(servers.first.username, "1720000000:chef");
      expect(servers.first.credential, "abc123");
    });

    test("normalizes a single-string urls into a list", () {
      final servers = LiveKitCallService.parseIceServers([
        {"urls": "stun:stun.l.google.com:19302"},
      ]);
      expect(servers, hasLength(1));
      expect(servers.first.urls, ["stun:stun.l.google.com:19302"]);
      // A bare STUN entry carries no creds.
      expect(servers.first.username, isNull);
      expect(servers.first.credential, isNull);
    });

    test("maps multiple entries and preserves order", () {
      final servers = LiveKitCallService.parseIceServers([
        {
          "urls": ["stun:stun.l.google.com:19302"],
        },
        {
          "urls": ["turn:relay.example:3478"],
          "username": "u",
          "credential": "c",
        },
      ]);
      expect(servers, hasLength(2));
      expect(servers[0].urls, ["stun:stun.l.google.com:19302"]);
      expect(servers[1].urls, ["turn:relay.example:3478"]);
    });

    test("skips entries with no usable urls and non-object rows", () {
      final servers = LiveKitCallService.parseIceServers([
        {"urls": <String>[]},
        {"username": "no-urls"},
        "not-a-map",
        {"urls": ""},
        {
          "urls": ["turn:good:3478"],
        },
      ]);
      expect(servers, hasLength(1));
      expect(servers.first.urls, ["turn:good:3478"]);
    });

    test("filters non-string url list members but keeps valid ones", () {
      final servers = LiveKitCallService.parseIceServers([
        {
          "urls": ["turn:ok:3478", 42, null, "turn:ok2:3478"],
        },
      ]);
      expect(servers, hasLength(1));
      expect(servers.first.urls, ["turn:ok:3478", "turn:ok2:3478"]);
    });

    test("never throws on a malformed (non-list) payload", () {
      expect(LiveKitCallService.parseIceServers(null), isEmpty);
      expect(LiveKitCallService.parseIceServers("nope"), isEmpty);
      expect(LiveKitCallService.parseIceServers(123), isEmpty);
      expect(LiveKitCallService.parseIceServers({"a": 1}), isEmpty);
    });
  });

  group("parseIcePolicy", () {
    test("maps 'relay' to relay", () {
      expect(LiveKitCallService.parseIcePolicy("relay"),
          RTCIceTransportPolicy.relay);
    });

    test("defaults 'all' / missing / junk to all", () {
      expect(LiveKitCallService.parseIcePolicy("all"),
          RTCIceTransportPolicy.all);
      expect(
          LiveKitCallService.parseIcePolicy(null), RTCIceTransportPolicy.all);
      expect(LiveKitCallService.parseIcePolicy("banana"),
          RTCIceTransportPolicy.all);
    });
  });

  group("fetchIceConfig", () {
    test("a fetch failure returns null and does not throw", () async {
      // Point the service at an unreachable host so the GET fails fast
      // (connection refused). The fetch must swallow it and yield null rather
      // than propagate, so a call never blocks on the ICE lookup.
      final svc = LiveKitCallService(webuiBaseUrl: "http://127.0.0.1:1");
      final cfg = await svc.fetchIceConfig("chef");
      expect(cfg, isNull);
    });
  });
}
