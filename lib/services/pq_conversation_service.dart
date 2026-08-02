import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pq_backend.dart';
import 'pq_dm_codec.dart';
import 'pq_prekey_service.dart';

/// Per-conversation hybrid-PQ state (the self-report the UI surfaces).
enum PqConversationState {
  /// Not yet negotiated / unknown.
  unknown,

  /// Classical path, peer published no hybrid prekey (negotiated downgrade) or
  /// this device has no PQ backend (web without noble bundled).
  classical,

  /// Hybrid-pq negotiated, both sides advertise `x25519-mlkem768`. DMs sealed +
  /// opened via the hybrid KEM.
  hybridPq,
}

/// Wires the [PqDmCodec] + [PqPrekeyService] into the app's DM send/receive.
///
/// - [sealOutgoing]: on send, fetch the peer's prekey; if hybrid AND this device
///   has a keypair, seal the body into a `pqdm1:` token (the recorded negotiated
///   suite flips `hybrid-pq`). Otherwise return the body unchanged (classical
///   path, byte-for-byte). NEVER silently downgrades a previously-hybrid convo,
///   a fetch failure keeps the last known hybrid state.
/// - [openIncoming]: on receive, detect a `pqdm1:` token and open it with the
///   device private key (flips the convo `hybrid-pq`). Non-token bodies pass
///   through unchanged. A failed open returns a visible placeholder (never
///   throws into the render loop).
///
/// Own-outbound rendering (multi-device fanout, Task 11): [sealOutgoing] fans a
/// DM out to EVERY recipient device slot: the peer's devices AND the sender's
/// OWN devices, sealed once as a `pqdm2:` multi-recipient envelope (via
/// [PqDmCodec.buildPqdm2]). Because this device is itself a recipient slot, when
/// the history poll echoes our own sent token back we open it straight from our
/// OWN slot (the token's header binds `sender == localShort`), so it renders as
/// the original plaintext with NO persisted token->plaintext cache. The old Hive
/// `recordOutbound`/`recallOutbound` recall path is retired. A pqdm1-only peer
/// (no `codec: pqdm2` advert) still gets the single-recipient `pqdm1:` seal; our
/// own pqdm1 outbound has no own slot and renders as the locked placeholder,
/// which is fine now that live peers advertise pqdm2.
///
/// The (sender, recipient) bound into the downgrade-lock AAD are the SHORT names
/// (e.g. `chef`, `lumina`) so they match what the Python daemon binds. Both
/// sides MUST agree on these identifiers or the AEAD open fails.
class PqConversationService {
  PqConversationService({
    required PqPrekeyService prekeys,
    required String localShort,
    PqDmCodec? codec,
  })  : _prekeys = prekeys,
        _localShort = localShort,
        _codec = codec ?? PqDmCodec();

  final PqPrekeyService _prekeys;
  final PqDmCodec _codec;
  final String _localShort;

  final Map<String, PqConversationState> _state = {};

  /// The per-conversation hybrid self-report (defaults to [unknown]).
  PqConversationState stateFor(String peer) =>
      _state[_short(peer)] ?? PqConversationState.unknown;

  bool isHybrid(String peer) =>
      stateFor(peer) == PqConversationState.hybridPq;

  /// Prefetch + cache the peer's prekey bundle when a conversation OPENS, so the
  /// seal at send time uses the cached bundle and doesn't race a busy webui
  /// (BUG 2). If the peer advertises hybrid, the conversation is recorded
  /// hybrid-pq up front (the badge can show immediately). A failed prefetch is a
  /// no-op, it never downgrades a conversation, and the send-time fetch retries.
  Future<void> prefetchPeer(String peer) async {
    final peerShort = _short(peer);
    // Make sure this device has a keypair (so a hybrid peer actually negotiates
    // hybrid). Best-effort; a missing backend keeps classical.
    final haveKey = await _prekeys.ensureKeyPair();
    if (!haveKey) return;
    try {
      final bundle = await _prekeys.fetchPeerNewest(peerShort);
      if (bundle.isHybrid) {
        _state[peerShort] = PqConversationState.hybridPq;
      }
    } catch (_) {
      // Never downgrade on a prefetch failure, leave the last known state.
    }
  }

