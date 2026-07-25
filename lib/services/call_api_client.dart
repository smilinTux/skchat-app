import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_config.dart';
import 'operator_token.dart' as op_token;

/// Result of POST /call/start or /call/answer: the server-derived room plus a
/// minted LiveKit token for THIS caller/callee and the SFU ws URL to join.
class CallStartResult {
  const CallStartResult({
    required this.room,
    required this.token,
    required this.livekitUrl,
    required this.peerFqid,
    required this.identity,
  });

  final String room;
  final String token;
  final String livekitUrl;
  final String peerFqid;
  final String identity;

  factory CallStartResult.fromJson(Map<String, dynamic> j) => CallStartResult(
        room: j['room'] as String? ?? '',
        token: j['token'] as String? ?? '',
        livekitUrl: j['livekit_url'] as String? ?? '',
        peerFqid: j['peer_fqid'] as String? ?? '',
        identity: j['identity'] as String? ?? '',
      );
}

/// One signed, server-verified incoming CALL_INVITE addressed to self.
class CallInvite {
  const CallInvite({
    required this.fromFqid,
    required this.room,
    required this.livekitUrl,
    required this.topic,
    required this.ts,
    required this.nonce,
  });

  final String fromFqid;
  final String room;
  final String livekitUrl;
  final String topic;
  final int ts;
  final String nonce;

  factory CallInvite.fromJson(Map<String, dynamic> j) => CallInvite(
        fromFqid: j['from_fqid'] as String? ?? '',
        room: j['room'] as String? ?? '',
        livekitUrl: j['livekit_url'] as String? ?? '',
        topic: j['topic'] as String? ?? '',
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        nonce: j['nonce'] as String? ?? '',
      );
}

/// Interface so tests inject a fake instead of the real transport.
abstract class CallApi {
  Future<CallStartResult> startCall(String peer);
  Future<CallStartResult> answerCall(String peer);
  Future<List<CallInvite>> pollIncoming();
}

/// Thin client over the skchat web-UI /call/* routes (the same origin that
/// serves POST /livekit/token). Rings via the server's signed CALL_INVITE.
class CallApiClient implements CallApi {
  CallApiClient({required String baseUrl, Dio? dio, String? Function()? tokenReader})
      : _base = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _dio = dio ?? Dio(),
        _readToken = tokenReader ?? op_token.operatorToken;

  final String _base;
  final Dio _dio;

  /// Reads the manually-pasted operator token (SKCHAT_GUEST_OPERATOR_TOKEN,
  /// stored in web localStorage via the Link-this-device flow). The /call/*
  /// routes are operator-gated by `_gate_token_mint`: when the server has an
  /// operator token configured, every call request MUST present it as the
  /// `X-Operator-Token` header (network position alone is not enough), exactly
  /// as mode_c_service and guest_group_service already do. A null/empty token
  /// (e.g. native, or not-yet-linked) simply omits the header.
  final String? Function() _readToken;

  Options _opts() {
    final headers = <String, dynamic>{'Content-Type': 'application/json'};
    final tok = _readToken();
    if (tok != null && tok.isNotEmpty) {
      headers['X-Operator-Token'] = tok;
    }
    return Options(headers: headers);
  }

  @override
  Future<CallStartResult> startCall(String peer) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '$_base/call/start',
      data: {'peer': peer},
      options: _opts(),
    );
    return CallStartResult.fromJson(resp.data ?? {});
  }

  @override
  Future<CallStartResult> answerCall(String peer) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      '$_base/call/answer',
      data: {'peer': peer},
      options: _opts(),
    );
    return CallStartResult.fromJson(resp.data ?? {});
  }

  @override
  Future<List<CallInvite>> pollIncoming() async {
    final resp = await _dio.get<Map<String, dynamic>>(
      '$_base/call/incoming',
      options: _opts(),
    );
    final list = (resp.data?['invites'] as List<dynamic>?) ?? const [];
    return list
        .map((e) => CallInvite.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final callApiProvider = Provider<CallApi>(
  (ref) => CallApiClient(baseUrl: ref.watch(backendConfigProvider).skchatWebuiUrl),
);
