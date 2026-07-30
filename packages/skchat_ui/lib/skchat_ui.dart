/// skchat_ui: the skchat subapp packaged as a mountable SKWorld module.
///
/// This is the FIRST increment of the workspace extraction (reconciled spec
/// 3.2 step 2). It exposes:
///
///  * [SkchatModule]  - `implements SkworldModule`; the entry point the signed
///                      `skworld.module.json` (spec 3.1) points its
///                      `entry.flutter_package` at, so the grade-A skchat
///                      manifest has a real package to declare.
///  * [ChatsSurface]  - the initial module body the shell renders. A bounded
///                      placeholder for now (see its TODO): the full ChatsScreen
///                      still lives in the app because it is entangled with
///                      lib/core, lib/models, lib/services and lib/data, which
///                      move into this package in later increments.
///  * [ChatMessage]   - the first genuinely-leaf feature extracted here (the
///                      core chat domain model, pure Dart, zero imports). The
///                      app keeps `lib/models/chat_message.dart` as an `export`
///                      shim so its 16 existing importers keep resolving
///                      unchanged (spec 3.2 step 2, "export shims so imports
///                      never break").
///
/// Import gate (spec 3.2 step 4): everything under `lib/` imports ONLY
/// `package:skworld_module_api/...`, Flutter, and Dart core. Never a shell
/// package. Proven by `tool/import_gate.sh` and `test/import_gate_test.dart`.
library;

export 'src/chats_surface.dart';
export 'src/models/chat_message.dart';
export 'src/skchat_module.dart';
