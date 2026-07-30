// Export shim (reconciled spec 3.2 step 2).
//
// The pure chat-text helpers (`displayTextFor`, `normalizePeerKey`) MOVED into
// the `skchat_ui` workspace package (`packages/skchat_ui/lib/src/chat_text.dart`)
// so the extracted chats surface can derive list previews without importing a
// shell/app package. Re-exported here so every existing importer keeps
// resolving. New code should import `package:skchat_ui/skchat_ui.dart`.
export 'package:skchat_ui/skchat_ui.dart' show displayTextFor, normalizePeerKey;
