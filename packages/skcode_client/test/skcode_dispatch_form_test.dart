import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

/// A [SkcodeApiClient] test double whose ENTIRE surface for this file is
/// [fetchDispatchTargets] and [dispatch]: every other route throws
/// [UnimplementedError], matching the "not exercised by this file's tests"
/// convention every other fake in this package already uses.
class _FakeApiClient implements SkcodeApiClient {
  _FakeApiClient({this.targetsResponse, this.targetsError, this.dispatchResult, this.dispatchError});

  /// [fetchDispatchTargets] resolves with this when [targetsError] is null.
  final SkcodeDispatchTargets? targetsResponse;

  /// When set, [fetchDispatchTargets] throws this instead (the "endpoint
  /// unavailable" degrade-state seam).
  final Object? targetsError;

  /// [dispatch] resolves with this when [dispatchError] is null.
  final SkcodeDispatchResult? dispatchResult;

  /// When set, [dispatch] throws this instead (the "rejection" degrade
  /// states: 403 forbidden, 400 spawn-rejected, etc.).
  final Object? dispatchError;

  int targetsCalls = 0;
  final List<({String repo, String branch, String profile, String permissionMode, String mode,
      String prompt, String harness, String model})> dispatchCalls = [];

  @override
  Future<SkcodeDispatchTargets> fetchDispatchTargets({required String token}) async {
    targetsCalls++;
    final err = targetsError;
    if (err != null) throw err;
    return targetsResponse ?? const SkcodeDispatchTargets();
  }

  @override
  Future<SkcodeDispatchResult> dispatch({
    required String repo,
    required String branch,
    required String profile,
    required String permissionMode,
    required String mode,
    required String prompt,
    required String harness,
    required String model,
    required String token,
  }) async {
    dispatchCalls.add((
      repo: repo,
      branch: branch,
      profile: profile,
      permissionMode: permissionMode,
      mode: mode,
      prompt: prompt,
      harness: harness,
      model: model,
    ));
    final err = dispatchError;
    if (err != null) throw err;
    return dispatchResult ??
        const SkcodeDispatchResult(
          sid: "sandbox-deadbeef",
          status: "running",
          branch: "skcode/deadbeef",
          profile: "sandbox",
          mode: "interactive",
        );
  }

  @override
  Future<List<SkcodeSessionSummary>> listSessions({required String token}) async {
    throw UnimplementedError("not exercised by dispatch form tests");
  }

  @override
  Future<List<SkcodeEvent>> fetchEventsPage(
    String sid, {
    required String token,
    int? beforeSeq,
    int limit = 100,
  }) async {
    throw UnimplementedError("not exercised by dispatch form tests");
  }

  @override
  Future<List<SkcodeJobRun>> listJobs({required String token}) async {
    throw UnimplementedError("not exercised by dispatch form tests");
  }

  @override
  Future<void> injectText(String sid, String text, {required String token}) async {
    throw UnimplementedError("not exercised by dispatch form tests");
  }

  @override
  Future<void> ratifySession(String sid, {required String token}) async {
    throw UnimplementedError("not exercised by dispatch form tests");
  }

  @override
  Future<SkcodeCancelResult> cancelSession(String sid, {required String token}) async {
    throw UnimplementedError("not exercised by dispatch form tests");
  }
}

/// Pulls the exact rendered option values off a repo/harness/profile/model
/// dropdown. [DropdownButtonFormField] itself does not expose its `items`
/// list as a field (the constructor parameter is captured by an internal
/// builder closure, never stored on `this`); it builds a real
/// [DropdownButton] underneath via `DropdownButton._formField(...)`, which
/// DOES store `items`, so this reads that descendant directly -- more
/// reliable than opening the overlay menu and counting `find.text` hits,
/// which double-counts a value that is also the current selection.
List<String?> _dropdownValues(WidgetTester tester, String key) {
  final button = tester.widget<DropdownButton<String>>(
    find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(DropdownButton<String>),
    ),
  );
  return button.items?.map((item) => item.value).toList() ?? const [];
}

