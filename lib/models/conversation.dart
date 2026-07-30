// Export shim (reconciled spec 3.2 step 2).
//
// The `Conversation` / `ConversationMember` models MOVED into the `skchat_ui`
// workspace package (`packages/skchat_ui/lib/src/models/conversation.dart`) as
// the leaf domain model the extracted chats list renders. Re-exported here so
// every existing importer keeps resolving unchanged. New code should import
// `package:skchat_ui/skchat_ui.dart`.
export 'package:skchat_ui/skchat_ui.dart' show Conversation, ConversationMember;
