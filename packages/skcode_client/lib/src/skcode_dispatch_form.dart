import "dart:async";

import "package:flutter/material.dart";
import "package:skworld_module_api/skworld_module_api.dart";

import "skcode_api_client.dart";
import "skcode_config.dart";
import "skcode_dispatch_targets.dart";

/// The New Session form (card C-6, spec sections 3.1 and 8's "New run" row):
/// `GET /dispatch/targets` fed, `POST /dispatch` submitting.
///
/// FIELD PROVENANCE, spelled out because it is the whole point of this
/// card: [repo], [harness], [profile] and [model] are each rendered as a
/// dropdown whose ENTIRE item list is [SkcodeDispatchTargets]'s own list of
/// the same name -- nothing here ever adds, removes, or substitutes an
/// option (see `test/skcode_dispatch_form_test.dart`, which proves this by
/// feeding two different targets responses and asserting the rendered
/// options change to match, exactly, every time). [branch] is free text: it
/// is not part of the targets response at all (a base branch is chosen per
/// dispatch, not enumerated by the host), so a text field is the honest
/// shape for it, never a fixed list. [mode] and [permissionMode] are the
/// two two-valued PROTOCOL fields `daemon.py::dispatch_route` itself
/// validates (`mode in ("direct", "interactive")`, 400 otherwise;
/// `permission_mode` is `harness.py`'s own `"manual" | "auto"` vocabulary):
/// these are part of the wire contract, not advisory targets, so they are
/// the one place this form is allowed to enumerate options itself -- card
/// C-6's "never hardcode a model, repo, branch, profile, or harness value"
/// does not name them, precisely because they are not targets-sourced
/// values.
///
/// Renders one of four states: loading (the first `fetchDispatchTargets`
/// call in flight), unavailable (the call failed -- no token, network, or
/// transport error), empty (the call succeeded but every list in the
/// response was empty: nothing this host will let this device dispatch),
/// or the real form. Each is an explicit, honest render, matching the
/// pattern `SkcodeSessionsRail`'s own Jobs section already established for
/// "endpoint unavailable" vs "empty" vs "populated".
///
/// DIRECT (REPO-LESS) SESSIONS (card C-16): `daemon.py::dispatch_route`
/// reads `repo`/`branch`/`model` with `str(body.get(..., "") or "")` --
/// every one of them is genuinely optional on the wire, and the old
/// iframe's default entry point dispatches with none of them set at all
/// (`SkcodeApiClient.dispatch`'s own doc comment). Before this card,
/// [_canSubmit] required `_repo != null`, which made that repo-less path
/// impossible here even though the server has always accepted it -- the
/// fastest way to start a session in the client being replaced had no
/// equivalent in the replacement. The [_directSession] checkbox is the
/// fix: it is a SEPARATE control from the repo dropdown, not a value
/// folded into it, specifically so `test/skcode_dispatch_form_test.dart`'s
/// non-hardcoding proof (which asserts the repo dropdown's item list is
/// EXACTLY what one targets response sent, nothing added) keeps holding.
/// Checking it does not invent a repo -- it does the opposite: it makes
/// [_submit] send `repo: ""` regardless of whatever the dropdown had
/// auto-selected, so ticking the box always means "no repo", never "the
/// repo I happened to have selected".
class SkcodeDispatchForm extends StatefulWidget {
  const SkcodeDispatchForm({
    super.key,
    required this.apiClient,
    required this.mintToken,
    required this.onDispatched,
  });

  final SkcodeApiClient apiClient;
  final Future<String?> Function() mintToken;

  /// Called with the server's own response after a successful
  /// `POST /dispatch`. This widget never navigates or shows a toast itself
  /// (matching every other transport-touching widget in this package): the
  /// caller (`SkcodeDispatchScreen`) decides what "started" means for the
  /// screen it owns.
  final void Function(SkcodeDispatchResult result) onDispatched;

  @override
  State<SkcodeDispatchForm> createState() => _SkcodeDispatchFormState();
}

enum _TargetsPhase { loading, unavailable, ready }

class _SkcodeDispatchFormState extends State<SkcodeDispatchForm> {
  _TargetsPhase _phase = _TargetsPhase.loading;
  SkcodeDispatchTargets _targets = const SkcodeDispatchTargets();

  String? _repo;
  String? _harness;
  String? _profile;
  String? _model;

