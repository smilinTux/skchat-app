/// skchat_ui: the skchat subapp packaged as a mountable SKWorld module.
///
/// This is the FIRST increment of the workspace extraction (reconciled spec
/// 3.2 step 2). It exposes:
///
///  * [SkchatModule]  - `implements SkworldModule`; the entry point the signed
///                      `skworld.module.json` (spec 3.1) points its
///                      `entry.flutter_package` at, so the grade-A skchat
///                      manifest has a real package to declare.
///  * [ChatsSurface]  - the module body the shell renders. It now renders the
///                      REAL chats list ([ConversationListTile] rows on the
///                      extracted Sovereign Glass theme, wired to the shell
///                      theme bridge and navigation bus), not the earlier
///                      placeholder. Trust badges and the group composite
///                      avatar are now wired too: the tile renders a
///                      package-pure [PeerTrust] the app injects via
///                      `ChatsSurface.trustResolver`, and a group row renders
///                      the [GroupCompositeAvatar]. The live data feed is
///                      injected from the app side (`LiveChatsSurface`).
///  * [ChatMessage] / [Conversation] - extracted leaf domain models (pure
///                      Dart / theme-only). The app keeps
///                      `lib/models/chat_message.dart` and
///                      `lib/models/conversation.dart` as `export` shims so
///                      every existing importer keeps resolving unchanged.
///  * Sovereign Glass theme + [displayTextFor] - the theme tokens
///                      (`SovereignColors`, `SovereignTheme`, `GlassCard`,
///                      `SoulAvatar`, ...) and pure chat-text helpers the chats
///                      UI needs, extracted here with `lib/core/theme/*.dart`
///                      and `lib/core/chat_text.dart` export shims in the app.
///
/// Import gate (spec 3.2 step 4): everything under `lib/` imports ONLY
/// `package:skworld_module_api/...`, Flutter, and Dart core. Never a shell
/// package. Proven by `tool/import_gate.sh` and `test/import_gate_test.dart`.
library;

export 'src/chat_text.dart' show displayTextFor, normalizePeerKey;
export 'src/chats_surface.dart';
export 'src/conversation_tile.dart';
export 'src/group_composite_avatar.dart';
export 'src/models/chat_message.dart';
export 'src/models/conversation.dart';
export 'src/models/peer_trust.dart';
export 'src/skchat_module.dart';
export 'src/theme/theme.dart';
export 'src/trust_badge.dart';