  /// Seal [content] to [peer]. When the peer advertises the `pqdm2` fanout
  /// capability, seal ONE `pqdm2:` multi-recipient envelope wrapped per device
  /// slot: every peer device slot AND every sender-own device slot (so all of
  /// our own devices can also open our sent message straight from their slot).
  /// A peer that only advertises the legacy single slot gets the `pqdm1:` seal
  /// against its newest slot. A classical (no hybrid prekey) peer gets [content]
  /// unchanged. Records the negotiated suite so the UI 🔐 indicator is honest,
  /// and NEVER silently downgrades a previously-hybrid conversation on a
  /// transient fetch miss.
  Future<String> sealOutgoing(String peer, String content) async {
    final peerShort = _short(peer);
    // Control sentinels (__REACT__/__TYPING__/… and __CALL_REQUEST__) must stay
    // cleartext so the existing dispatch keeps working, never seal them.
    if (content.startsWith('__')) return content;
    // Already a token (re-send), pass through.
    if (PqDmCodec.isHybridToken(content) ||
        content.startsWith(PqDmCodec.pqdm2Prefix)) {
      return content;
    }

    final haveKey = await _prekeys.ensureKeyPair();
    if (!haveKey) {
      // No PQ backend at all → classical (a capability fact, not a per-message
      // failure, so recording classical is honest).
      _state[peerShort] = PqConversationState.classical;
      return content;
    }
    // The full peer slot LIST (multi-device). Uses the in-process cache when the
    // conversation was prefetched; only hits the network on a cache miss.
    final peerSlots = await _prekeys.fetchPeer(peerShort);
    final peerIsHybrid = peerSlots.any((b) => b.isHybrid);
    final suite = PqDmCodec.negotiateSuite(
      localSupportsHybrid: true,
      peerIsHybrid: peerIsHybrid,
    );
    if (suite != PqDmCodec.hybridSuite) {
      // Don't clobber a previously-negotiated hybrid state on a transient miss:
      // a convo that negotiated hybrid STAYS hybrid (the fetch is retried) so a
      // single later failure doesn't silently downgrade it.
      if (stateFor(peerShort) != PqConversationState.hybridPq) {
        _state[peerShort] = PqConversationState.classical;
      }
      return content;
    }

    final body = Uint8List.fromList(utf8.encode(content));

    // Fanout when ANY peer slot advertises the pqdm2 capability (mirrors the
    // daemon's `_seal_hybrid_outbound` gate). Seal to every peer device slot AND
    // every sender-own device slot in a single envelope.
    final fanout = peerSlots.any((b) => b.codec == PrekeyBundle.pqdm2Codec);
    if (fanout) {
      try {
        final recipients = await _fanoutRecipients(peerShort, peerSlots);
        if (recipients.isNotEmpty) {
          final token = await _codec.buildPqdm2(
            body,
            recipients,
            sender: _localShort,
            recipientId: peerShort,
          );
          _state[peerShort] = PqConversationState.hybridPq;
          return token;
        }
        // No sealable slot: fall through to the pqdm1 path below.
      } catch (_) {
        // Fanout failed (malformed slot / no backend): fall back to pqdm1 so a
        // single bad device never sinks the send. Don't downgrade if hybrid.
      }
    }

    // pqdm1 single-recipient fallback (peer has no pqdm2 advert): seal to the
    // newest peer slot. Our own pqdm1 outbound has no own slot to open, so it
    // renders as the locked placeholder on echo (acceptable now peers are pqdm2).
    try {
      final newest = peerSlots.isNotEmpty ? peerSlots.first : const PrekeyBundle();
      final token = await _codec.sealToken(
        body,
        newest.hybridPublic(),
        sender: _localShort,
        recipient: peerShort,
      );
      _state[peerShort] = PqConversationState.hybridPq;
      return token;
    } catch (_) {
      // Sealing failed (bad bundle / no backend) → keep msg, don't downgrade a
      // known-hybrid convo (transient); only record classical if not hybrid.
      if (stateFor(peerShort) != PqConversationState.hybridPq) {
        _state[peerShort] = PqConversationState.classical;
      }
      return content;
    }
  }

