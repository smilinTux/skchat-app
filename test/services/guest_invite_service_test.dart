import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_group_service.dart";

class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);
  final Map<String, Object?> routes;
  RequestOptions? last;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    last = options;
    final body = routes[options.path] ?? routes[options.uri.path] ?? {};
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}


/// dio hands the adapter the raw request body (a Map when posting JSON), so
/// normalise to a Map for assertions whether it arrives as a Map or a String.
Map<String, dynamic> _decode(Object? data) {
  if (data is String) return jsonDecode(data) as Map<String, dynamic>;
  if (data is Map) return data.cast<String, dynamic>();
  return const {};
}

void main() {
  test("createInvite posts to the operator route and fullLink prefixes base",
      () async {
    final adapter = _CannedAdapter({
      "/api/v1/groups/g1/invite": {
        "token": "INV-TOKEN",
        "join_url": "/join/INV-TOKEN",
        "group_id": "g1",
      },
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final svc = GuestInviteService(dio: dio, webuiBaseUrl: "https://h.test");

    final res = await svc.createInvite(groupId: "g1", singleUse: true);
    expect(res["token"], "INV-TOKEN");
    final body = _decode(adapter.last!.data);
    expect(body["single_use"], true);

    // The relative join_url is turned into a full shareable link.
    expect(svc.fullLink(res["join_url"] as String),
        "https://h.test/join/INV-TOKEN");
  });
}
