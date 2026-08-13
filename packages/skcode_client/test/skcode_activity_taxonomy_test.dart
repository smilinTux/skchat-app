import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

SkcodeEvent _ev({
  String type = "assistant_text",
  String text = "",
  Map<String, dynamic> data = const {},
  int seq = 1,
  double ts = 1000.0,
  String sid = "s-1",
  String source = "interactive",
}) =>
    SkcodeEvent(
      type: type,
      text: text,
      data: data,
      seq: seq,
      ts: ts,
      sid: sid,
      source: source,
    );

/// An attach-mode (capture-pane) `assistant_text` event, the only shape the
/// TUI chrome filter / redraw dedupe (card C-17) ever touches.
SkcodeEvent _attachEv({
  String text = "",
  int seq = 1,
  double ts = 1000.0,
  String sid = "s-1",
}) =>
    _ev(type: "assistant_text", text: text, seq: seq, ts: ts, sid: sid, source: "attach");

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

  group(
    "card C-17: attach-mode TUI chrome filter (ported from hostd's "
    "index.html isChromeLine, SKWorld's own logic, not Buzz)",
    () {
      test("a full-width box-drawing separator -> suppressed/neutral", () {
        final c = classifySkcodeEvent(_attachEv(text: "─" * 40));
        expect(c.renderClass, ActivityRenderClass.suppressed);
        expect(c.tone, ActivityTone.neutral);
      });

      test("a short run of box-drawing chars (< 8) is NOT stripped", () {
        // isChromeLine requires length >= 8 even when every glyph is
        // box-drawing, matching the iframe's boundary exactly.
        final c = classifySkcodeEvent(_attachEv(text: "─" * 7));
        expect(c.renderClass, ActivityRenderClass.message);
      });

      for (final phrase in const [
        "manual mode on (shift+tab to cycle)",
        "? for shortcuts",
        "esc to interrupt · ctrl+t for agents",
      ]) {
        test("status bar line containing '$phrase' -> suppressed/neutral", () {
          final c = classifySkcodeEvent(_attachEv(text: phrase));
          expect(c.renderClass, ActivityRenderClass.suppressed);
        });
      }

      test("the thinking-spinner line (leading U+273B) -> suppressed/neutral", () {
        final c = classifySkcodeEvent(_attachEv(text: "✻ Thinking..."));
        expect(c.renderClass, ActivityRenderClass.suppressed);
      });

      test("ordinary text on an attach session passes straight through", () {
        final c = classifySkcodeEvent(_attachEv(text: "❯ Fix the login bug"));
        expect(c.renderClass, ActivityRenderClass.message);
      });

      test("a blank line is never itself chrome (the dedupe below owns blanks)", () {
        final c = classifySkcodeEvent(_attachEv(text: "   "));
        expect(c.renderClass, ActivityRenderClass.message);
      });

      test(
        "the SAME chrome-shaped text on a non-attach source is never suppressed "
        "(the filter is scoped to source == attach, not to text shape alone)",
        () {
          final interactive =
              classifySkcodeEvent(_ev(type: "assistant_text", text: "─" * 40));
          final autocode = classifySkcodeEvent(
            _ev(type: "assistant_text", text: "─" * 40, source: "autocode"),
          );
          expect(interactive.renderClass, ActivityRenderClass.message);
          expect(autocode.renderClass, ActivityRenderClass.message);
        },
      );
    },
  );

  group(
    "card C-17: attach-mode terminal-redraw dedupe "
    "(classifySkcodeEventsInContext, ported from hostd's addEvent)",
    () {
      test("an exact duplicate of the line just rendered is suppressed", () {
        final events = [
          _attachEv(text: "same frame", seq: 1),
          _attachEv(text: "same frame", seq: 2),
        ];
        final cs = classifySkcodeEventsInContext(events);
        expect(cs[0].renderClass, ActivityRenderClass.message);
        expect(cs[1].renderClass, ActivityRenderClass.suppressed);
      });

      test("distinct consecutive lines are both kept", () {
        final events = [
          _attachEv(text: "line one", seq: 1),
          _attachEv(text: "line two", seq: 2),
        ];
        final cs = classifySkcodeEventsInContext(events);
        expect(cs[0].renderClass, ActivityRenderClass.message);
        expect(cs[1].renderClass, ActivityRenderClass.message);
      });

      test("a blank line following a blank line is suppressed (TUI padding)", () {
        final events = [
          _attachEv(text: "content", seq: 1),
          _attachEv(text: "", seq: 2),
          _attachEv(text: "   ", seq: 3),
        ];
        final cs = classifySkcodeEventsInContext(events);
        expect(cs[0].renderClass, ActivityRenderClass.message);
        expect(cs[1].renderClass, ActivityRenderClass.message, reason: "first blank stands");
        expect(cs[2].renderClass, ActivityRenderClass.suppressed, reason: "blank-after-blank");
      });

      test(
        "a leading blank line is suppressed too (the dedupe state starts "
        "empty, exactly like the client on stream-open)",
        () {
          final cs = classifySkcodeEventsInContext([_attachEv(text: "", seq: 1)]);
          expect(cs[0].renderClass, ActivityRenderClass.suppressed);
        },
      );

      test(
        "a blank between two non-blank lines does not carry the dedupe "
        "state across it: a later blank is judged against the line "
        "immediately before it, not the whole history",
        () {
          final events = [
            _attachEv(text: "", seq: 1), // leading blank, suppressed
            _attachEv(text: "hello", seq: 2), // kept, becomes lastAttachText
            _attachEv(text: "", seq: 3), // NOT a redraw: previous kept line was non-blank
          ];
          final cs = classifySkcodeEventsInContext(events);
          expect(cs[0].renderClass, ActivityRenderClass.suppressed);
          expect(cs[1].renderClass, ActivityRenderClass.message);
          expect(cs[2].renderClass, ActivityRenderClass.message);
        },
      );

      test(
        "a chrome line between two identical lines never updates the dedupe "
        "state, so the second real line still reads as a redraw of the "
        "first (matches the iframe: chrome lines never touch _lastRenderedText)",
        () {
          final events = [
            _attachEv(text: "hello", seq: 1),
            _attachEv(text: "─" * 40, seq: 2), // chrome, filtered first
            _attachEv(text: "hello", seq: 3),
          ];
          final cs = classifySkcodeEventsInContext(events);
          expect(cs[0].renderClass, ActivityRenderClass.message);
          expect(cs[1].renderClass, ActivityRenderClass.suppressed, reason: "chrome line");
          expect(
            cs[2].renderClass,
            ActivityRenderClass.suppressed,
            reason: "redraw of the last REAL rendered line",
          );
        },
      );

      test("dedupe never applies on a non-attach source", () {
        final events = [
          _ev(type: "assistant_text", text: "same", seq: 1),
          _ev(type: "assistant_text", text: "same", seq: 2),
        ];
        final cs = classifySkcodeEventsInContext(events);
        expect(cs[0].renderClass, ActivityRenderClass.message);
        expect(cs[1].renderClass, ActivityRenderClass.message);
      });

      test(
        "classifySkcodeEventsInContext is positionally aligned 1:1 with its "
        "input and never drops or reorders an entry",
        () {
          final events = [
            _attachEv(text: "a", seq: 1),
            _ev(type: "status", data: {"subtype": "heartbeat"}, seq: 2),
            _attachEv(text: "a", seq: 3),
          ];
          final cs = classifySkcodeEventsInContext(events);
          expect(cs.length, events.length);
        },
      );
    },
  );

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

    test(
      "card C-17: attach-mode TUI chrome and terminal redraws are hidden from "
      "the transcript, exactly like heartbeat noise",
      () {
        final events = [
          _attachEv(text: "❯ fix the login bug", seq: 1),
          _attachEv(text: "─" * 40, seq: 2), // box-drawing separator: chrome
          _attachEv(text: "manual mode on (shift+tab to cycle)", seq: 3), // status bar: chrome
          _attachEv(text: "✻ Thinking...", seq: 4), // spinner: chrome
          _attachEv(text: "● Done editing the file.", seq: 5),
          _attachEv(text: "● Done editing the file.", seq: 6), // redraw of row 5
        ];
        final records = buildSkcodeTranscript(events);
        expect(records, hasLength(2));
        expect(
          records.map((r) => r.event.text),
          ["❯ fix the login bug", "● Done editing the file."],
        );
      },
    );
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
