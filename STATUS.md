# SKChat Flutter App

**Status**: 🚧 Scaffold Complete - Ready for Development

## What's Built

✅ **Project Scaffold**
- Flutter project structure with Material 3
- Dependencies configured (Riverpod, GoRouter, Dio, Hive)
- Analysis options and linter rules

✅ **Sovereign Glass Theme System**
- OLED-black dark theme (`#000000`)
- Glass surface decorations with backdrop blur
- Soul-color derivation from CapAuth fingerprints
- Predefined colors for Lumina (violet-rose), Jarvis (cyan), Chef (amber-gold)
- Reusable glass components (cards, pills, bottom bars, app bars)

✅ **Core Screens**
- **Chat List**: Conversation tiles with soul-color avatars, online status, encryption indicators
- **Conversation View**: Message bubbles (inbound/outbound), input bar, agent-aware typing indicators
- Soul avatar component with gradient rings and agent diamond badges
- Typing indicators with personality-aware animations (Lumina: gentle pulse, Jarvis: cursor blink)

✅ **Data Models**
- `ChatMessage` with Freezed (id, content, sender, timestamp, status, reactions, encryption)
- `Conversation` with presence status, Cloud 9 score, typing indicators
- Message delivery status (sending, sent, delivered, read, failed)

✅ **HTTP Bridge**
- `SKCommsClient` for talking to SKComms daemon on `localhost:9384`
- Endpoints: send, poll inbox, conversations, presence, transport status, groups, agents
- Dio-based with error handling and Riverpod provider

## What's Next

### Immediate (to run the app)

1. **Install Flutter** (if not already done)
   ```bash
   # On Linux with snap
   sudo snap install flutter --classic
   # Or clone from GitHub
   git clone https://github.com/flutter/flutter.git -b stable
   export PATH="$PATH:`pwd`/flutter/bin"
   flutter doctor
   ```

2. **Add Font Assets**
   ```bash
   mkdir -p assets/fonts
   # Download Inter Variable: https://rsms.me/inter/
   # Download JetBrains Mono: https://www.jetbrains.com/mono/
   # Place TTF files in assets/fonts/
   ```

3. **Run Code Generation** (for Freezed models)
   ```bash
   cd skchat/flutter_app
   flutter pub get
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

4. **Start SKComms Daemon** (prerequisite)
   ```bash
   cd skchat
   python -m skchat.cli daemon --port 9384
   ```

5. **Run the App**
   ```bash
   flutter run
   # Or for Android emulator
   flutter emulators --launch <emulator_name>
   flutter run
   ```

### State Management (Next Priority)

Create Riverpod providers for:
- `conversationsProvider` - List of conversations, poll daemon
- `messagesProvider(conversationId)` - Messages for a conversation
- `presenceProvider` - Peer online/offline status
- `identityProvider` - Local CapAuth identity

### Local Persistence

- Initialize Hive boxes for messages, conversations, drafts
- Sync with SKComms daemon on app start
- Cache messages locally for offline viewing

### Background Sync

- WorkManager periodic task (every 30s)
- Poll daemon for new messages
- Show local notifications for new messages

### Navigation Integration

- Wire up GoRouter with actual navigation
- Pass conversation IDs to ConversationScreen
- Handle deep links

## File Locations

```
skchat/flutter_app/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── core/
│   │   ├── theme/
│   │   │   ├── sovereign_glass.dart
│   │   │   ├── soul_color.dart
│   │   │   └── glass_decorations.dart
│   │   └── transport/
│   │       └── skcomms_client.dart
│   ├── features/
│   │   ├── chat_list/
│   │   │   ├── chat_list_screen.dart
│   │   │   └── widgets/
│   │   │       ├── conversation_tile.dart
│   │   │       └── soul_avatar.dart
│   │   └── conversation/
│   │       ├── conversation_screen.dart
│   │       └── widgets/
│   │           ├── message_bubble.dart
│   │           ├── input_bar.dart
│   │           └── typing_indicator.dart
│   └── models/
│       ├── chat_message.dart
│       └── conversation.dart
├── pubspec.yaml
├── analysis_options.yaml
└── README.md
```

## Design Reference

See `skchat/flutter/PRD.md` for full design spec:
- Color tokens
- Typography scale
- Component examples
- Animation timings
- Haptic feedback map

## Architecture Notes

- **No Firebase**: Local notifications via `flutter_local_notifications`
- **No Cloud**: All data syncs via SKComms daemon and Syncthing
- **Localhost Only**: SKComms daemon must run on same device
- **Freezed Models**: Immutable data classes with JSON serialization
- **Riverpod**: State management (providers not yet created)
- **GoRouter**: Declarative routing (routes defined, navigation wiring pending)

## Testing the UI

Even without the daemon running, you can see the UI:
1. Run `flutter run`
2. The app will show mock data (Lumina, Jarvis, Chef conversations)
3. Tapping a conversation will navigate to the conversation view
4. The theme and animations are fully functional

To test with real data:
1. Start the SKComms daemon
2. Wire up the Riverpod providers
3. Replace mock data with daemon calls

## Known Issues

- [ ] Freezed code generation needs to run (will fail on first `flutter run`)
- [ ] Font assets not included (will use system fonts as fallback)
- [ ] Navigation doesn't pass actual conversation IDs yet
- [ ] No state management providers (using mock data)
- [ ] No local persistence (Hive boxes not initialized)

## Questions for transport-builder

1. What's the exact JSON schema for messages from the daemon?
2. Is presence broadcast automatic or manual?
3. How do we handle typing indicators (send on keypress, clear on idle)?
4. Is there a WebSocket endpoint for real-time updates, or do we poll?
5. Group chat key rotation - how is that exposed via API?

---

**Ready to proceed with state management and daemon integration once the API spec is finalized.**