Widget _harness(SkcodeApiClient apiClient, {void Function(SkcodeDispatchResult)? onDispatched}) {
  return MaterialApp(
    home: Scaffold(
      body: SkcodeDispatchForm(
        apiClient: apiClient,
        mintToken: () async => "T",
        onDispatched: onDispatched ?? (_) {},
      ),
    ),
  );
}

void main() {
  group("no dispatch option is ever hardcoded (card C-6 non-negotiable)", () {
    testWidgets(
        "renders EXACTLY the repo/harness/profile/model options one targets response sent",
        (tester) async {
      final apiClient = _FakeApiClient(
        targetsResponse: const SkcodeDispatchTargets(
          repos: ["/repos/skworld-app", "/repos/skchat"],
          harnesses: ["claude-code"],
          profiles: ["sandbox", "full"],
          models: ["ornith-big"],
        ),
      );

      await tester.pumpWidget(_harness(apiClient));
      await tester.pump();

      expect(_dropdownValues(tester, "skcodeDispatchRepo"),
          ["/repos/skworld-app", "/repos/skchat"]);
      expect(_dropdownValues(tester, "skcodeDispatchHarness"), ["claude-code"]);
      expect(_dropdownValues(tester, "skcodeDispatchProfile"), ["sandbox", "full"]);
      expect(_dropdownValues(tester, "skcodeDispatchModel"), ["ornith-big"]);

      // None of the legacy web client's HARDCODED model options
      // (skharness/src/skharness/client/index.html's <select id="model">)
      // appear anywhere: this form must never fall back to that catalog.
      expect(find.text("sk-default"), findsNothing);
      expect(find.text("claude-sonnet-5"), findsNothing);
      expect(find.text("claude-opus-4-8"), findsNothing);
    });

    testWidgets(
        "an ALTERED targets response changes exactly what is offered, proving the form is "
        "driven by the response and not a fixed catalog", (tester) async {
      final apiClient = _FakeApiClient(
        targetsResponse: const SkcodeDispatchTargets(
          repos: ["/repos/only-one-repo-here"],
          harnesses: ["some-other-harness"],
          profiles: ["experimental-profile"],
          models: ["some-fresh-model-id"],
        ),
      );

      await tester.pumpWidget(_harness(apiClient));
      await tester.pump();

      expect(_dropdownValues(tester, "skcodeDispatchRepo"), ["/repos/only-one-repo-here"]);
      expect(_dropdownValues(tester, "skcodeDispatchHarness"), ["some-other-harness"]);
      expect(_dropdownValues(tester, "skcodeDispatchProfile"), ["experimental-profile"]);
      expect(_dropdownValues(tester, "skcodeDispatchModel"), ["some-fresh-model-id"]);

      // The FIRST test's values are gone: this is not a superset/union of
      // two catalogs, it is exactly the one response this pump received.
      expect(find.text("/repos/skworld-app"), findsNothing);
      expect(find.text("claude-code"), findsNothing);
      expect(find.text("ornith-big"), findsNothing);
    });

    testWidgets("submit posts exactly the selected server-provided values, nothing invented",
        (tester) async {
      final apiClient = _FakeApiClient(
        targetsResponse: const SkcodeDispatchTargets(
          repos: ["/repos/skworld-app"],
          harnesses: ["claude-code"],
          profiles: ["sandbox"],
          models: ["ornith-big"],
        ),
        dispatchResult: const SkcodeDispatchResult(
          sid: "sandbox-deadbeef",
          status: "running",
          branch: "skcode/deadbeef",
          profile: "sandbox",
          mode: "interactive",
        ),
      );
      SkcodeDispatchResult? dispatched;

      await tester.pumpWidget(_harness(apiClient, onDispatched: (r) => dispatched = r));
      await tester.pump();

      await tester.enterText(find.byKey(const Key("skcodeDispatchPrompt")), "fix the bug");
      await tester.pump();
      // The form is a SingleChildScrollView taller than the test viewport;
      // the submit button sits below the fold, so it must be scrolled into
      // view before a tap can hit-test it.
      await tester.ensureVisible(find.byKey(const Key("skcodeDispatchSubmit")));
      await tester.tap(find.byKey(const Key("skcodeDispatchSubmit")));
      await tester.pumpAndSettle();

      expect(apiClient.dispatchCalls, hasLength(1));
      final call = apiClient.dispatchCalls.single;
      expect(call.repo, "/repos/skworld-app");
      expect(call.harness, "claude-code");
      expect(call.profile, "sandbox");
      expect(call.model, "ornith-big");
      expect(call.prompt, "fix the bug");
      expect(dispatched?.sid, "sandbox-deadbeef");
    });
  });

  group("direct (repo-less) session (card C-16: iframe parity gap)", () {
    testWidgets(
        "checking Direct session dispatches with repo empty, NOT the dropdown's "
        "auto-selected value -- no silent default is substituted", (tester) async {
      final apiClient = _FakeApiClient(
        targetsResponse: const SkcodeDispatchTargets(
          repos: ["/repos/skworld-app", "/repos/skchat"],
          harnesses: ["claude-code"],
          profiles: ["sandbox"],
          models: ["ornith-big"],
        ),
      );

      await tester.pumpWidget(_harness(apiClient));
      await tester.pump();

      // Sanity: the repo dropdown auto-selected the first server-provided
      // repo, exactly like the existing hardcoding-proof test asserts. The
      // point of this test is that checking the box below overrides that
      // selection at submit time rather than sending it anyway.
      expect(
        tester.widget<DropdownButtonFormField<String>>(
          find.byKey(const Key("skcodeDispatchRepo")),
        ).initialValue,
        "/repos/skworld-app",
      );

      await tester.tap(find.byKey(const Key("skcodeDispatchDirectSession")));
      await tester.pump();
      await tester.enterText(find.byKey(const Key("skcodeDispatchPrompt")), "start fresh");
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key("skcodeDispatchSubmit")));
      await tester.tap(find.byKey(const Key("skcodeDispatchSubmit")));
      await tester.pumpAndSettle();

      expect(apiClient.dispatchCalls, hasLength(1));
      final call = apiClient.dispatchCalls.single;
      expect(call.repo, "", reason: "checking the box must send repo empty, never the "
          "dropdown's leftover auto-selected value");
      // Everything else the operator picked still rides along unchanged --
      // this is not a "wipe the form" toggle, only repo is overridden.
      expect(call.harness, "claude-code");
      expect(call.profile, "sandbox");
      expect(call.model, "ornith-big");
      expect(call.prompt, "start fresh");
    });

    testWidgets(
        "a host with zero advertised repos can still dispatch a direct session -- the "
        "server accepts a repo-less dispatch regardless of what /dispatch/targets offered",
        (tester) async {
      final apiClient = _FakeApiClient(
        targetsResponse: const SkcodeDispatchTargets(
          repos: [],
          harnesses: ["claude-code"],
          profiles: ["sandbox"],
        ),
      );

      await tester.pumpWidget(_harness(apiClient));
      await tester.pump();

      // Same degrade state as before: no dropdown, no options to pick from.
      expect(find.byKey(const Key("skcodeDispatchRepoEmpty")), findsOneWidget);
      expect(find.byKey(const Key("skcodeDispatchRepo")), findsNothing);

      await tester.enterText(find.byKey(const Key("skcodeDispatchPrompt")), "anything");
      await tester.pump();

      // Still disabled with the box unchecked -- unchanged from before.
      var submit = tester.widget<FilledButton>(find.byKey(const Key("skcodeDispatchSubmit")));
      expect(submit.onPressed, isNull);

      await tester.tap(find.byKey(const Key("skcodeDispatchDirectSession")));
      await tester.pump();

      submit = tester.widget<FilledButton>(find.byKey(const Key("skcodeDispatchSubmit")));
      expect(submit.onPressed, isNotNull);

      await tester.ensureVisible(find.byKey(const Key("skcodeDispatchSubmit")));
      await tester.tap(find.byKey(const Key("skcodeDispatchSubmit")));
      await tester.pumpAndSettle();

      expect(apiClient.dispatchCalls, hasLength(1));
      expect(apiClient.dispatchCalls.single.repo, "");
    });

    testWidgets(
        "unchecking Direct session after checking it restores the repo requirement",
        (tester) async {
      final apiClient = _FakeApiClient(
        targetsResponse: const SkcodeDispatchTargets(
          repos: [],
          harnesses: ["claude-code"],
          profiles: ["sandbox"],
        ),
      );

      await tester.pumpWidget(_harness(apiClient));
      await tester.pump();
      await tester.enterText(find.byKey(const Key("skcodeDispatchPrompt")), "anything");
      await tester.pump();

      await tester.tap(find.byKey(const Key("skcodeDispatchDirectSession")));
      await tester.pump();
      await tester.tap(find.byKey(const Key("skcodeDispatchDirectSession")));
      await tester.pump();

      final submit = tester.widget<FilledButton>(find.byKey(const Key("skcodeDispatchSubmit")));
      expect(submit.onPressed, isNull);
    });
  });

  group("degrade states (card C-6: never a crash or a silent no-op)", () {
    testWidgets("an empty targets response renders a clear empty state, not a crash",
        (tester) async {
      final apiClient = _FakeApiClient(targetsResponse: const SkcodeDispatchTargets());

      await tester.pumpWidget(_harness(apiClient));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key("skcodeDispatchTargetsEmpty")), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byKey(const Key("skcodeDispatchSubmit")), findsNothing);
    });

    testWidgets("targets endpoint unavailable renders a clear state with a retry, not a crash",
        (tester) async {
      final apiClient = _FakeApiClient(targetsError: const SkcodeApiException("boom"));

      await tester.pumpWidget(_harness(apiClient));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key("skcodeDispatchUnavailable")), findsOneWidget);
      expect(find.byKey(const Key("skcodeDispatchRetry")), findsOneWidget);
      expect(apiClient.targetsCalls, 1);

      await tester.tap(find.byKey(const Key("skcodeDispatchRetry")));
      await tester.pump();

      expect(apiClient.targetsCalls, 2);
    });

    testWidgets(
        "a repo-empty-but-otherwise-populated response disables submit and shows a "
        "per-field empty message instead of a dropdown with nothing in it", (tester) async {
      final apiClient = _FakeApiClient(
        targetsResponse: const SkcodeDispatchTargets(
          repos: [],
          harnesses: ["claude-code"],
          profiles: ["sandbox"],
          models: ["ornith-big"],
        ),
      );

      await tester.pumpWidget(_harness(apiClient));
      await tester.pump();

      expect(find.byKey(const Key("skcodeDispatchRepoEmpty")), findsOneWidget);
      expect(find.byKey(const Key("skcodeDispatchRepo")), findsNothing);

      await tester.enterText(find.byKey(const Key("skcodeDispatchPrompt")), "anything");
      await tester.pump();

      final submit = tester.widget<FilledButton>(find.byKey(const Key("skcodeDispatchSubmit")));
      expect(submit.onPressed, isNull); // disabled: no repo selectable at all.
    });

    testWidgets("a 403 dispatch rejection from the PDP is shown as its own clear state",
        (tester) async {
      final apiClient = _FakeApiClient(
        targetsResponse: const SkcodeDispatchTargets(
          repos: ["/repos/skworld-app"],
          harnesses: ["claude-code"],
          profiles: ["sandbox"],
        ),
        dispatchError: const SkcodeDispatchForbiddenException("insufficient enrollment mode"),
      );
      var dispatchedCount = 0;

      await tester.pumpWidget(_harness(apiClient, onDispatched: (_) => dispatchedCount++));
      await tester.pump();

      await tester.enterText(find.byKey(const Key("skcodeDispatchPrompt")), "do the thing");
      await tester.pump();
      // The form is a SingleChildScrollView taller than the test viewport;
      // the submit button sits below the fold, so it must be scrolled into
      // view before a tap can hit-test it.
      await tester.ensureVisible(find.byKey(const Key("skcodeDispatchSubmit")));
      await tester.tap(find.byKey(const Key("skcodeDispatchSubmit")));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(dispatchedCount, 0);
      expect(find.byKey(const Key("skcodeDispatchError")), findsOneWidget);
      expect(find.textContaining("Not authorized"), findsOneWidget);
      expect(find.textContaining("insufficient enrollment mode"), findsOneWidget);
    });
  });
}
