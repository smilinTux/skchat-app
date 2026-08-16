/// Pure decision logic for "a newer build is deployed than the one this tab
/// is running" notices.
///
/// The problem this replaces: the old plain-HTML Space client (`space.html`)
/// compiled a build stamp into the page, polled `GET /spaces/build` on
/// `visibilitychange`, and reloaded or prompted when the deployed hash
/// disagreed with its own. That self-heal is deleted along with the client
/// it lived in, and the Flutter app has had no equivalent: an ALREADY OPEN
/// tab keeps running the JavaScript it loaded, forever, no matter how many
/// times the server redeploys, because cache headers only affect the *next*
/// load and this tab is never doing a next load. That is exactly what
/// stranded the operator's phones on a stale build during a live call.
///
/// Everything here is pure Dart: no Flutter, no HTTP, no timers. The whole
/// "is the served build newer / different from mine, and should I say
/// anything" decision lives here so it can be unit tested exhaustively; the
/// actual fetching and the `visibilitychange`-driven polling live in
/// `services/deploy_freshness_service.dart`.
library;

/// What a deploy-freshness check should tell the UI to do.
enum DeployFreshnessAction {
  /// Nothing worth saying: same build, an unresolved earlier prompt is still
  /// outstanding, or the check itself could not be trusted (see
  /// [resolveDeployFreshness]).
  none,

  /// A different build is now being served than the one this session first
  /// observed. Always surfaced as a DISMISSIBLE prompt, never an automatic
  /// reload: reloading a tab that is mid-call or mid-Space would drop the
  /// room, which is far worse than running an old build for another minute.
  /// There is no [DeployFreshnessAction] value for "reload now" on purpose.
  prompt,
}

/// Pure decision: given what the server reports right now compared to the
/// baseline this session captured, should the UI say anything?
///
/// [servedMarker] is fetched fresh from the server on every check (see
/// [DeployFreshnessTracker.onCheck]) and stands in for "whatever build the
/// server is serving right now". [baselineMarker] is the first
/// [servedMarker] this session ever observed successfully, captured once
/// near startup. Comparing those two is comparing "what the server said when
/// this tab started" to "what the server says now": the only comparison that
/// can ever legitimately disagree.
///
/// A null or empty marker on EITHER side means "don't know" (a failed
/// request, a response with no usable header, or "no baseline captured
/// yet") and must never be read as "changed". A missing signal is the
/// ordinary, expected case on a network hiccup or the very first check of
/// the session; treating it as a genuine change would nag the operator over
/// nothing, and the whole feature exists to be trustworthy enough that a
/// prompt always means something real.
DeployFreshnessAction resolveDeployFreshness({
  required String? servedMarker,
  required String? baselineMarker,
}) {
  if (servedMarker == null || servedMarker.isEmpty) {
    return DeployFreshnessAction.none;
  }
  if (baselineMarker == null || baselineMarker.isEmpty) {
    return DeployFreshnessAction.none;
  }
  if (servedMarker == baselineMarker) {
    return DeployFreshnessAction.none;
  }
  return DeployFreshnessAction.prompt;
}

/// [resolveDeployFreshness] plus the memory needed to run it as a session:
/// capture a baseline on the first check, prompt at most once per genuinely
/// new deploy, and never re-arm a prompt the operator has not yet acted on.
/// One instance per app run, driven by a `visibilitychange`-triggered check
/// (see `DeployFreshnessService`).
class DeployFreshnessTracker {
  DeployFreshnessTracker({required this.myBuildId});

  /// The compile-time `BUILD_ID` this running instance was built with (see
  /// `core/build_info.dart`). This is a VALIDITY GATE only, never a value
  /// compared against anything else compiled in: two constants baked into
  /// the same binary at the same build always agree with each other, so
  /// comparing [myBuildId] against, say, `kAppVersion` would silently never
  /// fire. A build with no dart-defines (`'dev'`, an ordinary local
  /// `flutter run`) has no meaningful "deployed build" to compare against,
  /// so [myBuildId] exists only to stand the whole tracker down in that
  /// case, once, rather than nagging a developer's local session. The real
  /// comparison in [onCheck] is entirely between two values FETCHED from the
  /// server at different times, which is the only comparison that can ever
  /// disagree.
  final String myBuildId;

  String? _baseline;
  String? _pending;

  bool get _enabled => myBuildId.isNotEmpty && myBuildId != 'dev';

  /// The marker this session is currently comparing against. Exposed for
  /// diagnostics / tests only.
  String? get baseline => _baseline;

  /// Whether a prompt is currently outstanding (shown, not yet dismissed or
  /// acted on). Diagnostic / test surface.
  bool get hasPendingPrompt => _pending != null;

  /// Feed one fresh fetch result in. Returns what the UI should do.
  ///
  /// The FIRST call (per instance) only establishes the baseline: there is
  /// nothing to compare against yet, so whatever the server is serving right
  /// now is, by definition, what this tab is running. Every call after that
  /// compares the fresh marker to the baseline via [resolveDeployFreshness].
  ///
  /// While a prompt is already outstanding ([hasPendingPrompt]), further
  /// checks answer [DeployFreshnessAction.none] rather than re-deciding: a
  /// `visibilitychange` firing every time the operator glances at the tab
  /// must not re-show a banner they already dismissed once, or worse, that
  /// they are already reading. Call [acknowledge] to clear it.
  DeployFreshnessAction onCheck(String? servedMarker) {
    if (!_enabled) return DeployFreshnessAction.none;

    if (_baseline == null) {
      if (servedMarker != null && servedMarker.isNotEmpty) {
        _baseline = servedMarker;
      }
      return DeployFreshnessAction.none;
    }

    if (_pending != null) return DeployFreshnessAction.none;

    final action = resolveDeployFreshness(
      servedMarker: servedMarker,
      baselineMarker: _baseline,
    );
    if (action == DeployFreshnessAction.prompt) {
      _pending = servedMarker;
    }
    return action;
  }

  /// The operator dismissed the prompt, or tapped reload (about to leave
  /// anyway either way). Promotes the pending marker to the new baseline, so
  /// the SAME deploy never prompts twice; a genuinely NEWER deploy landing
  /// after this still will, on the next [onCheck].
  void acknowledge() {
    if (_pending != null) {
      _baseline = _pending;
      _pending = null;
    }
  }
}
