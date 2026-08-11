/// skcode_client: the skcode subapp packaged as a mountable SKWorld module.
///
/// This is the Phase 1 skeleton (card C-2, spec section 4.1) plus the
/// transport layer moved in by card C-3b. It exposes:
///
///  * [SkcodeModule]  - `implements SkworldModule`; the entry point the
///                      signed `skworld.module.json` will point its
///                      `entry.flutter_package` at once the registry flip
///                      (card C-10, deliberately last) lands. Takes [origin]
///                      and [onAuthRejected] through its constructor (card
///                      C-3b): the one seam the transport needed to move
///                      here, since nothing in [ShellContext] /
///                      [AuthContext] says where the backend lives.
///  * [SkcodeSurface] - the module body the shell renders. An EMPTY shell in
///                      this skeleton: it proves the mount (shell theme, bus,
///                      AuthContext) and the standalone boot, nothing more.
///                      The real transcript UI lands in card C-4.
///  * [SkcodeApiClient] / [SkcodeSessionStore] / [SkcodeSessionsListStore] /
///    [SkcodeWsTransport] / [SkcodeEvent] - the transport layer (card C-3,
///                      moved here unchanged by card C-3b): Bearer-header
///                      HTTP for the read plane, a `?token=` WS tail with
///                      jittered-backoff reconnect, `(sid, seq, ts)` dedup
///                      merge of the live and archived event windows, and
///                      the 401/1008 re-mint-once-then-fail-visibly rule.
///                      It reaches auth ONLY through the `mintToken` /
///                      `onAuthRejected` callbacks its constructors take,
///                      never a host service directly.
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

export 'src/skcode_api_client.dart';
export 'src/skcode_config.dart';
export 'src/skcode_event.dart';
export 'src/skcode_event_merge.dart';
export 'src/skcode_module.dart';
export 'src/skcode_session_store.dart';
export 'src/skcode_sessions_list_store.dart';
export 'src/skcode_surface.dart';
export 'src/skcode_ws_transport.dart';
