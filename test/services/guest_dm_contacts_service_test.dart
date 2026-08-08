import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_dm_contacts_service.dart";

class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  /// What the daemon answers with. Defaults to an empty object; set it when the
  /// test cares about what the caller reads back off the response.
  Map<String, dynamic> body = const {};

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

Map<String, dynamic> _decode(Object? data) {
  if (data is String) return jsonDecode(data) as Map<String, dynamic>;
  if (data is Map) return data.cast<String, dynamic>();
  return const {};
}

GuestDmContactsService _service(_RecordingAdapter a) => GuestDmContactsService(
    dio: Dio()..httpClientAdapter = a, webuiBaseUrl: "https://h.test");

void main() {
  test("revoke (person-level) POSTs the bare revoke route with no body",
      () async {
    final a = _RecordingAdapter();
    final svc = _service(a);

    await svc.revoke("FP1");

    final req = a.requests.single;
    expect(req.method, "POST");
    expect(req.uri.path, "/api/v1/guest-dm/contacts/FP1/revoke");
    expect(_decode(req.data), isEmpty);
  });

  test(
      "revokeGroupMembership (guest-dm G7) POSTs the SAME route with a "
      "group_id body", () async {
    final a = _RecordingAdapter();
    final svc = _service(a);

    await svc.revokeGroupMembership("FP1", "g-42");

    final req = a.requests.single;
    expect(req.method, "POST");
    expect(req.uri.path, "/api/v1/guest-dm/contacts/FP1/revoke");
    expect(_decode(req.data)["group_id"], "g-42");
  });

  test("setGroupExpiry PATCHes the GROUP route with a seconds TTL", () async {
    final a = _RecordingAdapter();
    final svc = _service(a);

    await svc.setGroupExpiry("g-42", groupTtl: 7 * 86400);

    final req = a.requests.single;
    expect(req.method, "PATCH");
    // The GROUP route, not the contact route: this closes the room to
    // everyone, it does not expire one person everywhere.
    expect(req.uri.path, "/api/v1/guest-dm/groups/g-42");
    expect(_decode(req.data)["group_ttl"], 7 * 86400);
    expect(_decode(req.data).containsKey("contact_ttl"), isFalse);
  });

  test("setGroupExpiry returns the absolute expiry the SERVER stored", () async {
    final a = _RecordingAdapter()..body = const {"ok": true, "expires_at": 1234.5};
    final svc = _service(a);

    // Not the TTL we sent back at us: the caller renders what was stored.
    expect(await svc.setGroupExpiry("g-42", groupTtl: 60), 1234.5);
  });

  test("clearGroupExpiry sends an explicit null so the field is REMOVED",
      () async {
    final a = _RecordingAdapter();
    final svc = _service(a);

    await svc.clearGroupExpiry("g-42");

    final req = a.requests.single;
    expect(req.method, "PATCH");
    expect(req.uri.path, "/api/v1/guest-dm/groups/g-42");
    // A far-future TTL (the per-contact workaround, whose route has no clear)
    // would leave the room expiring one day. The group route takes null, so
    // "no expiry" here really means unset.
    final body = _decode(req.data);
    expect(body.containsKey("expires_at"), isTrue);
    expect(body["expires_at"], isNull);
    expect(body.containsKey("group_ttl"), isFalse);
  });
}
