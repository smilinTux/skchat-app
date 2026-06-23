import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/skcomms_client.dart';

/// Canned-response adapter that resolves by path and records the last request,
/// so we can assert the exact POST body the groups flow builds.
class _CannedAdapter implements HttpClientAdapter {
  final Map<String, Object?> routes = {};
  final Map<String, int> statusCodes = {};
  RequestOptions? lastRequest;
  String? lastBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      lastBody = utf8.decode(chunks.expand((c) => c).toList());
    } else if (options.data != null) {
      lastBody = jsonEncode(options.data);
    }
    final path = options.uri.path;
    final body = routes[path] ?? routes[Uri.decodeFull(path)] ?? {};
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      statusCodes[path] ?? 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

SKCommsClient _client(_CannedAdapter a) {
  final dio = Dio()..httpClientAdapter = a;
  return SKCommsClient(baseUrl: 'http://test.local:9384', dio: dio);
}

void main() {
  group('createGroup', () {
    test('builds POST /api/v1/groups with name + members + description', () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/groups'] = {
        'group_id': 'g-123',
        'name': 'Penguins',
        'description': 'the kingdom',
        'member_count': 3,
        'key_algorithm': 'AES-256-GCM',
        'members': [
          {'identity': 'lumina'},
          {'identity': 'jarvis'},
        ],
      };

      final res = await _client(a).createGroup(
        name: 'Penguins',
        description: 'the kingdom',
        memberUris: ['lumina', 'jarvis'],
      );

      // The request body is the contract the backend reads.
      final sent = jsonDecode(a.lastBody!) as Map<String, dynamic>;
      expect(a.lastRequest!.method, 'POST');
      expect(a.lastRequest!.uri.path, '/api/v1/groups');
      expect(sent['name'], 'Penguins');
      expect(sent['description'], 'the kingdom');
      expect(sent['members'], [
        {'identity': 'lumina'},
        {'identity': 'jarvis'},
      ]);

      // The parsed result carries the group id + member count + key info.
      expect(res.groupId, 'g-123');
      expect(res.name, 'Penguins');
      expect(res.memberCount, 3);
      expect(res.keyAlgorithm, 'AES-256-GCM');
      expect(res.members, ['lumina', 'jarvis']);
    });

    test('omits members/description when empty', () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/groups'] = {'group_id': 'g-1', 'name': 'Solo'};
      await _client(a).createGroup(name: 'Solo');
      final sent = jsonDecode(a.lastBody!) as Map<String, dynamic>;
      expect(sent.containsKey('members'), isFalse);
      expect(sent.containsKey('description'), isFalse);
      expect(sent['name'], 'Solo');
    });
  });

  group('getGroupMembers', () {
    test('parses the member contract (identity_uri/role/participant_type)',
        () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/groups/g-123/members'] = [
        {
          'identity_uri': 'chef@skworld.io',
          'display_name': 'Chef',
          'role': 'admin',
          'participant_type': 'human',
          'is_online': true,
        },
        {
          'identity_uri': 'lumina',
          'display_name': 'Lumina',
          'role': 'member',
          'participant_type': 'agent',
          'is_online': false,
        },
      ];

      final members = await _client(a).getGroupMembers('g-123');
      expect(members, hasLength(2));
      expect(members[0]['role'], 'admin');
      expect(members[1]['participant_type'], 'agent');
    });
  });

  group('addGroupMember (also the promote-1:1 trigger)', () {
    test('POSTs identity + role to /groups/{id}/members', () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/groups/jarvis/members'] = {'ok': true, 'promoted': true};
      await _client(a).addGroupMember('jarvis', identity: 'lumina');
      final sent = jsonDecode(a.lastBody!) as Map<String, dynamic>;
      expect(a.lastRequest!.uri.path, '/api/v1/groups/jarvis/members');
      expect(sent['identity'], 'lumina');
      expect(sent['role'], 'member');
    });
  });

  group('group conversation thread', () {
    test('getConversationFull returns the group thread message contract',
        () async {
      final a = _CannedAdapter();
      a.routes['/api/v1/conversations/g-123'] = [
        {
          'id': 'm1',
          'conversation_id': 'g-123',
          'sender': 'chef@skworld.io',
          'content': 'standup time',
          'body': 'standup time',
          'ts': '2026-06-23T10:00:00.000Z',
          'is_outbound': true,
          'is_agent': false,
          'sender_name': 'You',
        },
      ];
      final rows = await _client(a).getConversationFull('g-123');
      expect(rows, hasLength(1));
      expect(rows[0]['content'], 'standup time');
      expect(rows[0]['conversation_id'], 'g-123');
    });
  });
}