  /// Build the deduped recipient device slot list for a `pqdm2:` fanout: every
  /// peer device slot in [peerSlots] PLUS every sender-own device slot (this
  /// device from [PqPrekeyService.myBundle], and any other own devices published
  /// under the local short name). Malformed / classical / key-less slots are
  /// skipped so one bad device never sinks the fanout; deduped by `key_id`.
  Future<List<Pqdm2Recipient>> _fanoutRecipients(
    String peerShort,
    List<PrekeyBundle> peerSlots,
  ) async {
    // Own slots: guarantee THIS device (so our own echo always opens locally),
    // then merge any other own devices the daemon has published for us.
    final ownSlots = <PrekeyBundle>[await _prekeys.myBundle()];
    try {
      ownSlots.addAll(await _prekeys.fetchPeer(_localShort));
    } catch (_) {
      // Best-effort: the guaranteed local slot still covers own-device render.
    }

    final recipients = <Pqdm2Recipient>[];
    final seen = <String>{};
    for (final b in [...peerSlots, ...ownSlots]) {
      final kid = b.keyId;
      if (kid == null || kid.isEmpty || !b.isHybrid) continue;
      if (!seen.add(kid)) continue;
      final Uint8List pub;
      try {
        pub = b.hybridPublic();
      } catch (_) {
        continue; // malformed hex, skip this slot
      }
      recipients.add(Pqdm2Recipient(keyId: kid, hybridPublicKey: pub));
    }
    return recipients;
  }

  /// Placeholder rendered for a hybrid-sealed message this device cannot open
  /// because it holds no PQ key at all (no backend / never generated one).
  static const String lockedNoKeyText =
      '🔐 Encrypted message (no key on this device)';

  /// Placeholder rendered for a hybrid-sealed message this device cannot open
  /// because the AEAD open failed, most commonly the message was sealed to a
  /// DIFFERENT device's prekey (the operator has one published prekey; the
  /// active device is not the one Lumina sealed to).
  static const String lockedCantOpenText =
      "🔐 Encrypted message (can't be opened on this device)";

  /// Open an incoming [body] from [peer]. A `pqdm2:` token whose header binds
  /// `sender == localShort` is OUR OWN outbound echoed back from history: we open
  /// it straight from this device's own slot (no plaintext cache) and render it
  /// as outbound. Otherwise decapsulate + decrypt with this device's private key
  /// and flip the convo `hybrid-pq`. Non-token bodies are returned unchanged. A
  /// failed open returns a visible placeholder so the render loop never throws.
  Future<String> openIncoming(String peer, String body) async =>
      (await openIncomingDetailed(peer, body)).text;

