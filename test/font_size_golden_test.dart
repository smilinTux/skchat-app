// OS text-scale overflow guard (density spec section 5, card D-1
// acceptance criterion 5).
//
// Density sets BASE sizes; the OS `MediaQuery.textScaler` multiplies on
// top, exactly like production (`lib/main.dart`'s `MaterialApp.router`
// `builder` wraps in `MediaQuery.withClampedTextScaling(maxScaleFactor:
// 2.0)`, no minimum clamp). These tests render three representative rows,
// a chats-list row, a transcript row, and a coordination-board row, at OS
// scale 1.0, 1.3, and 2.0, all at `SovereignDensity.compact` (the app
// default), and assert zero overflow ("yellow/black stripes") exceptions.
//
// This is the test the PRD's "All text scales with system font size
// preference" promise never had before this pass.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skchat/core/theme/theme.dart';
import 'package:skchat/features/chats/widgets/conversation_tile.dart';
import 'package:skchat/features/coord/coord_board_provider.dart';
import 'package:skchat/features/coord/coord_board_screen.dart';
import 'package:skchat/features/chat/message_bubble.dart';
import 'package:skchat/models/chat_message.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/skcapstone_client.dart';

const _scales = [1.0, 1.3, 2.0];

/// A phone-realistic viewport. Overflow at large OS scale is a real-device
/// risk specifically because the viewport does NOT grow with text scale;
/// widening the test surface here would hide exactly the failure this test
/// exists to catch.
const _phoneSize = Size(390, 844);

/// Wraps [child] the way production does: a [SovereignDensity.compact]
/// theme, and the same `MediaQuery.withClampedTextScaling` the app's
/// `MaterialApp.router` builder applies, at a given (already-clamped) OS
/// [scale].
Widget _harness(Widget child, double scale) {
  return MediaQuery(
    data: MediaQueryData(size: _phoneSize, textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: SovereignTheme.dark(density: SovereignDensity.compact),
      home: Scaffold(
        backgroundColor: SovereignColors.surfaceBase,
        body: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 2.0,
          child: SizedBox(width: _phoneSize.width, child: child),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    Hive.init(Directory.systemTemp.createTempSync('skchat_golden_hive').path);
  });

  group('chats list row at OS scale', () {
    // Deliberately long content: a stress case, not a realistic average
    // row, so a regression that only breaks on long peer names/messages
    // is caught the same as one that breaks universally.
    final rows = <Conversation>[
      Conversation(
        peerId: 'agent-1',
        displayName:
            'A Very Extremely Long Agent Display Name That Threatens Row Overflow',
        lastMessage:
            'This is a long last-message preview meant to stress-test the '
            'ellipsis handling under large OS text scale factors combined '
            'with compact density spacing.',
        lastMessageTime: DateTime(2026, 8, 10, 9, 30),
        isAgent: true,
        isOnline: true,
        unreadCount: 250,
      ),
      Conversation(
        peerId: 'group-1',
        displayName: 'Engineering Team Sync, Overnight Swarm Coordination',
        lastMessage: 'typing indicator stress row',
        lastMessageTime: DateTime(2026, 8, 10, 9, 25),
        isGroup: true,
        isTyping: true,
        memberCount: 6,
        members: const [
          ConversationMember(identityUri: 'a', displayName: 'Alice'),
          ConversationMember(identityUri: 'b', displayName: 'Bob'),
          ConversationMember(identityUri: 'c', displayName: 'Chef'),
        ],
      ),
    ];

    for (final scale in _scales) {
      testWidgets('scale $scale: no overflow', (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            child: _harness(
              ListView(
                children: [
                  for (final c in rows)
                    ConversationTile(conversation: c, onTap: () {}),
                ],
              ),
              scale,
            ),
          ),
        );
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'chats list row overflowed at OS text scale $scale',
        );
      });
    }
  });

  group('transcript row at OS scale', () {
    final messages = [
      ChatMessage(
        id: 'm1',
        peerId: 'p1',
        content:
            'A long inbound message body meant to stress-test bubble wrap '
            'and timestamp layout under large OS text scale factors, the '
            'kind of message a real conversation actually contains.',
        timestamp: DateTime(2026, 8, 10, 9, 31),
        isOutbound: false,
      ),
      ChatMessage(
        id: 'm2',
        peerId: 'p1',
        content: 'Short outbound reply.',
        timestamp: DateTime(2026, 8, 10, 9, 32),
        isOutbound: true,
        deliveryStatus: 'read',
      ),
    ];

    for (final scale in _scales) {
      testWidgets('scale $scale: no overflow', (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            child: _harness(
              ListView(
                children: [
                  for (final m in messages) ChatMessageBubble(message: m),
                ],
              ),
              scale,
            ),
          ),
        );
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'transcript row overflowed at OS text scale $scale',
        );
      });
    }
  });

  group('coord board row at OS scale', () {
    for (final scale in _scales) {
      testWidgets('scale $scale: no overflow', (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coordBoardProvider.overrideWith(_StubCoordBoard.new),
            ],
            child: _harness(const CoordBoardScreen(), scale),
          ),
        );
        // CoordBoardScreen depends on an async provider; let it resolve.
        await tester.pump();
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'coord board row overflowed at OS text scale $scale',
        );
      });
    }
  });
}

class _StubCoordBoard extends CoordBoardNotifier {
  @override
  Future<CoordBoardData?> build() async {
    return CoordBoardData(
      tasks: [
        const CoordTask(
          id: 't1',
          title:
              'A very long coordination task title meant to stress-test the '
              'task tile at large OS text scale factors and compact density',
          priority: 'critical',
          status: 'in_progress',
          claimedBy: kMyAgentName,
          tags: ['density', 'phase0', 'repo:skworld-app'],
        ),
        const CoordTask(
          id: 't2',
          title: 'Team task not claimed by me',
          priority: 'high',
          status: 'open',
          tags: ['repo:skworld-app'],
        ),
      ],
      agents: const [
        AgentBoardStatus(name: 'lumina', state: 'active', currentTask: 't1'),
      ],
      summary: const CoordSummary(total: 2, done: 0, open: 1, inProgress: 1),
    );
  }
}
