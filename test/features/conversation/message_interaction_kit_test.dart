import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/theme.dart';
import 'package:skchat/features/conversation/widgets/message_bubble.dart';
import 'package:skchat/features/conversation/widgets/message_content.dart';
import 'package:skchat/models/chat_message.dart';

ChatMessage _msg(
  String content, {
  required bool out,
  String id = 'm1',
  String contentType = 'text',
  DateTime? ts,
  DateTime? editedAt,
  List<String> editHistory = const [],
  Map<String, List<String>> reactions = const {},
}) =>
    ChatMessage(
      id: id,
      peerId: 'lumina',
      content: content,
      timestamp: ts ?? DateTime(2026, 1, 1, 12, 0),
      isOutbound: out,
      contentType: contentType,
      editedAt: editedAt,
      editHistory: editHistory,
      reactionSenders: reactions,
    );

Future<void> _pump(
  WidgetTester tester,
  MessageBubble bubble,
) async {
  // Tall viewport + top-aligned bubble so long-press popup menus (which anchor
  // above/below the bubble) render on-screen in the test harness.
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(textTheme: SovereignTypography.buildTextTheme()),
      home: Scaffold(
        backgroundColor: SovereignColors.surfaceBase,
        body: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 200),
            child: SizedBox(width: 400, child: bubble),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('swipe-to-reply', () {
    testWidgets('inbound swipe right past threshold fires onReply', (t) async {
      var replied = false;
      await _pump(
        t,
        MessageBubble(
          message: _msg('hi from lumina', out: false),
          soulColor: SovereignColors.soulLumina,
          onReply: () => replied = true,
        ),
      );

      // Drag right past the 72px reply threshold and release.
      await t.drag(find.text('hi from lumina'), const Offset(120, 0));
      await t.pumpAndSettle();

      expect(replied, isTrue);
    });

    testWidgets('outbound swipe left past threshold fires onReply', (t) async {
      var replied = false;
      await _pump(
        t,
        MessageBubble(
          message: _msg('hi from chef', out: true),
          soulColor: SovereignColors.soulChef,
          onReply: () => replied = true,
        ),
      );

      await t.drag(find.text('hi from chef'), const Offset(-120, 0));
      await t.pumpAndSettle();

      expect(replied, isTrue);
    });

    testWidgets('small swipe below threshold does NOT fire onReply', (t) async {
      var replied = false;
      await _pump(
        t,
        MessageBubble(
          message: _msg('hi', out: false),
          soulColor: SovereignColors.soulLumina,
          onReply: () => replied = true,
        ),
      );
      await t.drag(find.text('hi'), const Offset(20, 0));
      await t.pumpAndSettle();
      expect(replied, isFalse);
    });
  });

  group('reaction tray', () {
    testWidgets('long-press opens the reaction tray (6 suggested + overflow)',
        (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg('react to me', out: false),
          soulColor: SovereignColors.soulLumina,
          onReact: (_) {},
        ),
      );

      await t.longPress(find.text('react to me'));
      await t.pumpAndSettle();

      // Actions sheet shows React/Reply/Copy; tap React to reveal the tray.
      expect(find.text('React'), findsOneWidget);
      await t.tap(find.text('React'));
      await t.pumpAndSettle();

      // 6 suggested emoji are present in the tray.
      for (final e in const ['❤️', '🔥', '👍', '😂', '😮', '🙏']) {
        expect(find.text(e), findsWidgets, reason: 'tray should show $e');
      }
      // Overflow affordance present.
      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    });

    testWidgets('tapping a reaction chip toggles via onReact', (t) async {
      String? toggled;
      await _pump(
        t,
        MessageBubble(
          message: _msg(
            'has reactions',
            out: false,
            reactions: {
              '❤️': ['chef'],
            },
          ),
          soulColor: SovereignColors.soulLumina,
          myIdentity: 'me',
          onReact: (emoji) => toggled = emoji,
        ),
      );

      // The chip renders "❤️ 1"; tapping it toggles that emoji.
      expect(find.textContaining('❤️'), findsWidgets);
      await t.tap(find.textContaining('❤️ 1'));
      await t.pumpAndSettle();
      expect(toggled, '❤️');
    });

    testWidgets('own reaction chip is highlighted (bold)', (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg(
            'mine',
            out: false,
            reactions: {
              '🔥': ['me'],
            },
          ),
          soulColor: SovereignColors.soulLumina,
          myIdentity: 'me',
          onReact: (_) {},
        ),
      );
      final chip = t.widget<Text>(find.textContaining('🔥 1'));
      expect(chip.style?.fontWeight, FontWeight.w700);
    });
  });

  group('edit', () {
    testWidgets('edited message shows the "edited" badge', (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg(
            'edited body',
            out: true,
            editedAt: DateTime(2026, 1, 1, 12, 5),
            editHistory: const ['original body'],
          ),
          soulColor: SovereignColors.soulLumina,
          onEdit: (_) {},
        ),
      );
      expect(find.text('edited'), findsOneWidget);
    });

    testWidgets('tapping the edited badge opens edit history', (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg(
            'current text',
            out: true,
            editedAt: DateTime(2026, 1, 1, 12, 5),
            editHistory: const ['first draft'],
          ),
          soulColor: SovereignColors.soulLumina,
          onEdit: (_) {},
        ),
      );
      await t.tap(find.text('edited'));
      await t.pumpAndSettle();
      expect(find.text('Edit history'), findsOneWidget);
      expect(find.text('first draft'), findsOneWidget);
      expect(find.text('current text'), findsWidgets);
    });

    testWidgets('own recent message offers Edit in the actions sheet', (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg('editable', out: true, ts: DateTime.now()),
          soulColor: SovereignColors.soulLumina,
          onEdit: (_) {},
        ),
      );
      await t.longPress(find.text('editable'));
      await t.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
    });
  });

  group('golden rule — content_type fallback', () {
    testWidgets('unknown content_type renders its body', (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg(
            'You are here: 40.7,-74.0',
            out: false,
            contentType: 'application/skchat.location+json',
          ),
          soulColor: SovereignColors.soulLumina,
        ),
      );
      // Body is shown verbatim (never dropped) ...
      expect(find.text('You are here: 40.7,-74.0'), findsOneWidget);
      // ... with a short type tag noting the forward-compat degrade.
      expect(find.text('location'), findsOneWidget);
    });

    testWidgets('MessageContent.knownTypes excludes future types', (t) async {
      expect(
        MessageContent.knownTypes.contains('application/skchat.poll+json'),
        isFalse,
      );
      expect(MessageContent.knownTypes.contains('text'), isTrue);
    });

    testWidgets('system content_type renders italic body', (t) async {
      await _pump(
        t,
        MessageBubble(
          message: _msg('Lumina joined', out: false, contentType: 'system'),
          soulColor: SovereignColors.soulLumina,
        ),
      );
      expect(find.text('Lumina joined'), findsOneWidget);
    });
  });

  group('thread affordance', () {
    testWidgets('a message with a thread shows "View thread"', (t) async {
      final m = _msg('rooted', out: false).copyWith(threadId: 'thr-1');
      var opened = false;
      await _pump(
        t,
        MessageBubble(
          message: m,
          soulColor: SovereignColors.soulLumina,
          onOpenThread: () => opened = true,
        ),
      );
      expect(find.text('View thread'), findsOneWidget);
      await t.tap(find.text('View thread'));
      await t.pumpAndSettle();
      expect(opened, isTrue);
    });
  });
}
