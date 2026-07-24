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
}
