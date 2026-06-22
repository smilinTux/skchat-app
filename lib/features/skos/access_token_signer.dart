import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/daemon_config.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// AccessTokenSigner — mints the capauth token for a single sk-access call.
/// ─────────────────────────────────────────────────────────────────────────
///
/// **Why this lives in the daemon, not the app:** the sk-access gate (P7)
/// verifies an *OpenPGP detached signature* over the canonical Envelope-v1
/// bytes (`skcomms.federation.accept_signed` → `pgpy`). The app's in-app crypto
/// ([PgpBridge]) is RSA/PKCS#1-v1.5 + SHA-256 producing a *raw base64*
/// signature — NOT an OpenPGP packet — so it can never produce a byte-compatible
/// token. The local SKComms daemon, however, already holds this node's CapAuth
/// PGP key and can build the exact `SignedEnvelope` a node accepts.
///
/// So the app asks the daemon to mint the token (`POST /api/v1/access/token`),
/// then forwards `{token, tool, arguments}` straight to the target node's
/// sk-access `/tool` over the tailnet (see DaemonAccessClient). The private key
/// never leaves the daemon; the app only ever handles the signed, public token.
class AccessTokenSigner {
  AccessTokenSigner({required this.daemonBaseUrl, Dio? dio})
      : _dio = dio ?? Dio();

  /// Base URL of the local SKComms daemon (e.g. `http://localhost:9384`).
  final String daemonBaseUrl;

  final Dio _dio;

  /// Mint a capauth `SignedEnvelope` (as a JSON string) authorizing one
  /// `{node, tool, arguments}` sk-access call. Drop the result into the
  /// `"token"` field of the node's `POST /tool` body.
  ///
  /// Throws a [StateError] when the daemon can't sign (no CapAuth key → HTTP
  /// 503) or is unreachable, so the surface can surface a clear failure rather
  /// than POSTing an empty token the node will 401.
  Future<String> tokenForCall(
    String node,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '${_normalized(daemonBaseUrl)}/api/v1/access/token',
        data: {'node': node, 'tool': tool, 'arguments': arguments},
        options: Options(contentType: 'application/json'),
      );
      final token = (resp.data ?? const {})['token'] as String?;
      if (token == null || token.isEmpty) {
        throw StateError('daemon returned an empty access token');
      }
      return token;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final detail = e.response?.data is Map
          ? (e.response!.data as Map)['detail']
          : e.message;
      if (code == 503) {
        throw StateError(
          'No CapAuth signing key on the daemon — cannot mint an access token '
          '($detail)',
        );
      }
      throw StateError('Failed to mint access token (HTTP $code): $detail');
    }
  }

  static String _normalized(String url) {
    var s = url.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// The daemon-backed access-token signer, repointed automatically whenever the
/// daemon URL changes (same source the rest of the app's daemon clients use).
final accessTokenSignerProvider = Provider<AccessTokenSigner>((ref) {
  final base = ref.watch(daemonUrlProvider);
  return AccessTokenSigner(daemonBaseUrl: base);
});
