import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

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
/// Own-outbound problem (the BUG 1 fix): a hybrid DM is sealed to the PEER's
/// public key, so when the history poll returns our OWN sent `pqdm1:` token this
/// device cannot decapsulate it (it was sealed to the peer, not to us). We must
/// NEVER render an own-outbound token as ciphertext. The robust fix is a
/// persisted **token → plaintext** map ([recordOutbound]/[recallOutbound]):
/// every token this device seals is remembered (in-memory + Hive, so it
/// survives a page reload), keyed by the exact token string. When a `pqdm1:`
/// token arrives from history, the render path FIRST asks [recallOutbound], a
/// hit means "this is our own sent message; show this plaintext as outbound,
/// deduped", and only a miss is treated as a peer message to [openIncoming].
/// This removes the dependency on (often-wrong) directionality detection for our
/// own messages: an own-outbound sealed token always renders as its original
/// plaintext, deduped against the optimistic bubble.
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

  /// In-memory token → plaintext map for THIS device's own outbound sealed DMs
  /// (so we can render our own sent ciphertext as the original plaintext when it
  /// echoes back from history). Backed by a Hive box for reload survival.
  final Map<String, String> _outboundPlain = {};
  Box<String>? _outboundBox;
  bool _outboundLoaded = false;

  /// Hive box that persists the own-outbound token → plaintext map across page
  /// reloads (web). Bounded by a coarse cap so it can't grow without limit.
  static const String _outboundBoxName = 'pq_outbound_plain';
  static const int _outboundCap = 500;

  /// The per-conversation hybrid self-report (defaults to [unknown]).
  PqConversationState stateFor(String peer) =>
      _state[_short(peer)] ?? PqConversationState.unknown;

  bool isHybrid(String peer) =>
      stateFor(peer) == PqConversationState.hybridPq;

  /// Open (lazily) the persisted own-outbound plaintext box and hydrate the
  /// in-memory map. Best-effort: if Hive isn't initialized the cache stays
  /// in-memory only (still fixes the live session; reload falls back to the
  /// optimistic-bubble skip).
  Future<void> _ensureOutboundBox() async {
    if (_outboundLoaded) return;
    _outboundLoaded = true;
    try {
      _outboundBox = Hive.isBoxOpen(_outboundBoxName)
          ? Hive.box<String>(_outboundBoxName)
          : await _safeOpenBox();
      if (_outboundBox != null) {
        for (final key in _outboundBox!.keys) {
          final v = _outboundBox!.get(key);
          if (v != null) _outboundPlain['$key'] = v;
        }
      }
    } catch (_) {
      _outboundBox = null; // in-memory only
    }
  }

  /// Open the Hive box, fully containing the case where Hive isn't initialized
  /// (e.g. web before `Hive.initFlutter`, or a unit test that never inits Hive).
  /// `Hive.openBox` throws synchronously AND rejects an internal future in a
  /// separate microtask; the sync throw is caught by the caller, but the stray
  /// async rejection would otherwise surface as an unhandled error. A guarded
  /// zone swallows it and we stay in-memory only, best-effort persistence.
  Future<Box<String>?> _safeOpenBox() async {
    final completer = Completer<Box<String>?>();
    runZonedGuarded(() async {
      try {
        completer.complete(await Hive.openBox<String>(_outboundBoxName));
      } catch (_) {
        if (!completer.isCompleted) completer.complete(null);
      }
    }, (error, stack) {
      if (!completer.isCompleted) completer.complete(null);
    });
    return completer.future;
  }

  /// Remember the plaintext for an own-outbound sealed [token] so a later
  /// history echo of that exact token renders as plaintext (not ciphertext).
  Future<void> recordOutbound(String token, String plaintext) async {
    _outboundPlain[token] = plaintext;
    await _ensureOutboundBox();
    final box = _outboundBox;
    if (box == null) return;
    try {
      await box.put(token, plaintext);
      // Coarse FIFO trim so the box can't grow unbounded over a long session.
      if (box.length > _outboundCap) {
        final overflow = box.length - _outboundCap;
        final victims = box.keys.take(overflow).toList();
        await box.deleteAll(victims);
        for (final k in victims) {
          _outboundPlain.remove('$k');
        }
      }
    } catch (_) {
      // Persistence is best-effort; the in-memory map still covers the session.
    }
  }

  /// If [token] is one THIS device sealed (an own outbound), return its original
  /// plaintext; otherwise null. Hydrates the persisted map on first use so the
  /// lookup works after a page reload.
  Future<String?> recallOutbound(String token) async {
    if (_outboundPlain.containsKey(token)) return _outboundPlain[token];
    await _ensureOutboundBox();
    return _outboundPlain[token];
  }

  /// Synchronous fast-path for [recallOutbound] once the box has been hydrated.
  String? recallOutboundSync(String token) => _outboundPlain[token];

  /// Eagerly hydrate the persisted own-outbound cache (call on conversation open
  /// so the very first history poll can resolve own tokens).
  Future<void> primeOutboundCache() => _ensureOutboundBox();

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

  /// Seal [content] to [peer] if a hybrid prekey is advertised. Returns the
  /// `pqdm1:` token (hybrid) or the original [content] (classical). Records the
  /// negotiated suite so the UI indicator is honest, and remembers the token →
  /// plaintext so our own echoed-back token renders as plaintext.
  Future<String> sealOutgoing(String peer, String content) async {
    final peerShort = _short(peer);
    // Control sentinels (__REACT__/__TYPING__/… and __CALL_REQUEST__) must stay
    // cleartext so the existing dispatch keeps working, never seal them.
    if (content.startsWith('__')) return content;
    // Already a token (re-send), pass through.
    if (PqDmCodec.isHybridToken(content)) return content;

    final haveKey = await _prekeys.ensureKeyPair();
    if (!haveKey) {
      // No PQ backend at all → classical (a capability fact, not a per-message
      // failure, so recording classical is honest).
      _state[peerShort] = PqConversationState.classical;
      return content;
    }
    // Uses the cached bundle (prefetched on conversation open) when present;
    // fetchPeerNewest only hits the network on a cache miss.
    final bundle = await _prekeys.fetchPeerNewest(peerShort);
    final suite = PqDmCodec.negotiateSuite(
      localSupportsHybrid: true,
      peerIsHybrid: bundle.isHybrid,
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
    try {
      final token = await _codec.sealToken(
        Uint8List.fromList(utf8.encode(content)),
        bundle.hybridPublic(),
        sender: _localShort,
        recipient: peerShort,
      );
      _state[peerShort] = PqConversationState.hybridPq;
      // Remember our own outbound so the history echo renders as plaintext.
      await recordOutbound(token, content);
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

  /// Open an incoming [body] from [peer]. If it's a `pqdm1:` token, FIRST check
  /// whether it's one WE sealed (own outbound echoed back from history), if so
  /// return the remembered plaintext (it can't be decapsulated with our key, it
  /// was sealed to the peer). Otherwise decapsulate + decrypt with this device's
  /// private key and flip the convo `hybrid-pq`. Non-token bodies are returned
  /// unchanged. A failed open returns a visible placeholder so the render loop
  /// never throws.
  Future<String> openIncoming(String peer, String body) async =>
      (await openIncomingDetailed(peer, body)).text;

  /// Like [openIncoming], but reports WHETHER the body was actually opened.
  ///
  /// Returns `(text, opened, mine)`:
  /// - `opened == true`  → [text] is the real plaintext (a peer message we
  ///   decrypted, our own recalled outbound, or a non-token passthrough).
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

    // Own-outbound? (sealed to the peer's key, not openable here). Render the
    // remembered plaintext and flip the convo hybrid (we DID seal hybrid).
    final mine = await recallOutbound(body);
    if (mine != null) {
      _state[peerShort] = PqConversationState.hybridPq;
      return (text: mine, opened: true, mine: true);
    }

    final haveKey = await _prekeys.ensureKeyPair();
    if (!haveKey) {
      return (text: lockedNoKeyText, opened: false, mine: false);
    }
    final priv = _prekeys.privateKey;
    if (priv == null) {
      return (text: lockedNoKeyText, opened: false, mine: false);
    }

    // pqdm2: multi-device fanout envelope. Select THIS device's own slot by its
    // published key_id and open it. A token that carries no slot for this device
    // (or any AEAD failure) returns null, surfaced as the graceful locked
    // placeholder, never a crash. Mirrors the daemon's _open_pqdm2_inbound.
    if (isPqdm2) {
      final myKeyId = _prekeys.keyId;
      if (myKeyId == null) {
        return (text: lockedNoKeyText, opened: false, mine: false);
      }
      final clear = await _codec.openPqdm2(
        body,
        myKeyId: myKeyId,
        myPrivate: priv,
        sender: peerShort,
        recipientId: _localShort,
      );
      if (clear == null) {
        return (text: lockedCantOpenText, opened: false, mine: false);
      }
      _state[peerShort] = PqConversationState.hybridPq;
      return (text: utf8.decode(clear), opened: true, mine: false);
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
