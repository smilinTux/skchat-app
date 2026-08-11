/// skcode_client: the skcode subapp packaged as a mountable SKWorld module.
///
/// This is the Phase 1 skeleton (card C-2, spec section 4.1). It exposes:
///
///  * [SkcodeModule]  - `implements SkworldModule`; the entry point the
///                      signed `skworld.module.json` will point its
///                      `entry.flutter_package` at once the registry flip
///                      (card C-10, deliberately last) lands.
///  * [SkcodeSurface] - the module body the shell renders. An EMPTY shell in
///                      this skeleton: it proves the mount (shell theme, bus,
///                      AuthContext) and the standalone boot, nothing more.
///                      Transcript, session, and WS code land in card C-3
///                      and C-4.
///
/// Import gate (module contract standard section 3.1, "a grep gate proves the
/// module's UI package imports only skworld_module_api, never any shell
/// package"): everything under `lib/` imports ONLY
/// `package:skworld_module_api/...`, Flutter, and Dart core. Never a shell
/// package. Proven by `tool/import_gate.sh` and `test/import_gate_test.dart`.
library;

export 'src/skcode_module.dart';
export 'src/skcode_surface.dart';
