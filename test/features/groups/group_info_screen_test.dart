import 'dart:convert';

import 'package:dio/dio.dart';
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
import 'package:skchat/services/guest_dm_contacts_service.dart';
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

/// guest-dm G7: canned Dio adapter for GuestDmContactsService, wired into
/// _openGuestContactSheet's listContacts() + revoke calls. Mirrors the
/// pattern in test/services/guest_invite_service_test.dart.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.contacts = const []});
  final List<Map<String, dynamic>> contacts;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    requests.add(options);
    if (options.method == 'GET' &&
        options.path.endsWith('/guest-dm/contacts')) {
      return ResponseBody.fromString(
          jsonEncode({'contacts': contacts}), 200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          });
    }
    return ResponseBody.fromString(jsonEncode(const {}), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

/// A daemon that refuses every write, so the UI's failure path is exercised
/// rather than assumed.
class _FailingAdapter extends _RecordingAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    requests.add(options);
    throw DioException(requestOptions: options, message: 'daemon offline');
  }
}

Map<String, dynamic> _body(Object? data) => data is String
    ? jsonDecode(data) as Map<String, dynamic>
    : (data as Map).cast<String, dynamic>();

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
  // Seed a specific conversation (a promoted gdm, a room already on a
  // schedule) instead of the plain group most cases want.
  Conversation? group,
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
      groupsProvider
          .overrideWith(() => _FakeGroupsNotifier([group ?? _group(groupId)])),
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

  group('Per-member contact sheet (guest-dm G7)', () {
    late _MockClient client;
    late _MockRepo repo;

    setUp(() {
      client = _MockClient();
      repo = _MockRepo();
      when(() => repo.save(any())).thenAnswer((_) async {});
    });

    const guest = GroupMemberInfo(
      identityUri: 'guest://alice#FP-ALICE',
      displayName: '',
      role: MemberRole.member,
      isGuest: true,
      guestName: 'Alice',
    );
    const trusted = GroupMemberInfo(
      identityUri: 'chef@skworld.io',
      displayName: 'Chef',
      role: MemberRole.admin,
    );

    testWidgets('tapping a guest member row opens the C4 contact sheet',
        (tester) async {
      final adapter = _RecordingAdapter(contacts: const [
        {'fp': 'FP-ALICE', 'guest_name': 'Alice', 'group_id': 'g-1'},
      ]);
      final svc = GuestDmContactsService(
          dio: Dio()..httpClientAdapter = adapter,
          webuiBaseUrl: 'https://h.test');

      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [trusted, guest],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
          guestDmContactsServiceProvider.overrideWithValue(svc),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('guest: Alice'));
      await tester.pumpAndSettle();

      // The sheet is up, opened with a group context: alias field present
      // plus the per-group note and the scoped action.
      expect(find.text('Private alias'), findsOneWidget);
      expect(
          find.textContaining('apply to this person everywhere'),
          findsOneWidget);
      expect(find.text('Remove from this group'), findsOneWidget);

      // fp was derived from identity_uri the same way the server does.
      final getReq = adapter.requests
          .firstWhere((r) => r.path.endsWith('/guest-dm/contacts'));
      expect(getReq.method, 'GET');
    });

    testWidgets('long-pressing a guest member row also opens the sheet',
        (tester) async {
      final adapter = _RecordingAdapter();
      final svc = GuestDmContactsService(
          dio: Dio()..httpClientAdapter = adapter,
          webuiBaseUrl: 'https://h.test');

      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [trusted, guest],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
          guestDmContactsServiceProvider.overrideWithValue(svc),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('guest: Alice'));
      await tester.pumpAndSettle();

      expect(find.text('Private alias'), findsOneWidget);
    });

    testWidgets('tapping a trusted member row does NOT open the sheet',
        (tester) async {
      final adapter = _RecordingAdapter();
      final svc = GuestDmContactsService(
          dio: Dio()..httpClientAdapter = adapter,
          webuiBaseUrl: 'https://h.test');

      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [trusted, guest],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
          guestDmContactsServiceProvider.overrideWithValue(svc),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chef'));
      await tester.pumpAndSettle();

      expect(find.text('Private alias'), findsNothing);
      expect(adapter.requests, isEmpty);
    });

    testWidgets(
        'a successful per-group revoke refreshes the roster immediately '
        '(no waiting on a poll)', (tester) async {
      final adapter = _RecordingAdapter(contacts: const [
        {'fp': 'FP-ALICE', 'guest_name': 'Alice', 'group_id': 'g-1'},
      ]);
      final svc = GuestDmContactsService(
          dio: Dio()..httpClientAdapter = adapter,
          webuiBaseUrl: 'https://h.test');

      var rebuilds = 0;
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: const [trusted, guest],
        extraOverrides: [
          peerTrustResolverProvider
              .overrideWithValue(PeerTrustResolver(_MemTrustStore())),
          guestDmContactsServiceProvider.overrideWithValue(svc),
          groupMembersProvider('g-1').overrideWith((ref) async {
            rebuilds++;
            return const [trusted, guest];
          }),
        ],
      ));
      await tester.pumpAndSettle();
      final rebuildsAfterLoad = rebuilds;

      await tester.tap(find.text('guest: Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from this group'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      // ref.invalidate(groupMembersProvider(groupId)) reruns the override,
      // proving the roster was refreshed on the spot rather than left stale
      // until the next poll.
      expect(rebuilds, greaterThan(rebuildsAfterLoad));

      final postReq = adapter.requests.firstWhere((r) => r.method == 'POST');
      expect(postReq.uri.path, '/api/v1/guest-dm/contacts/FP-ALICE/revoke');
      expect(_body(postReq.data)['group_id'], 'g-1');
    });
  });

  // guest-dm: the whole-room expiry control. The server has enforced
  // `expires_at` since S3 and the writer route landed with the G7 follow-up,
  // but nothing in the app ever called it, so a schedule was settable over HTTP
  // and nowhere else. These pin the surface that closes that gap.
  group('room access expiry (gdm)', () {
    late _MockClient client;
    late _MockRepo repo;

    setUp(() {
      client = _MockClient();
      repo = _MockRepo();
      when(() => repo.save(any())).thenAnswer((_) async {});
    });

    Conversation gdm({double? expiresAt}) => Conversation(
          peerId: 'g-1',
          displayName: 'Ops room',
          lastMessage: '',
          lastMessageTime: DateTime(2026),
          isGroup: true,
          memberCount: 3,
          mode: 'gdm',
          isGuestDm: true,
          expiresAt: expiresAt,
        );

    const roster = [
      GroupMemberInfo(
        identityUri: 'chef@skworld.io',
        displayName: 'Chef',
        role: MemberRole.admin,
      ),
    ];

    Widget wrap(Conversation conv, _RecordingAdapter adapter) => _wrapInfo(
          client: client,
          repo: repo,
          members: roster,
          group: conv,
          extraOverrides: [
            guestDmContactsServiceProvider.overrideWithValue(
              GuestDmContactsService(
                dio: Dio()..httpClientAdapter = adapter,
                webuiBaseUrl: 'https://h.test',
              ),
            ),
          ],
        );

    testWidgets('a promoted guest room offers the expiry control',
        (tester) async {
      await tester.pumpWidget(wrap(gdm(), _RecordingAdapter()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('group-expiry-action')), findsOneWidget);
      expect(find.text('No expiry - this room stays open'), findsOneWidget);
    });

    testWidgets('an ordinary group does NOT offer it', (tester) async {
      // The server refuses `expires_at` on a non-dm-family group (the
      // chokepoint would never read it), so offering the control here would be
      // a button that always errors.
      await tester.pumpWidget(_wrapInfo(
        client: client,
        repo: repo,
        members: roster,
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('group-expiry-action')), findsNothing);
    });

    testWidgets('a room already on a schedule reads its expiry back',
        (tester) async {
      final at = DateTime.now().add(const Duration(days: 7));
      await tester.pumpWidget(wrap(
        gdm(expiresAt: at.millisecondsSinceEpoch / 1000),
        _RecordingAdapter(),
      ));
      await tester.pumpAndSettle();

      // A write-only control is untrustworthy: what is set must be visible.
      expect(find.textContaining('Expires in '), findsOneWidget);
    });

    testWidgets('a room whose schedule already ran out says so', (tester) async {
      final at = DateTime.now().subtract(const Duration(days: 1));
      await tester.pumpWidget(wrap(
        gdm(expiresAt: at.millisecondsSinceEpoch / 1000),
        _RecordingAdapter(),
      ));
      await tester.pumpAndSettle();

      // Not a countdown that quietly went negative.
      expect(find.text('Expired - guests are locked out'), findsOneWidget);
    });

    testWidgets('picking a window PATCHes the group route with a seconds TTL',
        (tester) async {
      final adapter = _RecordingAdapter();
      await tester.pumpWidget(wrap(gdm(), adapter));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('group-expiry-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In 7 days'));
      await tester.pumpAndSettle();

      final req = adapter.requests.firstWhere((r) => r.method == 'PATCH');
      expect(req.uri.path, '/api/v1/guest-dm/groups/g-1');
      expect(_body(req.data)['group_ttl'], 7 * 86400);
      expect(find.textContaining('lose access to this room in 7 days'),
          findsOneWidget);
    });

    testWidgets('"No expiry" clears the schedule with an explicit null',
        (tester) async {
      final adapter = _RecordingAdapter();
      await tester.pumpWidget(wrap(
        gdm(expiresAt:
            DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch /
                1000),
        adapter,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('group-expiry-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No expiry'));
      await tester.pumpAndSettle();

      final req = adapter.requests.firstWhere((r) => r.method == 'PATCH');
      final body = _body(req.data);
      expect(body.containsKey('expires_at'), isTrue);
      expect(body['expires_at'], isNull);
      expect(find.textContaining('Room expiry cleared'), findsOneWidget);
    });

    testWidgets('a failed write says nothing changed, never claims success',
        (tester) async {
      final adapter = _FailingAdapter();
      await tester.pumpWidget(wrap(gdm(), adapter));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('group-expiry-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In 1 day'));
      await tester.pumpAndSettle();

      // Believing a room is timed out when it is not is the failure that
      // actually costs something here.
      expect(find.textContaining('Could not update the room expiry'),
          findsOneWidget);
      expect(find.textContaining('lose access'), findsNothing);
    });
  });
}