  /// True when the operator explicitly chose "Direct session (no repo)"
  /// (card C-16). Overrides [_repo] entirely at submit time -- see this
  /// class's own doc comment for why that must be a separate flag rather
  /// than a value stuffed into the repo dropdown itself.
  bool _directSession = false;
  String _branch = "";
  String _mode = "interactive";
  String _permissionMode = "manual";
  final _promptController = TextEditingController();

  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTargets());
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _loadTargets() async {
    setState(() => _phase = _TargetsPhase.loading);
    final token = await widget.mintToken();
    if (!mounted) return;
    if (token == null) {
      // Tokenless: same fail-closed degrade `SkcodeSessionsListStore`/
      // `SkcodeJobsListStore` already use, rendered here as "unavailable"
      // rather than a crash or a silently empty form.
      setState(() => _phase = _TargetsPhase.unavailable);
      return;
    }
    try {
      final targets = await widget.apiClient.fetchDispatchTargets(token: token);
      if (!mounted) return;
      setState(() {
        _targets = targets;
        _phase = _TargetsPhase.ready;
        // Auto-select the server's first option per field, when it offered
        // one -- still exactly a server-provided value, never invented.
        _repo = targets.repos.isNotEmpty ? targets.repos.first : null;
        _harness = targets.harnesses.isNotEmpty ? targets.harnesses.first : null;
        _profile = targets.profiles.isNotEmpty ? targets.profiles.first : null;
        _model = targets.models.isNotEmpty ? targets.models.first : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _TargetsPhase.unavailable);
    }
  }

  bool get _canSubmit =>
      !_submitting &&
      (_directSession || _repo != null) &&
      _harness != null &&
      _profile != null &&
      _promptController.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final token = await widget.mintToken();
    if (!mounted) return;
    if (token == null) {
      setState(() {
        _submitting = false;
        _submitError = "Not authenticated.";
      });
      return;
    }
    try {
      final result = await widget.apiClient.dispatch(
        // [_directSession] wins outright: even if the repo dropdown carries
        // an auto-selected value from [_loadTargets], checking the box
        // means "no repo" and this must send exactly "", never that
        // leftover selection (card C-16: never a silent default).
        repo: _directSession ? "" : (_repo ?? ""),
        branch: _branch.trim(),
        profile: _profile ?? "",
        permissionMode: _permissionMode,
        mode: _mode,
        prompt: _promptController.text.trim(),
        harness: _harness ?? "",
        model: _model ?? "",
        token: token,
      );
      if (!mounted) return;
      setState(() => _submitting = false);
      widget.onDispatched(result);
    } on SkcodeDispatchForbiddenException catch (e) {
      // The clear "PDP denied" state card C-6 requires: distinct from a
      // generic network failure below.
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = "Not authorized: ${e.message}";
      });
    } on SkcodeUnauthorizedException {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = "Not authenticated.";
      });
    } on SkcodeApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _TargetsPhase.loading:
        return const Center(
          key: Key("skcodeDispatchLoading"),
          child: CircularProgressIndicator(),
        );
      case _TargetsPhase.unavailable:
        return Center(
          key: const Key("skcodeDispatchUnavailable"),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Dispatch targets unavailable.",
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const Key("skcodeDispatchRetry"),
                  onPressed: () => unawaited(_loadTargets()),
                  child: const Text("Retry"),
                ),
              ],
            ),
          ),
        );
      case _TargetsPhase.ready:
        if (_targets.isEmpty) {
          return Center(
            key: const Key("skcodeDispatchTargetsEmpty"),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                "No dispatch targets available on this host.",
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return _buildForm(context);
    }
  }

  Widget _buildForm(BuildContext context) {
    return SingleChildScrollView(
      key: const Key("skcodeDispatchForm"),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Card C-16: the server accepts a fully repo-less dispatch
          // (`daemon.py::dispatch_route`, doc comment on
          // `SkcodeApiClient.dispatch`) -- this is the honest "no repo" UI
          // for it, separate from the dropdown below so checking it can
          // never be confused with a value the dropdown offered.
          CheckboxListTile(
            key: const Key("skcodeDispatchDirectSession"),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            value: _directSession,
            title: const Text("Direct session (no repo)"),
            subtitle: Text(
              "Skip repo selection, same as the server's own optional repo field.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onChanged: (v) => setState(() => _directSession = v ?? false),
          ),
          const SizedBox(height: 4),
          IgnorePointer(
            ignoring: _directSession,
            child: Opacity(
              opacity: _directSession ? 0.5 : 1.0,
              child: _targetsField(
                key: "skcodeDispatchRepo",
                label: "Repo",
                emptyText: "No repos available for dispatch.",
                options: _targets.repos,
                value: _repo,
                onChanged: (v) => setState(() => _repo = v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key("skcodeDispatchBranch"),
            decoration: const InputDecoration(labelText: "Base branch", hintText: "main"),
            onChanged: (v) => _branch = v,
          ),
          const SizedBox(height: 12),
          _targetsField(
            key: "skcodeDispatchProfile",
            label: "Profile",
            emptyText: "No profiles available for dispatch.",
            options: _targets.profiles,
            value: _profile,
            onChanged: (v) => setState(() => _profile = v),
          ),
          const SizedBox(height: 12),
          _targetsField(
            key: "skcodeDispatchHarness",
            label: "Harness",
            emptyText: "No harnesses available for dispatch.",
            options: _targets.harnesses,
            value: _harness,
            onChanged: (v) => setState(() => _harness = v),
          ),
          const SizedBox(height: 12),
          _targetsField(
            key: "skcodeDispatchModel",
            label: "Model",
            emptyText: "No models advertised by this host.",
            options: _targets.models,
            value: _model,
            onChanged: (v) => setState(() => _model = v),
          ),
          const SizedBox(height: 12),
          // Protocol-level fields, not targets-sourced (see this class's own
          // doc comment): the two-value vocabulary itself comes from
          // `daemon.py::dispatch_route`'s own validation, not from a
          // targets list.
          DropdownButtonFormField<String>(
            key: const Key("skcodeDispatchMode"),
            initialValue: _mode,
            decoration: const InputDecoration(labelText: "Session mode"),
            items: const [
              DropdownMenuItem(value: "interactive", child: Text("interactive (stays open)")),
              DropdownMenuItem(value: "direct", child: Text("direct (one-shot)")),
            ],
            onChanged: (v) => setState(() => _mode = v ?? "interactive"),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key("skcodeDispatchPermissionMode"),
            initialValue: _permissionMode,
            decoration: const InputDecoration(labelText: "Permission mode"),
            items: const [
              DropdownMenuItem(value: "manual", child: Text("manual (approve each action)")),
              DropdownMenuItem(value: "auto", child: Text("auto")),
            ],
            onChanged: (v) => setState(() => _permissionMode = v ?? "manual"),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key("skcodeDispatchPrompt"),
            controller: _promptController,
            decoration: const InputDecoration(
              labelText: "Prompt",
              alignLabelWithHint: true,
            ),
            minLines: 3,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          if (_submitError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _submitError!,
                key: const Key("skcodeDispatchError"),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton(
            key: const Key("skcodeDispatchSubmit"),
            onPressed: _canSubmit ? _submit : null,
            child: Text(_submitting ? "Starting..." : "Start session"),
          ),
        ],
      ),
    );
  }

  /// One repo/profile/harness/model dropdown: [options] is rendered
  /// VERBATIM as the item list (this is the entire non-hardcoding proof
  /// surface -- see this class's own doc comment), or, when [options] is
  /// empty, an explicit "no X available" line in place of a dropdown with
  /// nothing to select (never a dropdown silently offering zero items).
  Widget _targetsField({
    required String key,
    required String label,
    required String emptyText,
    required List<String> options,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    if (options.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          emptyText,
          key: Key("${key}Empty"),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return DropdownButtonFormField<String>(
      key: Key(key),
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
      onChanged: onChanged,
    );
  }
}

/// The New Session screen (card C-6, spec section 8's "New run" row):
/// pushed by [SkcodeSessionsRail]'s New Session entry point.
///
/// Re-checks [kSkcodeDispatchScope] itself rather than trusting that only a
/// scope-gated caller can ever reach it (defense in depth beyond the rail's
/// own gate on whether to show the entry point at all): a null [auth] or a
/// token missing the scope renders NEITHER the loading state NOR the form,
/// just the same fail-closed empty state `SkcodeSessionScreen`'s
/// `_hasInjectScope` establishes for card C-5.
class SkcodeDispatchScreen extends StatelessWidget {
  const SkcodeDispatchScreen({
    super.key,
    required this.apiClient,
    required this.mintToken,
    this.auth,
  });

  final SkcodeApiClient apiClient;
  final Future<String?> Function() mintToken;

  /// The mounted module's audience-scoped [AuthContext]
  /// (`skworld_module_api`), forwarded from `SkcodeSessionsRail`. Null in
  /// standalone mode before a real login seam exists, which correctly means
  /// [_hasDispatchScope] reads false: no [AuthContext], no provable
  /// `skcode.dispatch` scope, no dispatch form (fail closed).
  final AuthContext? auth;

  bool get _hasDispatchScope => auth?.hasScope(kSkcodeDispatchScope) ?? false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("New session")),
      body: _hasDispatchScope
          ? SkcodeDispatchForm(
              apiClient: apiClient,
              mintToken: mintToken,
              onDispatched: (result) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      result.sid.isEmpty
                          ? "Session started."
                          : "Started ${result.sid}"
                              "${result.branch.isEmpty ? '' : ' on ${result.branch}'}.",
                    ),
                  ),
                );
                Navigator.of(context).pop();
              },
            )
          : Center(
              key: const Key("skcodeDispatchNoScope"),
              child: Text(
                "You do not have permission to start sessions.",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
    );
  }
}
