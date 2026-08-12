/// Wire shapes for the DISPATCH surface (spec 3.1, spec section 8's "New
/// run" row, card C-6): `GET /skcode/api/v1/dispatch/targets`,
/// `POST /skcode/api/v1/dispatch`, and `POST /skcode/api/v1/sessions/{sid}/cancel`.
///
/// [SkcodeDispatchTargets] is the load-bearing type in this file. Every list
/// it exposes is read directly off whatever JSON the server sent for THIS
/// call -- there is no non-empty fallback anywhere below. A missing or
/// wrong-typed key degrades to an empty list, never a made-up value. That is
/// what makes it possible to prove nothing in the New Session form is
/// hardcoded (`test/skcode_dispatch_form_test.dart`): feed this parser an
/// empty or an altered JSON blob and the lists it produces change to match,
/// exactly, every time.
///
/// `repos` / `harnesses` / `profiles` are the base keys
/// `skharness/src/skharness/daemon.py::dispatch_targets_route` always sends.
/// `models` is read the same defensive way for the skgateway-backed model
/// list spec section 8 calls for ("model list via skgateway-backed targets,
/// never hardcoded"), even though today's production
/// `serve.py::build_dispatch_targets()` does not populate it yet -- this
/// client never assumes a key exists, it only ever reads what showed up on
/// the wire.
class SkcodeDispatchTargets {
  const SkcodeDispatchTargets({
    this.repos = const [],
    this.harnesses = const [],
    this.profiles = const [],
    this.models = const [],
  });

  final List<String> repos;
  final List<String> harnesses;
  final List<String> profiles;
  final List<String> models;

  /// True when the server returned zero options for every list this form
  /// can offer a control from: the honest "nothing to dispatch with" case
  /// (spec: "empty target lists ... need a clear state").
  bool get isEmpty =>
      repos.isEmpty && harnesses.isEmpty && profiles.isEmpty && models.isEmpty;

  factory SkcodeDispatchTargets.fromJson(Map<String, dynamic> json) {
    return SkcodeDispatchTargets(
      repos: _stringList(json["repos"]),
      harnesses: _stringList(json["harnesses"]),
      profiles: _stringList(json["profiles"]),
      models: _stringList(json["models"]),
    );
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<String>().toList(growable: false);
  }
}

/// `POST /skcode/api/v1/dispatch`'s 200 response body (spec 3.1): the
/// spawned session's id plus the server's own echo of what it actually did.
/// This class never guesses a value the response omitted; every field
/// blank/empty-defaults exactly like [SkcodeSessionSummary.fromJson] does.
class SkcodeDispatchResult {
  const SkcodeDispatchResult({
    required this.sid,
    required this.status,
    required this.branch,
    required this.profile,
    required this.mode,
  });

  final String sid;
  final String status;
  final String branch;
  final String profile;
  final String mode;

  factory SkcodeDispatchResult.fromJson(Map<String, dynamic> json) {
    return SkcodeDispatchResult(
      sid: json["sid"] as String? ?? "",
      status: json["status"] as String? ?? "",
      branch: json["branch"] as String? ?? "",
      profile: json["profile"] as String? ?? "",
      mode: json["mode"] as String? ?? "",
    );
  }
}

/// `POST /skcode/api/v1/sessions/{sid}/cancel`'s 200 response body (spec
/// section 8). The server is idempotent by construction
/// (`daemon.py::cancel_session`): an unknown or already-finished session
/// answers 200 with `cancelled: false` and a [reason], never an error. This
/// class -- and [SkcodeApiClient.cancelSession] above it -- treat that as a
/// normal, parseable outcome, never an exception, so the caller can surface
/// it honestly instead of reporting success unconditionally.
class SkcodeCancelResult {
  const SkcodeCancelResult({required this.cancelled, required this.reason});

  final bool cancelled;
  final String reason;

  factory SkcodeCancelResult.fromJson(Map<String, dynamic> json) {
    return SkcodeCancelResult(
      cancelled: json["cancelled"] as bool? ?? false,
      reason: json["reason"] as String? ?? "",
    );
  }
}
