import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/cluster_service.dart";

/// Canned-response adapter for the JSON endpoints. Resolves by path and
/// records the last request (body + method) for assertions. For the SSE
/// endpoints (`/api/up`, `/api/logs`) it streams pre-baked `data:` frames.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes, {this.sseFrames = const {}});

  /// path → JSON body for plain endpoints.
  final Map<String, Object?> routes;

  /// path → list of `data:` payloads (already JSON strings) for SSE endpoints.
  final Map<String, List<String>> sseFrames;

  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    final path = options.uri.path;

    if (sseFrames.containsKey(path)) {
      // Emit one SSE event per frame: `data: <payload>\n\n`.
      final frames = sseFrames[path]!;
      final controller = StreamController<Uint8List>();
      scheduleMicrotask(() async {
        for (final f in frames) {
          controller.add(Uint8List.fromList(utf8.encode("data: $f\n\n")));
        }
        await controller.close();
      });
      return ResponseBody(
        controller.stream,
        200,
        headers: {
          Headers.contentTypeHeader: ["text/event-stream"],
        },
      );
    }

    final body = routes[path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  late _CannedAdapter adapter;
  late Dio dio;
  late ClusterService svc;

  ClusterService build({Map<String, List<String>> sse = const {}}) {
    adapter = _CannedAdapter(adapter.routes, sseFrames: sse);
    dio = Dio()..httpClientAdapter = adapter;
    return ClusterService(dio: dio, baseUrl: "http://test.local:8774");
  }

  setUp(() {
    adapter = _CannedAdapter({});
    dio = Dio()..httpClientAdapter = adapter;
    svc = ClusterService(dio: dio, baseUrl: "http://test.local:8774");
  });

  test("listServices parses the catalog", () async {
    adapter.routes["/api/services"] = {
      "services": [
        {
          "name": "postgres",
          "path": "v2/postgres",
          "capability": "database",
          "provider": "cnpg",
          "ha": true,
          "min_replicas": 2,
          "config": {"storage": "10Gi"},
          "secrets": ["pg-password"],
        },
      ],
    };

    final svcs = await svc.listServices();
    expect(svcs, hasLength(1));
    expect(svcs.first.name, "postgres");
    expect(svcs.first.ha, isTrue);
    expect(svcs.first.minReplicas, 2);
    expect(svcs.first.config["storage"], "10Gi");
    expect(svcs.first.secrets, ["pg-password"]);
  });

  test("status parses installed stacks + deployed services", () async {
    adapter.routes["/api/status"] = {
      "clusters": [
        {
          "cluster": "skbloom",
          "steps_done": 7,
          "complete": true,
          "services": [
            {"name": "redis", "url": "https://redis.local"},
            {"name": "postgres", "url": null},
          ],
        },
      ],
    };

    final stacks = await svc.status();
    expect(stacks, hasLength(1));
    expect(stacks.first.cluster, "skbloom");
    expect(stacks.first.complete, isTrue);
    expect(stacks.first.services, hasLength(2));
    expect(stacks.first.services.first.url, "https://redis.local");
    expect(stacks.first.services[1].url, isNull);
  });

  test("health parses per-service readiness", () async {
    adapter.routes["/api/health"] = {
      "services": [
        {"name": "postgres", "ready": 2, "total": 2, "healthy": true},
        {"name": "redis", "ready": 0, "total": 1, "healthy": false},
      ],
    };

    final health = await svc.health();
    expect(health, hasLength(2));
    expect(health.first.healthy, isTrue);
    expect(health[1].ready, 0);
    expect(health[1].healthy, isFalse);
  });

  test("propose parses reply, profile, plan and rotation", () async {
    adapter.routes["/api/propose"] = {
      "reply": "I'll set up postgres + redis.",
      "profile": {
        "cluster": "skbloom",
        "services": ["postgres", "redis"],
      },
      "plan": ["preflight", "deploy:postgres", "deploy:redis", "final-check"],
      "rotation": {"secrets": 2, "certs": 1, "all_automatic": true},
    };

    final p = await svc.propose("a postgres + redis stack");
    expect(p.reply, contains("postgres"));
    expect(p.services, ["postgres", "redis"]);
    expect(p.plan, hasLength(4));
    expect(p.rotationSecrets, 2);
    expect(p.rotationCerts, 1);
    expect(p.rotationAllAutomatic, isTrue);

    // The request body carries the intent + default cluster.
    final sent = adapter.lastRequest!.data as Map;
    expect(sent["intent"], "a postgres + redis stack");
    expect(sent["cluster"], "skbloom");

    // And it can be turned into a Profile for /api/up.
    final profile = p.toProfile(tls: true);
    expect(profile.services, ["postgres", "redis"]);
    expect(profile.tls, isTrue);
  });

  test("restart posts the right body and parses the envelope", () async {
    adapter.routes["/api/restart"] = {"ok": true, "output": "restarted"};

    final r = await svc.restart("redis", cluster: "skbloom");
    expect(r.ok, isTrue);
    expect(r.output, "restarted");

    final sent = adapter.lastRequest!.data as Map;
    expect(sent["service"], "redis");
    expect(sent["cluster"], "skbloom");
  });

  test("scale posts replicas and parses the envelope", () async {
    adapter.routes["/api/scale"] = {"ok": true, "output": "scaled"};

    final r = await svc.scale("redis", 3);
    expect(r.ok, isTrue);

    final sent = adapter.lastRequest!.data as Map;
    expect(sent["replicas"], 3);
    expect(sent["service"], "redis");
  });

  test("up consumes the SSE step stream into UpEvents", () async {
    svc = build(sse: {
      "/api/up": [
        jsonEncode({"step": "preflight", "status": "ok"}),
        jsonEncode({"step": "deploy:postgres", "status": "start"}),
        jsonEncode({"step": "deploy:postgres", "status": "ok"}),
        jsonEncode({"step": "final-check", "status": "done"}),
      ],
    });

    final events = await svc
        .up(const ClusterProfile(cluster: "skbloom", services: ["postgres"]))
        .toList();

    expect(events, hasLength(4));
    expect(events.first.step, "preflight");
    expect(events.first.status, "ok");
    expect(events.last.step, "final-check");
    expect(events.every((e) => !e.isError), isTrue);
  });

  test("up surfaces an error frame", () async {
    svc = build(sse: {
      "/api/up": [
        jsonEncode({"step": "deploy:redis", "status": "error", "error": "boom"}),
      ],
    });

    final events = await svc
        .up(const ClusterProfile(cluster: "skbloom", services: ["redis"]))
        .toList();

    expect(events, hasLength(1));
    expect(events.first.isError, isTrue);
    expect(events.first.detail, "boom");
  });

  test("logs consumes the SSE log-line stream (JSON-encoded strings)", () async {
    svc = build(sse: {
      "/api/logs": [
        jsonEncode("starting up"),
        jsonEncode("listening on :5432"),
      ],
    });

    final lines = await svc.logs("postgres").toList();
    expect(lines, ["starting up", "listening on :5432"]);
  });
}
