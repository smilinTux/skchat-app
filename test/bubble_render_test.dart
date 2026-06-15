import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/theme.dart';
import 'package:skchat/features/conversation/widgets/message_bubble.dart';
import 'package:skchat/models/chat_message.dart';

ChatMessage _msg(String content, {required bool out}) => ChatMessage(
      id: 'id-$content',
      peerId: 'lumina',
      content: content,
      timestamp: DateTime(2026, 1, 1, 12, 0),
      isOutbound: out,
    );

Future<int> _litPixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return -1;
  final bytes = data.buffer.asUint8List();
  int lit = 0;
  for (int i = 0; i + 3 < bytes.length; i += 4) {
    if (bytes[i] > 90 && bytes[i + 1] > 90 && bytes[i + 2] > 90) lit++;
  }
  return lit;
}

Future<void> _pump(WidgetTester tester, ChatMessage m) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(textTheme: SovereignTypography.buildTextTheme()),
    home: Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: 400,
            child: MessageBubble(message: m, soulColor: SovereignColors.soulChef),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  // Regression: a non-uniform Border + borderRadius threw a rendering exception
  // that blanked the whole inbound bubble (text invisible). Both directions must
  // render visible text with no exception.
  testWidgets('inbound bubble paints visible text (no render exception)',
      (tester) async {
    await _pump(tester, _msg('Here, Chef. Came back clean and steady.', out: false));
    expect(tester.takeException(), isNull);
    expect(find.text('Here, Chef. Came back clean and steady.'), findsOneWidget);
    expect(await _litPixels(tester), greaterThan(50));
  });

  testWidgets('outbound bubble paints visible text', (tester) async {
    await _pump(tester, _msg('hello from chef', out: true));
    expect(tester.takeException(), isNull);
    expect(find.text('hello from chef'), findsOneWidget);
    expect(await _litPixels(tester), greaterThan(50));
  });
}
