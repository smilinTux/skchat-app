/// skcode_client: the skcode subapp packaged as a mountable SKWorld module.
///
/// This is the Phase 1 build: the mount skeleton (card C-2), the transport
/// layer (card C-3, moved in unchanged by C-3b), and the render layer on top
/// of it (card C-4). It exposes:
///
///  * [SkcodeModule]  - `implements SkworldModule`; the entry point the
///                      signed `skworld.module.json` will point its
///                      `entry.flutter_package` at once the registry flip
///                      (card C-10, deliberately last) lands. Takes [origin]
///                      and [onAuthRejected] through its constructor (card
///                      C-3b): the one seam the transport needed to move
///                      here, since nothing in [ShellContext] /
///                      [AuthContext] says where the backend lives.
///  * [SkcodeSurface] - the module body the shell renders: the sessions
///                      rail, which IS the `/code` landing screen on phone
///                      (card C-4, spec section 7).
///  * [SkcodeSessionsRail] / [SkcodeSessionScreen] - the phone layout (card
///                      C-4 part 4): the rail polls sessions and pushes the
///                      full-screen session view; the session screen owns a
///                      live [SkcodeSessionStore] and toggles EXCLUSIVELY
///                      between [SkcodeTranscriptList] and [SkcodeRawRail]
///                      (never both at once), matching Buzz's
///                      `RawRailLayout` "side maps to exclusive" phone rule.
///  * [ActivityRenderClass] / [ActivityTone] / [ToolStatus] /
///    [classifySkcodeEvent] / [buildSkcodeTranscript] - the activity render
///    taxonomy (card C-4 parts 1-2), ported to Dart with attribution to
///    Buzz's `agentSessionTypes.ts` / `agentSessionToolClassifier.ts`. Every
///    render class carries a tone ([kDefaultToneForClass]); the transcript
///    reducer folds a `tool_call`/`tool_result` pair into one row and drops
///    `suppressed` events, which still surface in [SkcodeRawRail].
///  * [SkcodeTranscriptList] / [SkcodeRawRail] - the two views (card C-4
///    parts 2-3). Both key their rows on [skcodeEventRowId] so the same
///    underlying event anchors to the same row in either view.
///  * [SkcodeArtifactPane] - the artifact pane (card C-7, spec section 7
///    rev 2): Diff/Digest/Logs/Raw tabs (chat content is C-12's; it has a
///    reserved slot), the two-layer negative-x panel-left shadow ported from
///    Buzz with attribution, and [SkcodeArtifactPane.showBottomSheet] for the
///    phone swipe-up presentation.
///  * [SkcodeDigestTab] / [SkcodeDigest] / [SkcodeDigestEvent] - card C-9
///    (renderer) and card C-14a (data source): renders the skwatchdog
///    published digest fetched from skcode-hostd's own
///    `GET /api/v1/watchdog/digest` through [SkcodeApiClient.fetchDigest],
///    Bearer-authenticated on the `skcode.stream` read scope like every other
///    read here, with every line's link tappable through an injected
///    `onOpenLink` (the module boundary seam this package cannot resolve
///    itself, since it cannot import host routing). Four failure states stay
///    distinct on purpose (no digest published, not authorized, corrupt
///    artifact, host unreachable) and none of them is ever rendered as a real
///    digest that happened to be quiet. No digest data is stored or recomputed
///    here; the artifact stays the single narrative surface.
///  * [SkcodeApiClient] / [SkcodeSessionStore] / [SkcodeSessionsListStore] /
///                      [SkcodeWsTransport] / [SkcodeEvent] - the transport
///                      layer (card C-3, moved here unchanged by card C-3b):
///                      Bearer-header HTTP for the read plane, a `?token=`
///                      WS tail with jittered-backoff reconnect,
///                      `(sid, seq, ts)` dedup merge of the live and
///                      archived event windows, and the 401/1008
///                      re-mint-once-then-fail-visibly rule. It reaches auth
///                      ONLY through the `mintToken` / `onAuthRejected`
///                      callbacks its constructors take, never a host
///                      service directly.
///  * [SkcodeJobRun] / [SkcodeJobsListStore] / [SkcodeJobsPoll] - the Jobs
///                      section's own read-only view (card C-8, spec
///                      section 8) over `GET /skcode/api/v1/jobs`: a
///                      separately-polled cron-ledger row shape, NEVER
///                      folded into [SkcodeSessionSummary] or
///                      `SkcodeSessionStore`'s event merge. `stale` /
///                      `staleness_s` are server-computed and displayed
///                      as-is; nothing here recomputes them. Rendered
///                      beneath the sessions list by
///                      [SkcodeSessionsRail]'s private `_JobsSection`; there
///                      is no run-now/retry/cancel action on this surface in
///                      v1.
///  * [kSkcodeAudience] / [skcodeWsUri] - pure config the transport and its
///                      callers share (the capauth audience name, and the
///                      http(s) -> ws(s) URL builder).
///  * [SkcodeInjectComposer] / [SkcodeNeedsInputBanner] - card C-5, spec
///                      section 7.1: the terminal-styled, amber-bordered
///                      session-inject composer (button verb "Inject", a
///                      persistent `INJECT -> <sid>` target chip, its own
///                      non-Tab-traversable [FocusNode]) and the
///                      needs_input Approve/Deny banner pinned above it.
///                      [SkcodeSessionScreen] owns the gate: both render
///                      only when the mounted module's [AuthContext] carries
///                      [kSkcodeInjectScope] (composer additionally requires
///                      an interactive session).
///  * [SkcodeDispatchForm] / [SkcodeDispatchScreen] / [SkcodeDispatchTargets]
///                      / [SkcodeDispatchResult] / [SkcodeCancelResult] -
///                      card C-6, spec sections 3.1 and 8's "New run" row:
///                      the New Session form, fed ENTIRELY by
///                      `GET /dispatch/targets` (repo/harness/profile/model
///                      options come from that response and nowhere else -
///                      never hardcoded) and submitting to `POST /dispatch`;
///                      plus the cancel affordance on [SkcodeSessionScreen]
///                      (`POST /sessions/{sid}/cancel`, honest about the
///                      server's idempotent `cancelled: false`). Both routes
///                      are `skcode.dispatch` scope, PDP-decided:
///                      [SkcodeSessionsRail]'s New Session entry point and
///                      the session screen's cancel button both render only
///                      when the mounted module's [AuthContext] carries
///                      [kSkcodeDispatchScope].
///
/// Import gate (module contract standard section 3.1, "a grep gate proves the
/// module's UI package imports only skworld_module_api, never any shell
/// package"): everything under `lib/` imports ONLY `package:flutter/...`,
/// `package:skworld_module_api/...`, `package:dio/...`,
/// `package:web_socket_channel/...`, and Dart core. Never a shell package.
/// Proven by `tool/import_gate.sh` and `test/import_gate_test.dart`.
library;

