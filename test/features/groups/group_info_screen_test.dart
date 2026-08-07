import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/data/conversation_repository.dart';
import 'package:skchat/features/groups/group_info_screen.dart';
import 'package:skchat/features/groups/groups_provider.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/daemon_service.dart';
import 'package:skchat/services/skcomms_client.dart';
import 'package:skchat/services/peer_trust_store.dart';
import 'package:skchat/features/identity/widgets/trust_badge.dart';
import 'package:skchat/core/theme/sovereign_colors.dart';

/// In-memory trust store so the tier resolver is Hive-free under widget-test
/// fake async (real Hive I/O never completes and would stick the tier provider
/// on AsyncLoading, masking the real render).
class _MemTrustStore implements PeerTrustStore {
  final Map<String, PeerTrustRecord> _m = {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => _m;
  @override
  Future<void> save(Map<String, PeerTrustRecord> records) async {
    _m
      ..clear()
      ..addAll(records);
  }
}

class _MockClient extends Mock implements SKCommsClient {}

class _MockRepo extends Mock implements ConversationRepository {}

/// GroupsNotifier seeded with one group so the info screen finds it.
class _FakeGroupsNotifier extends GroupsNotifier {
  _FakeGroupsNotifier(this._seed);
  final List<Conversation> _seed;
  @override
  List<Conversation> build() => _seed;
}

Conversation _group(String id) => Conversation(
      peerId: id,
      displayName: 'Penguins',
      lastMessage: '',
      lastMessageTime: DateTime(2026),
      isGroup: true,
      memberCount: 2,
    );

Widget _wrapInfo({
  required _MockClient client,
  required _MockRepo repo,
  required List<GroupMemberInfo> members,
  String groupId = 'g-1',
  List<Override> extraOverrides = const [],
}) {
  final router = GoRouter(
    initialLocation: '/groups/$groupId/info',
    routes: [
      GoRoute(
        path: '/chats',
        builder: (_, __) => const Scaffold(body: Text('CHATS LIST')),
      ),
      GoRoute(
        path: '/groups/:id/info',
        builder: (_, __) => GroupInfoScreen(groupId: groupId),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      skcommsClientProvider.overrideWithValue(client),
      conversationRepositoryProvider.overrideWithValue(repo),
      // Fixed local identity so the admin gate is deterministic (no Hive).
      daemonServiceProvider
          .overrideWithValue(DaemonService(identity: 'chef@skworld.io')),
      groupsProvider.overrideWith(() => _FakeGroupsNotifier([_group(groupId)])),
      groupMembersProvider(groupId).overrideWith((ref) async => members),
      ...extraOverrides,
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  group('GroupMemberInfo', () {
    test('defaults are correct', () {
      const member = GroupMemberInfo(
        identityUri: 'capauth://test',
        displayName: 'Test',
      );

      expect(member.identityUri, 'capauth://test');
      expect(member.displayName, 'Test');
      expect(member.role, MemberRole.member);
      expect(member.participantType, ParticipantType.human);
      expect(member.isOnline, false);
      expect(member.soulColor, isNull);
    });

    test('fromJson parses complete member data', () {
      final json = {
        'identity_uri': 'capauth://lumina',
        'display_name': 'Lumina',
        'role': 'admin',
        'participant_type': 'agent',
        'is_online': true,
        'soul_fingerprint': '02BC0EB3CAD31DB691A753C70C5629AB893F9746',
      };

      final member = GroupMemberInfo.fromJson(json);

      expect(member.identityUri, 'capauth://lumina');
      expect(member.displayName, 'Lumina');
      expect(member.role, MemberRole.admin);
      expect(member.participantType, ParticipantType.agent);
      expect(member.isOnline, true);
      expect(member.soulFingerprint, '02BC0EB3CAD31DB691A753C70C5629AB893F9746');
    });

    test('fromJson reads the fingerprint alias when soul_fingerprint absent', () {
      final member = GroupMemberInfo.fromJson({
        'identity_uri': 'capauth://steward',
        'display_name': 'Steward',
        'fingerprint': '4E06A71935D1DF1FB9848112D8634AB3E7B55236',
      });
      expect(member.soulFingerprint, '4E06A71935D1DF1FB9848112D8634AB3E7B55236');
    });

    test('fromJson handles missing fields with defaults', () {
      final member = GroupMemberInfo.fromJson({});

      expect(member.identityUri, '');
      expect(member.displayName, '');
      expect(member.role, MemberRole.member);
      expect(member.participantType, ParticipantType.human);
      expect(member.isOnline, false);
    });

    test('fromJson parses observer role', () {
      final json = {
        'identity_uri': 'capauth://viewer',
        'display_name': 'Viewer',
        'role': 'observer',
      };

      final member = GroupMemberInfo.fromJson(json);
      expect(member.role, MemberRole.observer);
    });

    test('fromJson parses service participant type', () {
      final json = {
        'identity_uri': 'capauth://bot',
        'display_name': 'Bot',
        'participant_type': 'service',
      };

      final member = GroupMemberInfo.fromJson(json);
      expect(member.participantType, ParticipantType.service);
    });

    test('fromJson defaults unknown role to member', () {
      final json = {
        'identity_uri': 'capauth://test',
        'display_name': 'Test',
        'role': 'unknown-role',
      };

      final member = GroupMemberInfo.fromJson(json);
      expect(member.role, MemberRole.member);
    });

    test('fromJson defaults unknown participant type to human', () {
      final json = {
        'identity_uri': 'capauth://test',
        'display_name': 'Test',
        'participant_type': 'cyborg',
      };

      final member = GroupMemberInfo.fromJson(json);
      expect(member.participantType, ParticipantType.human);
    });
  });

  group('MemberRole', () {
    test('has three values', () {
      expect(MemberRole.values.length, 3);
      expect(MemberRole.values, contains(MemberRole.admin));
      expect(MemberRole.values, contains(MemberRole.member));
      expect(MemberRole.values, contains(MemberRole.observer));
    });
  });

  group('ParticipantType', () {
    test('has three values', () {
      expect(ParticipantType.values.length, 3);
      expect(ParticipantType.values, contains(ParticipantType.human));
      expect(ParticipantType.values, contains(ParticipantType.agent));
      expect(ParticipantType.values, contains(ParticipantType.service));
    });
  });

  group('groupMembersProvider', () {
    test('provider is accessible', () {
      expect(groupMembersProvider, isNotNull);
    });
  });

  group('Delete group (admin gating)', () {
    late _MockClient client;
    late _MockRepo repo;

    setUpAll(() {
      registerFallbackValue(_group('x'));
    });

    setUp(() {
      client = _MockClient();
      repo = _MockRepo();
      when(() => repo.save(any())).thenAnswer((_) async {});
      when(() => repo.delete(any())).thenAnswer((_) async {});
      when(() => client.deleteGroup(any())).thenAnswer((_) async {});
    });

    testWidgets('admin (creator) sees Delete group', (tester) async {
      // Local identity defaults to chef@skworld.io → admin member is "chef".
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'lumina@skworld.io',
            displayName: 'Lumina',
            role: MemberRole.member,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('delete-group-action')), findsOneWidget);
      expect(find.text('Delete group'), findsOneWidget);
    });

    testWidgets('non-admin does NOT see Delete group (only Leave)',
        (tester) async {
      // The operator (chef) is only a plain member here → no delete affordance.
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'lumina@skworld.io',
            displayName: 'Lumina',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.member,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('delete-group-action')), findsNothing);
      expect(find.text('Leave group'), findsOneWidget);
    });

    testWidgets('confirming Delete calls the API + navigates to Chats list',
        (tester) async {
      // Taller surface so the actions (Delete) sit on screen in the scroll view.
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('delete-group-action')));
      await tester.tap(find.byKey(const Key('delete-group-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-group-confirm')));
      await tester.pumpAndSettle();

      verify(() => client.deleteGroup('g-1')).called(1);
      expect(find.text('CHATS LIST'), findsOneWidget);
    });
  });

  group('Leave group (non-admin)', () {
    late _MockClient client;
    late _MockRepo repo;

    setUpAll(() {
      registerFallbackValue(_group('x'));
    });

    setUp(() {
      client = _MockClient();
      repo = _MockRepo();
      when(() => repo.save(any())).thenAnswer((_) async {});
      when(() => repo.delete(any())).thenAnswer((_) async {});
      when(() => client.leaveGroup(any())).thenAnswer((_) async {});
    });

    testWidgets('confirming Leave calls the API + navigates to Chats list',
        (tester) async {
      // Taller surface so the actions (Leave) sit on screen in the scroll
      // view, mirroring the Delete test above.
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // The operator (chef) is only a plain member here, so "Leave group" is
      // the offered destructive action (mirrors the Delete test above).
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'lumina@skworld.io',
            displayName: 'Lumina',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.member,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Leave group'));
      await tester.tap(find.text('Leave group'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();

      verify(() => client.leaveGroup('g-1')).called(1);
      expect(find.text('CHATS LIST'), findsOneWidget);
    });
  });

  group('Per-member trust badge (M1b)', () {
    late _MockClient client;
    late _MockRepo repo;

    setUp(() {
      client = _MockClient();
      repo = _MockRepo();
      when(() => repo.save(any())).thenAnswer((_) async {});
    });

    testWidgets('a member with a real capauth key shows a trust badge',
        (tester) async {
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'steward@skworld.io',
            displayName: 'Steward',
            role: MemberRole.member,
            soulFingerprint: '4E06A71935D1DF1FB9848112D8634AB3E7B55236',
          ),
        ],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
        ],
      ));
      await tester.pumpAndSettle();

      // Exactly one keyed member (Steward) → exactly one badge. Chef here has
      // no fingerprint, so no badge for him.
      expect(find.byType(TrustBadge), findsOneWidget);
    });

    testWidgets('a keyless member shows no badge', (tester) async {
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
        ],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.byType(TrustBadge), findsNothing);
    });
  });

  group('GroupMemberInfo guest fields (G6)', () {
    test('fromJson parses the guest keys', () {
      final member = GroupMemberInfo.fromJson({
        'identity_uri': 'guest://alice',
        'display_name': '',
        'guest': true,
        'guest_name': 'Alice',
        'guest_alias': 'Bestie',
        'guest_status': 'active',
        'membership_status': 'active',
      });

      expect(member.isGuest, true);
      expect(member.guestName, 'Alice');
      expect(member.guestAlias, 'Bestie');
      expect(member.guestStatus, 'active');
      expect(member.membershipStatus, 'active');
    });

    test('trusted member carries none of the guest keys', () {
      final member = GroupMemberInfo.fromJson({
        'identity_uri': 'chef@skworld.io',
        'display_name': 'Chef',
      });

      expect(member.isGuest, false);
      expect(member.guestName, isNull);
      expect(member.guestAlias, isNull);
      expect(member.title, 'Chef');
      expect(member.isUntrustedName, false);
      expect(member.isRevoked, false);
    });

    test('unaliased guest title is "guest: <name>" and untrusted', () {
      const member = GroupMemberInfo(
        identityUri: 'guest://alice',
        displayName: '',
        isGuest: true,
        guestName: 'Alice',
      );

      expect(member.title, 'guest: Alice');
      expect(member.isUntrustedName, true);
    });

    test('aliased guest title is the alias and is trusted styling', () {
      const member = GroupMemberInfo(
        identityUri: 'guest://alice',
        displayName: '',
        isGuest: true,
        guestName: 'Alice',
        guestAlias: 'Bestie',
      );

      expect(member.hasGuestAlias, true);
      expect(member.title, 'Bestie');
      expect(member.isUntrustedName, false);
    });

    test('a guest naming themselves after a real member does not collide',
        () {
      const trusted = GroupMemberInfo(
        identityUri: 'chef@skworld.io',
        displayName: 'Chef',
      );
      const spoofer = GroupMemberInfo(
        identityUri: 'guest://spoofer',
        displayName: '',
        isGuest: true,
        guestName: 'Chef',
      );

      expect(trusted.title, 'Chef');
      expect(spoofer.title, 'guest: Chef');
      expect(spoofer.title, isNot(trusted.title));
      expect(spoofer.isUntrustedName, true);
      expect(trusted.isUntrustedName, false);
    });

    test('revoked at either level reports isRevoked', () {
      const revokedPerson = GroupMemberInfo(
        identityUri: 'guest://alice',
        displayName: '',
        isGuest: true,
        guestName: 'Alice',
        guestStatus: 'revoked',
        membershipStatus: 'active',
      );
      const revokedSeat = GroupMemberInfo(
        identityUri: 'guest://bob',
        displayName: '',
        isGuest: true,
        guestName: 'Bob',
        guestStatus: 'active',
        membershipStatus: 'revoked',
      );

      expect(revokedPerson.isRevoked, true);
      expect(revokedSeat.isRevoked, true);
    });
  });

  group('_MemberTile guest rendering (G6)', () {
    late _MockClient client;
    late _MockRepo repo;

    setUp(() {
      client = _MockClient();
      repo = _MockRepo();
      when(() => repo.save(any())).thenAnswer((_) async {});
    });

    testWidgets('an unaliased guest renders "guest: Alice" with the Guest '
        'chip, styled untrusted', (tester) async {
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'guest://alice',
            displayName: '',
            role: MemberRole.member,
            isGuest: true,
            guestName: 'Alice',
          ),
        ],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('guest: Alice'), findsOneWidget);
      expect(find.text('Guest'), findsOneWidget);

      final text = tester.widget<Text>(find.text('guest: Alice'));
      expect(text.style?.color, SovereignColors.accentWarning);
      expect(text.style?.fontStyle, FontStyle.italic);
    });

    testWidgets('an aliased guest renders "Bestie" with the chip but '
        'trusted styling', (tester) async {
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'guest://alice',
            displayName: '',
            role: MemberRole.member,
            isGuest: true,
            guestName: 'Alice',
            guestAlias: 'Bestie',
          ),
        ],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Bestie'), findsOneWidget);
      // Still a guest, so the chip stays.
      expect(find.text('Guest'), findsOneWidget);
      expect(find.text('guest: Alice'), findsNothing);

      final text = tester.widget<Text>(find.text('Bestie'));
      expect(text.style?.fontStyle, FontStyle.normal);
    });

    testWidgets(
        'a guest naming themselves the same as a real member does not '
        'render identically', (tester) async {
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'guest://spoofer',
            displayName: '',
            role: MemberRole.member,
            isGuest: true,
            guestName: 'Chef',
          ),
        ],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
        ],
      ));
      await tester.pumpAndSettle();

      // The real Chef renders as "Chef"; the guest impersonator renders as
      // "guest: Chef" - never both as the bare "Chef" text.
      expect(find.text('Chef'), findsOneWidget);
      expect(find.text('guest: Chef'), findsOneWidget);
    });

    testWidgets('a revoked guest renders dimmed', (tester) async {
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'guest://alice',
            displayName: '',
            role: MemberRole.member,
            isGuest: true,
            guestName: 'Alice',
            guestStatus: 'revoked',
          ),
        ],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Revoked'), findsOneWidget);

      final opacityFinder = find.ancestor(
        of: find.text('guest: Alice'),
        matching: find.byType(Opacity),
      );
      expect(opacityFinder, findsWidgets);
      final opacity = tester.widget<Opacity>(opacityFinder.first);
      expect(opacity.opacity, 0.55);
    });

    testWidgets('a trusted member renders unchanged (no chip, no dimming)',
        (tester) async {
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [
          GroupMemberInfo(
            identityUri: 'chef@skworld.io',
            displayName: 'Chef',
            role: MemberRole.admin,
          ),
          GroupMemberInfo(
            identityUri: 'lumina@skworld.io',
            displayName: 'Lumina',
            role: MemberRole.member,
          ),
        ],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Chef'), findsOneWidget);
      expect(find.text('Lumina'), findsOneWidget);
      expect(find.text('Guest'), findsNothing);
      expect(find.text('Revoked'), findsNothing);

      final chefText = tester.widget<Text>(find.text('Chef'));
      expect(chefText.style?.fontStyle, isNot(FontStyle.italic));
    });
  });
}
