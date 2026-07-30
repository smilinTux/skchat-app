// Export shim (reconciled spec 3.2 step 2).
//
// The `ChatMessage` model MOVED into the `skchat_ui` workspace package
// (`packages/skchat_ui/lib/src/models/chat_message.dart`) as the first
// genuinely-leaf feature extracted in the workspace split. This file stays at
// its original path and re-exports the moved type so every existing importer
// (all 16 use a relative `../models/chat_message.dart` path) keeps resolving
// unchanged, with no call-site edits. New code should import
// `package:skchat_ui/skchat_ui.dart` directly.
export 'package:skchat_ui/skchat_ui.dart' show ChatMessage;