export 'src/skcode_activity_taxonomy.dart';
export 'src/skcode_api_client.dart';
export 'src/skcode_artifact_pane.dart';
export 'src/skcode_chat_chip.dart';
export 'src/skcode_config.dart';
export 'src/skcode_digest.dart';
export 'src/skcode_digest_tab.dart';
export 'src/skcode_dispatch_form.dart';
export 'src/skcode_dispatch_targets.dart';
export 'src/skcode_event.dart';
export 'src/skcode_event_merge.dart';
export 'src/skcode_inject_composer.dart';
export 'src/skcode_job_run.dart';
export 'src/skcode_jobs_list_store.dart';
export 'src/skcode_module.dart';
export 'src/skcode_needs_input_banner.dart';
export 'src/skcode_pane_tier.dart';
export 'src/skcode_project_chat.dart';
export 'src/skcode_raw_rail.dart';
export 'src/skcode_responsive_body.dart';
export 'src/skcode_session_column.dart';
export 'src/skcode_session_screen.dart';
export 'src/skcode_session_store.dart';
export 'src/skcode_sessions_list_store.dart';
export 'src/skcode_sessions_rail.dart';
export 'src/skcode_surface.dart';
export 'src/skcode_tone_style.dart';
export 'src/skcode_transcript_list.dart';
export 'src/skcode_ws_transport.dart';
