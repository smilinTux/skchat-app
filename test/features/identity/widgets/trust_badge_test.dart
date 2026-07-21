import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/self_identity.dart';
import 'package:skchat/features/identity/widgets/trust_badge.dart';

void main() {
  testWidgets('renders the tier label', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TrustBadge(tier: SelfTrustTier.red))));
    expect(find.text('Untrusted'), findsOneWidget);
  });

  testWidgets('compact renders no text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: TrustBadge(tier: SelfTrustTier.green, compact: true))));
    expect(find.text('Sovereign'), findsNothing);
  });

  testWidgets('custom label overrides default', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: TrustBadge(tier: SelfTrustTier.amber, label: 'Verified'))));
    expect(find.text('Verified'), findsOneWidget);
  });
}
