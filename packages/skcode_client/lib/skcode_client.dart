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
///    rev 2): Diff/Logs/Raw tabs (Digest is C-9's, chat content is C-12's;
///    both have reserved slots), the two-layer negative-x panel-left
///    shadow ported from Buzz with attribution, and
///    [SkcodeArtifactPane.showBottomSheet] for the phone swipe-up
///    presentation.
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
///  * [kSkcodeAudience] / [skcodeWsUri] - pure config the transport and its
///                      callers share (the capauth audience name, and the
///                      http(s) -> ws(s) URL builder).
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
export 'src/skcode_config.dart';
export 'src/skcode_event.dart';
export 'src/skcode_event_merge.dart';
export 'src/skcode_module.dart';
export 'src/skcode_raw_rail.dart';
export 'src/skcode_session_screen.dart';
export 'src/skcode_session_store.dart';
export 'src/skcode_sessions_list_store.dart';
export 'src/skcode_sessions_rail.dart';
export 'src/skcode_surface.dart';
export 'src/skcode_tone_style.dart';
export 'src/skcode_transcript_list.dart';
export 'src/skcode_ws_transport.dart';
