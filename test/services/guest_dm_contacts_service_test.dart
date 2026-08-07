import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_dm_contacts_service.dart";

class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(const {}), 200, headers: {
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
}