  /// Like [openIncoming], but reports WHETHER the body was actually opened.
  ///
  /// Returns `(text, opened, mine)`:
  /// - `opened == true`  → [text] is the real plaintext (a peer message we
  ///   decrypted, our own outbound opened from our slot, or a non-token
  ///   passthrough).
  /// - `opened == false` → [text] is a visible LOCKED placeholder; this device
  ///   could not open the sealed token (no key, or the AEAD open failed because
  ///   it was sealed to another device's prekey / a browser without PQC).
  /// - `mine == true`    → it is our own outbound echoed back (render outbound).
  ///
  /// The caller renders a not-opened result as a per-message locked bubble
  /// (deduped by id only) so the sender is never silently dropped. CARD E, the
  /// reduced-assurance web/PWA leg.
  Future<({String text, bool opened, bool mine})> openIncomingDetailed(
    String peer,
    String body,
  ) async {
    final isPqdm2 = body.startsWith(PqDmCodec.pqdm2Prefix);
    if (!PqDmCodec.isHybridToken(body) && !isPqdm2) {
      return (text: body, opened: true, mine: false);
    }
    final peerShort = _short(peer);

    final haveKey = await _prekeys.ensureKeyPair();
    if (!haveKey) {
      return (text: lockedNoKeyText, opened: false, mine: false);
    }
    final priv = _prekeys.privateKey;
    if (priv == null) {
      return (text: lockedNoKeyText, opened: false, mine: false);
    }

    // pqdm2: multi-device fanout envelope. Select THIS device's own slot by its
    // published key_id and open it. When the header binds `sender == localShort`
    // the token is OUR OWN outbound echoed back from history: open it with the
    // token's own (sender, recipient) binding and render it as outbound (`mine`),
    // which is how own-device rendering now works with NO plaintext cache. A
    // token that carries no slot for this device (or any AEAD failure) returns
    // null, surfaced as the graceful locked placeholder, never a crash. Mirrors
    // the daemon's _open_pqdm2_inbound.
    if (isPqdm2) {
      final myKeyId = _prekeys.keyId;
      if (myKeyId == null) {
        return (text: lockedNoKeyText, opened: false, mine: false);
      }
      final header = _pqdm2Header(body);
      final headerSender = header?['sender'] as String?;
      final headerRecipient = header?['recipient'] as String?;
      final mineToken = headerSender == _localShort;
      // Own outbound: the AAD was bound (sender=us, recipient=peer). A genuine
      // inbound uses (sender=peer, recipient=us).
      final openSender = mineToken ? _localShort : peerShort;
      final openRecipient =
          mineToken ? (headerRecipient ?? peerShort) : _localShort;
      final clear = await _codec.openPqdm2(
        body,
        myKeyId: myKeyId,
        myPrivate: priv,
        sender: openSender,
        recipientId: openRecipient,
      );
      if (clear == null) {
        return (text: lockedCantOpenText, opened: false, mine: false);
      }
      _state[peerShort] = PqConversationState.hybridPq;
      return (text: utf8.decode(clear), opened: true, mine: mineToken);
    }

    try {
      // The sender bound (sender=them, recipient=us). The token's expected suite
      // is read from the token itself by the codec.
      final clear = await _codec.openToken(
        body,
        priv,
        sender: peerShort,
        recipient: _localShort,
      );
      _state[peerShort] = PqConversationState.hybridPq;
      return (text: utf8.decode(clear), opened: true, mine: false);
    } catch (_) {
      // DowngradeDetected / malformed / wrong-device key, surface, don't crash.
      return (text: lockedCantOpenText, opened: false, mine: false);
    }
  }

  String _short(String uri) {
    var s = uri.startsWith('capauth:') ? uri.substring('capauth:'.length) : uri;
    return s.split('@').first;
  }

  /// Decode the JSON header of a `pqdm2:` token (the `b64(header).b64(slots).
  /// b64(body)` layout) so the render path can read its `sender`/`recipient`
  /// binding. Returns null on any malformed token (the caller then treats it as
  /// a normal inbound and lets the AEAD open fail gracefully).
  static Map<String, dynamic>? _pqdm2Header(String token) {
    try {
      final rest = token.substring(PqDmCodec.pqdm2Prefix.length);
      final parts = rest.split('.');
      if (parts.length != 3) return null;
      final decoded = jsonDecode(utf8.decode(base64.decode(parts[0])));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

// ── Riverpod wiring ──────────────────────────────────────────────────────────

/// The local operator short-name bound into the AAD. Mirrors how the daemon
/// binds the sender/recipient short names. Defaults to `chef`.
final pqLocalShortProvider = Provider<String>((ref) => 'chef');

final pqConversationServiceProvider = Provider<PqConversationService>((ref) {
  return PqConversationService(
    prekeys: ref.watch(pqPrekeyServiceProvider),
    localShort: ref.watch(pqLocalShortProvider),
    // Guarded KEM so building the codec (and thus reading this provider) can
    // never throw on a device without a PQ backend; seal/open then degrade to
    // the classical path instead of crashing the conversation screen.
    codec: PqDmCodec(kem: ref.watch(hybridKemProvider)),
  );
});

/// Per-conversation hybrid self-report for the UI 🔐 indicator. Rebuilds when
/// the service records a new state (the conversation provider invalidates it
/// after a seal/open).
final conversationPqStateProvider =
    Provider.family<PqConversationState, String>((ref, peer) {
  // Reading the service is enough; the conversation provider calls
  // `ref.invalidate(conversationPqStateProvider(peer))` after a seal/open so
  // this re-reads the freshly-recorded state.
  return ref.watch(pqConversationServiceProvider).stateFor(peer);
});
