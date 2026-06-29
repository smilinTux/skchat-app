import "package:dio/dio.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "daemon_config.dart";

/// One quarantined first-contact request (skfed-consent-design gate 5).
///
/// Mirrors the dict returned by `skcomms.consent_requests.list_requests`:
/// `{"sender", "envelope_id", "received_at"}`. All fields default to the empty
/// string so a partial / older daemon payload never throws.
class ContactRequest {
  const ContactRequest({
    required this.sender,
    this.envelopeId = "",
    this.receivedAt = "",
  });

  /// The sender FQID that knocked (e.g. `stranger@dk.skworld`).
  final String sender;

  /// The quarantined envelope id (opaque; used by the daemon, not the UI).
  final String envelopeId;

  /// ISO-8601 timestamp of when the knock was received.
  final String receivedAt;

  factory ContactRequest.fromJson(Map<String, dynamic> json) {
    return ContactRequest(
      sender: (json["sender"] ?? json["from_fqid"] ?? "") as String,
      envelopeId: (json["envelope_id"] ?? json["envelope"] ?? "") as String,
      receivedAt:
          (json["received_at"] ?? json["ts"] ?? json["created_at"] ?? "")
              as String,
    );
  }
}

/// Client for the SKComms **operator consent surface** (gate 5).
///
/// Wraps the loopback-gated consent endpoints on the SKComms daemon
/// (`:9384`): list / accept / decline / block / unblock / known. Because those
/// endpoints mutate the node's OWN consent state they are local/operator-only —
/// the daemon rejects any non-loopback caller (HTTP 403) unless
/// `SKCOMMS_DEV_AUTH` is set. The app reaches them via the same daemon origin
/// the rest of the app uses ([daemonUrlProvider]); on a native build that is
/// `http://localhost:9384` (true loopback), and on the web build it is the
/// host the app was served from, which the webui reverse-proxies to the daemon
/// over loopback. The recipient agent is resolved daemon-side (the node's
/// SKAGENT / self identity) — the client never passes an agent.
///
/// Additive + opt-in: the consent GATE itself stays OFF until
/// `SKCOMMS_CONSENT_MODE` is set on the daemon, in which case
/// [listRequests] simply returns an empty queue. This surface is safe to ship
/// dark — it shows "no requests" until consent mode is enabled.
class ConsentService {
  /// [dio] may be injected (tests) to supply a canned [HttpClientAdapter];
  /// its [BaseOptions.baseUrl] is set from [baseUrl] when both are provided —
  /// matching [SKCommsClient]'s constructor contract.
  ConsentService({String? baseUrl, Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? kDefaultDaemonUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 10),
                headers: {"Content-Type": "application/json"},
              ),
            ) {
    if (dio != null && baseUrl != null) {
      _dio.options.baseUrl = baseUrl;
    }
  }

  final Dio _dio;

  // ── Read ───────────────────────────────────────────────────────────────────

  /// GET /api/v1/consent/requests — list pending first-contact knocks.
  ///
  /// Tolerates either the `{agent, requests:[...]}` envelope or a bare list,
  /// and returns the oldest-first queue (empty when consent mode is off).
  Future<List<ContactRequest>> listRequests() async {
    final resp = await _dio.get<dynamic>("/api/v1/consent/requests");
    final raw = _listField(resp.data, "requests");
    return raw
        .whereType<Map>()
        .map((e) => ContactRequest.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// GET /api/v1/consent/known — list the accepted-contact roster (FQIDs).
  Future<List<String>> listKnown() async {
    final resp = await _dio.get<dynamic>("/api/v1/consent/known");
    return _listField(resp.data, "known")
        .map((e) => e.toString())
        .toList();
  }

  // ── Mutations ───────────────────────────────────────────────────────────────

  /// POST /api/v1/consent/accept — promote [sender] to known + mint its
  /// per-contact delivery token. Returns the minted token (or `null` if the
  /// daemon did not return one).
  Future<String?> accept(String sender) async {
    final resp = await _dio.post<dynamic>(
      "/api/v1/consent/accept",
      data: {"sender": sender},
    );
    final data = resp.data;
    if (data is Map) return data["token"] as String?;
    return null;
  }

  /// POST /api/v1/consent/decline — clear [sender]'s queued knock. When
  /// [block] is true the sender is also blocked (gate 5 → DROP); otherwise it
  /// returns to UNKNOWN.
  Future<void> decline(String sender, {bool block = false}) async {
    await _dio.post<dynamic>(
      "/api/v1/consent/decline",
      data: {"sender": sender, "block": block},
    );
  }

  /// POST /api/v1/consent/block — block [sender] outright.
  Future<void> block(String sender) async {
    await _dio.post<dynamic>(
      "/api/v1/consent/block",
      data: {"sender": sender},
    );
  }

  /// POST /api/v1/consent/unblock — lift a block on [sender] (→ UNKNOWN).
  Future<void> unblock(String sender) async {
    await _dio.post<dynamic>(
      "/api/v1/consent/unblock",
      data: {"sender": sender},
    );
  }

  /// Pull a list from either a `{key: [...]}` envelope or a bare top-level
  /// list, returning an empty list for any other shape.
  static List<dynamic> _listField(dynamic data, String key) {
    if (data is Map) {
      final v = data[key];
      if (v is List) return v;
      return const [];
    }
    if (data is List) return data;
    return const [];
  }
}

// ── Riverpod providers ────────────────────────────────────────────────────────

/// ConsentService bound to the runtime-configurable daemon URL.
///
/// Watching [daemonUrlProvider] means changing the daemon URL in settings
/// rebuilds this client so consent calls hit the new host.
final consentServiceProvider = Provider<ConsentService>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  return ConsentService(baseUrl: baseUrl);
});

/// Pending first-contact requests (GET /api/v1/consent/requests).
///
/// `autoDispose` so it re-fetches each time the Requests screen / Hub badge is
/// mounted; surfaces errors as an [AsyncError] for the offline state.
final consentRequestsProvider =
    FutureProvider.autoDispose<List<ContactRequest>>((ref) async {
  final svc = ref.watch(consentServiceProvider);
  return svc.listRequests();
});

/// Count of pending requests for the nav badge — 0 while loading / on error /
/// when consent mode is off (empty queue).
final consentPendingCountProvider = Provider.autoDispose<int>((ref) {
  return ref.watch(consentRequestsProvider).maybeWhen(
        data: (reqs) => reqs.length,
        orElse: () => 0,
      );
});
