import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/sovereign_colors.dart';
import 'package:skchat/features/chats/widgets/group_composite_avatar.dart';
import 'package:skchat/models/conversation.dart';

ConversationMember _m(String name, {String? fp}) =>
    ConversationMember(identityUri: '$name@x', displayName: name, soulFingerprint: fp);

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('renders one initial per member, capped at 3', (tester) async {
    await tester.pumpWidget(_host(GroupCompositeAvatar(
      members: [
        _m('Lumina', fp: 'AAAA1111'),
        _m('Steward', fp: 'BBBB2222'),
        _m('Chef'),
        _m('Opus'),
      ],
      fallbackColor: SovereignColors.textSecondary,
    )));

    // First initial of the first three members, in order; the 4th is dropped.
    expect(find.text('L'), findsOneWidget);
    expect(find.text('S'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('O'), findsNothing);
  });

  testWidgets('empty members falls back to a group icon', (tester) async {
    await tester.pumpWidget(_host(const GroupCompositeAvatar(
      members: [],
      fallbackColor: SovereignColors.textSecondary,
    )));
    expect(find.byIcon(Icons.group_rounded), findsOneWidget);
  });
}
