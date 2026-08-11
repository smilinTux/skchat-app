import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

SkcodeEvent _ev({
  String type = "assistant_text",
  String text = "",
  Map<String, dynamic> data = const {},
  int seq = 1,
  double ts = 1000.0,
  String sid = "s-1",
}) =>
    SkcodeEvent(type: type, text: text, data: data, seq: seq, ts: ts, sid: sid);

void main() {
  group("every ActivityRenderClass has a tone (spec section 6)", () {
    test(
      "kDefaultToneForClass covers all 16 render classes",
      () {
        expect(kDefaultToneForClass.length, ActivityRenderClass.values.length);
        for (final rc in ActivityRenderClass.values) {
          expect(
            kDefaultToneForClass.containsKey(rc),
            isTrue,
            reason: "$rc has no default tone",
          );
        }
      },
    );

    test("all 16 render classes are declared", () {
      expect(ActivityRenderClass.values, hasLength(16));
      expect(
        ActivityRenderClass.values.map((v) => v.name).toSet(),
        {
          "message",
          "fileEdit",
          "fileRead",
          "skillRead",
          "shell",
          "mcpOp",
          "status",
          "thought",
          "plan",
          "permission",
          "diff",
          "image",
          "error",
          "generic",
          "raw",
          "suppressed",
        },
      );
    });

    test("all 4 tones are declared", () {
      expect(ActivityTone.values, hasLength(4));
      expect(
        ActivityTone.values.map((v) => v.name).toSet(),
        {"read", "write", "admin", "neutral"},
      );
    });

    test("all 4 tool statuses are declared", () {
      expect(ToolStatus.values, hasLength(4));
      expect(
        ToolStatus.values.map((v) => v.name).toSet(),
        {"executing", "completed", "failed", "pending"},
      );
    });
  });

  group("classifySkcodeEvent: the mapping table (spec section 6), one row per case", () {
    test("assistant_text -> message/neutral", () {
      final c = classifySkcodeEvent(_ev(type: "assistant_text", text: "hi"));
      expect(c.renderClass, ActivityRenderClass.message);
      expect(c.tone, ActivityTone.neutral);
    });

    test("status init -> status/neutral", () {
      final c = classifySkcodeEvent(
        _ev(type: "status", data: {"subtype": "init", "model": "claude"}),
      );
      expect(c.renderClass, ActivityRenderClass.status);
      expect(c.tone, ActivityTone.neutral);
    });

    test("status attached -> status/neutral", () {
      final c = classifySkcodeEvent(_ev(type: "status", data: {"subtype": "attached"}));
      expect(c.renderClass, ActivityRenderClass.status);
      expect(c.tone, ActivityTone.neutral);
    });

    test("status result ok -> status/neutral", () {
      final c = classifySkcodeEvent(
        _ev(type: "status", data: {"subtype": "result", "is_error": false}),
      );
      expect(c.renderClass, ActivityRenderClass.status);
      expect(c.tone, ActivityTone.neutral);
    });

    test("status result is_error -> error/neutral", () {
      final c = classifySkcodeEvent(
        _ev(type: "status", data: {"subtype": "result", "is_error": true}),
      );
      expect(c.renderClass, ActivityRenderClass.error);
      expect(c.tone, ActivityTone.neutral);
    });

    test("needs_input -> permission/admin", () {
      final c = classifySkcodeEvent(_ev(type: "needs_input"));
      expect(c.renderClass, ActivityRenderClass.permission);
      expect(c.tone, ActivityTone.admin);
    });

    test("diff -> diff/write", () {
      final c = classifySkcodeEvent(_ev(type: "diff"));
      expect(c.renderClass, ActivityRenderClass.diff);
      expect(c.tone, ActivityTone.write);
    });

    for (final tool in const ["Read", "Glob", "Grep", "WebFetch", "WebSearch"]) {
      test("tool_call $tool -> fileRead/read", () {
        final c = classifySkcodeEvent(
          _ev(type: "tool_call", text: tool, data: {"id": "t1", "name": tool}),
        );
        expect(c.renderClass, ActivityRenderClass.fileRead);
        expect(c.tone, ActivityTone.read);
        expect(c.status, ToolStatus.executing);
      });
    }

    for (final tool in const ["Edit", "Write", "NotebookEdit"]) {
      test("tool_call $tool -> fileEdit/write", () {
        final c = classifySkcodeEvent(
          _ev(type: "tool_call", text: tool, data: {"id": "t1", "name": tool}),
        );
        expect(c.renderClass, ActivityRenderClass.fileEdit);
        expect(c.tone, ActivityTone.write);
        expect(c.status, ToolStatus.executing);
      });
    }

    test("tool_call Bash -> shell/write", () {
      final c = classifySkcodeEvent(
        _ev(type: "tool_call", text: "Bash", data: {"id": "t1", "name": "Bash"}),
      );
      expect(c.renderClass, ActivityRenderClass.shell);
      expect(c.tone, ActivityTone.write);
      expect(c.status, ToolStatus.executing);
    });

    test("tool_call Skill -> skillRead/read", () {
      final c = classifySkcodeEvent(
        _ev(type: "tool_call", text: "Skill", data: {"id": "t1", "name": "Skill"}),
      );
      expect(c.renderClass, ActivityRenderClass.skillRead);
      expect(c.tone, ActivityTone.read);
      expect(c.status, ToolStatus.executing);
    });

    for (final tool in const ["Task", "Agent"]) {
      test("tool_call $tool -> generic/write, labelled 'Launched agent'", () {
        final c = classifySkcodeEvent(
          _ev(type: "tool_call", text: tool, data: {"id": "t1", "name": tool}),
        );
        expect(c.renderClass, ActivityRenderClass.generic);
        expect(c.tone, ActivityTone.write);
        expect(c.status, ToolStatus.executing);
        expect(c.label, "Launched agent");
      });
    }

    test("tool_call TodoWrite -> plan/neutral", () {
      final c = classifySkcodeEvent(
        _ev(type: "tool_call", text: "TodoWrite", data: {"id": "t1", "name": "TodoWrite"}),
      );
      expect(c.renderClass, ActivityRenderClass.plan);
      expect(c.tone, ActivityTone.neutral);
      expect(c.status, ToolStatus.executing);
    });

    group("mcpOp verb heuristic", () {
      for (final verb in const ["get", "list", "search", "status", "show"]) {
        test("mcp__server__${verb}_thing -> mcpOp/read", () {
          final name = "mcp__server__${verb}_thing";
          final c = classifySkcodeEvent(
            _ev(type: "tool_call", text: name, data: {"id": "t1", "name": name}),
          );
          expect(c.renderClass, ActivityRenderClass.mcpOp);
          expect(c.tone, ActivityTone.read, reason: name);
        });
      }

      for (final verb in const ["kms", "fortress", "trustee", "rotate"]) {
        test("mcp__server__${verb}_thing -> mcpOp/admin", () {
          final name = "mcp__server__${verb}_thing";
          final c = classifySkcodeEvent(
            _ev(type: "tool_call", text: name, data: {"id": "t1", "name": name}),
          );
          expect(c.renderClass, ActivityRenderClass.mcpOp);
          expect(c.tone, ActivityTone.admin, reason: name);
        });
      }

      test("mcp__server__publish_release -> mcpOp/write (fallthrough)", () {
        const name = "mcp__server__publish_release";
        final c = classifySkcodeEvent(
          _ev(type: "tool_call", text: name, data: {"id": "t1", "name": name}),
        );
        expect(c.renderClass, ActivityRenderClass.mcpOp);
        expect(c.tone, ActivityTone.write);
      });
    });

    test("tool_call with an unknown tool -> generic/neutral, labelled 'Ran tool'", () {
      final c = classifySkcodeEvent(
        _ev(type: "tool_call", text: "SomeFutureTool", data: {"id": "t1", "name": "SomeFutureTool"}),
      );
      expect(c.renderClass, ActivityRenderClass.generic);
      expect(c.tone, ActivityTone.neutral);
      expect(c.status, ToolStatus.executing);
      expect(c.label, "Ran tool");
    });

    test("tool_result with is_error -> failed status, raw/neutral in isolation", () {
      final c = classifySkcodeEvent(
        _ev(type: "tool_result", data: {"tool_use_id": "t1", "is_error": true}),
      );
      expect(c.renderClass, ActivityRenderClass.raw);
      expect(c.tone, ActivityTone.neutral);
      expect(c.status, ToolStatus.failed);
    });

    test("tool_result without is_error -> completed status, raw/neutral in isolation", () {
      final c = classifySkcodeEvent(
        _ev(type: "tool_result", data: {"tool_use_id": "t1", "is_error": false}),
      );
      expect(c.renderClass, ActivityRenderClass.raw);
      expect(c.tone, ActivityTone.neutral);
      expect(c.status, ToolStatus.completed);
    });

    test("harness heartbeat noise -> suppressed/neutral", () {
      final c = classifySkcodeEvent(
        _ev(type: "status", data: {"subtype": "heartbeat"}),
      );
      expect(c.renderClass, ActivityRenderClass.suppressed);
      expect(c.tone, ActivityTone.neutral);
    });

    test("a bare data.heartbeat flag also suppresses, on any event type", () {
      final c = classifySkcodeEvent(
        _ev(type: "assistant_text", data: {"heartbeat": true}),
      );
      expect(c.renderClass, ActivityRenderClass.suppressed);
    });

    test("an unrecognized event type falls back to generic/neutral", () {
      final c = classifySkcodeEvent(_ev(type: "some_future_event"));
      expect(c.renderClass, ActivityRenderClass.generic);
      expect(c.tone, ActivityTone.neutral);
      expect(c.label, isNull);
    });
  });

  group("buildSkcodeTranscript: tool_call/tool_result folding + suppressed drop", () {
    test(
      "tool_result is_error overrides the open tool_call to error and the tone is preserved",
      () {
        final events = [
          _ev(
            type: "tool_call",
            seq: 1,
            data: {"id": "call-1", "name": "Edit"},
          ),
          _ev(
            type: "tool_result",
            seq: 2,
            data: {"tool_use_id": "call-1", "is_error": true},
          ),
        ];

        final records = buildSkcodeTranscript(events);

        expect(records, hasLength(1), reason: "the result folds into the call's row");
        expect(records.single.renderClass, ActivityRenderClass.error);
        expect(
          records.single.tone,
          ActivityTone.write,
          reason: "Edit's write tone must survive the error override",
        );
        expect(records.single.status, ToolStatus.failed);
      },
    );

    test("tool_result without is_error closes the call to completed, class unchanged", () {
      final events = [
        _ev(type: "tool_call", seq: 1, data: {"id": "call-1", "name": "Read"}),
        _ev(type: "tool_result", seq: 2, data: {"tool_use_id": "call-1", "is_error": false}),
      ];

      final records = buildSkcodeTranscript(events);

      expect(records, hasLength(1));
      expect(records.single.renderClass, ActivityRenderClass.fileRead);
      expect(records.single.tone, ActivityTone.read);
      expect(records.single.status, ToolStatus.completed);
    });

    test("a tool_call with no matching tool_result stays executing", () {
      final events = [
        _ev(type: "tool_call", seq: 1, data: {"id": "call-1", "name": "Bash"}),
      ];
      final records = buildSkcodeTranscript(events);
      expect(records.single.status, ToolStatus.executing);
    });

    test("suppressed events are hidden from the transcript", () {
      final events = [
        _ev(type: "assistant_text", seq: 1, text: "hello"),
        _ev(type: "status", seq: 2, data: {"subtype": "heartbeat"}),
        _ev(type: "assistant_text", seq: 3, text: "world"),
      ];
      final records = buildSkcodeTranscript(events);
      expect(records, hasLength(2));
      expect(records.map((r) => r.event.text), ["hello", "world"]);
    });

    test("raw rail rows share the sid:seq:ts anchor id with transcript rows", () {
      final call = _ev(type: "tool_call", seq: 7, ts: 42.5, data: {"id": "call-1", "name": "Bash"});
      final records = buildSkcodeTranscript([call]);
      expect(records.single.rowId, skcodeEventRowId(call));
    });

    test("a tool_result with no matching open call is dropped, not added as its own row", () {
      final events = [
        _ev(type: "tool_result", seq: 1, data: {"tool_use_id": "orphan", "is_error": false}),
      ];
      expect(buildSkcodeTranscript(events), isEmpty);
    });
  });

  group("suppressed events still appear in the raw rail's classification path", () {
    test(
      "classifySkcodeEvent still returns a full classification for a suppressed event "
      "(the raw rail classifies every event independently, unlike the transcript reducer "
      "which drops them)",
      () {
        final heartbeat = _ev(type: "status", seq: 5, data: {"subtype": "heartbeat"});
        final c = classifySkcodeEvent(heartbeat);
        expect(c.renderClass, ActivityRenderClass.suppressed);
        // The raw rail widget renders every event in [events] directly (see
        // SkcodeRawRail), never filtering on renderClass; this assertion
        // documents that classifySkcodeEvent itself never throws or omits a
        // row for a suppressed event, it only marks it as such.
      },
    );
  });
}
