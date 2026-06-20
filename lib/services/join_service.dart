import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "spaces_service.dart" show kDefaultWebuiUrl;

// ── Deep-link parsing ───────────────────────────────────────────────────────

/// A parsed conference JOIN link / route.
///
/// Mirrors the web `join.html` flow: a shared link carries the room plus
/// either a guest `invite` token or a `sovereign=1` flag. The app opens this
/// straight into the [JoinScreen] chooser (or auto-selects when only one path
/// is viable).
///
/// Accepted shapes (query params on any path, e.g. `/join` or a custom
/// `skchat://join` scheme):
///   /join?room=town-hall&invite=ABC123          -> guest path available
///   /join?room=town-hall&sovereign=1            -> sovereign path
///   /join?room=town-hall&invite=ABC&sovereign=1 -> both offered
class JoinLink {
  const JoinLink({
    required this.room,
    this.inviteToken,
    this.sovereign = false,
    this.displayName,
  });

  /// Conference room / space id to join.
  final String room;

  /// Guest invite token (present when a guest path is offered).
  final String? inviteToken;

  /// Whether the sovereign (capauth-signed) path is offered.
  final bool sovereign;

  /// Optional pre-filled display name from the link.
  final String? displayName;

  /// True when a guest join is possible (an invite token is present).
  bool get hasGuest => (inviteToken ?? "").isNotEmpty;

  /// Parse a raw link/route string. Returns null when it is not a valid join
  /// link (no `room`, or neither guest nor sovereign path is offered).
  static JoinLink? tryParse(String raw) {
    Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } catch (_) {
      return null;
    }
    return fromParams(uri.queryParameters);
  }

  /// Build from an already-parsed query-parameter map (GoRouter supplies this
  /// via `state.uri.queryParameters`).
  static JoinLink? fromParams(Map<String, String> q) {
    final room = (q["room"] ?? q["space"] ?? "").trim();
    if (room.isEmpty) return null;

    final invite = (q["invite"] ?? q["invite_token"] ?? "").trim();
    final sovereign = _truthy(q["sovereign"]);

    // Must offer at least one join path.
    if (invite.isEmpty && !sovereign) return null;

    return JoinLink(
      room: room,
      inviteToken: invite.isEmpty ? null : invite,
      sovereign: sovereign,
      displayName: (q["name"] ?? q["display_name"])?.trim(),
    );
  }

  static bool _truthy(String? v) {
    if (v == null) return false;
    final s = v.toLowerCase();
    return s == "1" || s == "true" || s == "yes";
  }
}

// ── Join result ─────────────────────────────────────────────────────────────

/// Normalized result of a guest or sovereign join: a LiveKit token + ws url
/// the call layer ([LiveKitCallService.connectWithToken]) can use directly.
class ConfJoin {
  const ConfJoin({
    required this.token,
    required this.lkUrl,
    required this.room,
    required this.identity,
    this.role,
    this.spaceId,
  });

  /// LiveKit JWT for the room connection.
  final String token;

  /// LiveKit WebSocket URL.
  final String lkUrl;

  /// Joined room name.
  final String room;

  /// Identity granted for this join.
  final String identity;

  /// Role (sovereign path only): host / speaker / listener.
  final String? role;

  /// Space id (sovereign path only).
  final String? spaceId;

  /// Guest response: {lk_token, lk_url, room, identity}.
  factory ConfJoin.fromGuestJson(Map<String, dynamic> j) => ConfJoin(
        token: j["lk_token"] as String? ?? j["token"] as String? ?? "",
        lkUrl: j["lk_url"] as String? ?? j["url"] as String? ?? "",
        room: j["room"] as String? ?? "",
        identity: j["identity"] as String? ?? "",
      );

  /// Sovereign response:
  /// {token, space_id, identity, role, conf_ws_url}.
  factory ConfJoin.fromSovereignJson(Map<String, dynamic> j) => ConfJoin(
        token: j["token"] as String? ?? "",
        lkUrl: j["conf_ws_url"] as String? ??
            j["lk_url"] as String? ??
            j["url"] as String? ??
            "",
        room: j["room"] as String? ?? j["space_id"] as String? ?? "",
        identity: j["identity"] as String? ?? "",
        role: j["role"] as String?,
        spaceId: j["space_id"] as String?,
      );
}

// ── Signer abstraction ──────────────────────────────────────────────────────

/// Produces the capauth-signed sovereign assertion `{claim, sig}` locally.
///
/// Implemented over the app's existing PGP identity (see
/// [PgpCapAuthSigner]); abstracted so the join flow can be unit-tested with a
/// fake signer (no key material / isolates required).
abstract class SovereignSigner {
  /// Sign [claim] (a canonical JSON string) and return the base64 signature.
  Future<String> sign(String claim);
}

// ── Service ─────────────────────────────────────────────────────────────────

/// Drives the two conference join paths exposed by the skchat web-UI:
///
/// - **Guest:**  POST `/guest/join`     {room, invite_token, display_name}
///               -> {lk_token, lk_url, room, identity}
/// - **Sovereign:** POST `/join/sovereign` {claim, sig}
///               -> {token, space_id, identity, role, conf_ws_url}
///
/// The base URL is the SAME configurable web-UI base used by [SpacesService]
/// ([kDefaultWebuiUrl] / `--dart-define=SKCHAT_WEBUI_URL=...`); it is never
/// hardcoded here.
class JoinService {
  JoinService({Dio? dio, String? webuiBaseUrl})
      : _dio = dio ?? Dio(),
        _base = webuiBaseUrl ?? kDefaultWebuiUrl;

  final Dio _dio;
  final String _base;

  /// Guest join: exchange an invite token for a LiveKit token.
  Future<ConfJoin> joinGuest({
    required String room,
    required String inviteToken,
    required String displayName,
  }) async {
    final data = await _post("/guest/join", {
      "room": room,
      "invite_token": inviteToken,
      "display_name": displayName,
    });
    return ConfJoin.fromGuestJson(data);
  }

  /// Sovereign join: build a capauth-signed `{claim, sig}` locally via
  /// [signer], POST it, and return the role-scoped LiveKit token.
  ///
  /// The claim is a canonical JSON assertion binding the signer's [identity]
  /// to the [room] at a fresh timestamp (replay window enforced server-side).
  Future<ConfJoin> joinSovereign({
    required String room,
    required String identity,
    required SovereignSigner signer,
    DateTime? issuedAt,
  }) async {
    final claim = buildSovereignClaim(
      room: room,
      identity: identity,
      issuedAt: issuedAt ?? DateTime.now().toUtc(),
    );
    final sig = await signer.sign(claim);
    final data = await _post("/join/sovereign", {"claim": claim, "sig": sig});
    return ConfJoin.fromSovereignJson(data);
  }

  /// Canonical JSON claim string that gets signed and re-verified server-side.
  ///
  /// Stable key order (alphabetical) so the bytes the client signs match what
  /// the server canonicalizes before verifying the signature.
  static String buildSovereignClaim({
    required String room,
    required String identity,
    required DateTime issuedAt,
  }) {
    return jsonEncode({
      "identity": identity,
      "iss": issuedAt.toUtc().toIso8601String(),
      "purpose": "conf-join",
      "room": room,
    });
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final r = await _dio.post<Map<String, dynamic>>(
      "$_base$path",
      data: body,
      options: Options(headers: {"Content-Type": "application/json"}),
    );
    return r.data ?? const {};
  }
}

final joinServiceProvider = Provider<JoinService>((ref) => JoinService());
