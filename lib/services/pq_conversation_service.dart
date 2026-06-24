import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pq_dm_codec.dart';
import 'pq_prekey_service.dart';

/// Per-conversation hybrid-PQ state (the self-report the UI surfaces).
enum PqConversationState {
  /// Not yet negotiated / unknown.
  unknown,

  /// Classical path — peer published no hybrid prekey (negotiated downgrade) or
  /// this device has no PQ backend (web without noble bundled).
  classical,

  /// Hybrid-pq negotiated — both sides advertise `x25519-mlkem768`. DMs sealed +
  /// opened via the hybrid KEM.
  hybridPq,
}

/// Wires the [PqDmCodec] + [PqPrekeyService] into the app's DM send/receive.
///
/// - [sealOutgoing]: on send, fetch the peer's prekey; if hybrid AND this device
///   has a keypair, seal the body into a `pqdm1:` token (the recorded negotiated
///   suite flips `hybrid-pq`). Otherwise return the body unchanged (classical
///   path, byte-for-byte). NEVER silently downgrades a previously-hybrid convo —
///   a fetch failure keeps the last known state.
/// - [openIncoming]: on receive, detect a `pqdm1:` token and open it with the
///   device private key (flips the convo `hybrid-pq`). Non-token bodies pass
///   through unchanged. A failed open returns a visible placeholder (never
///   throws into the render loop).
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

  /// Seal [content] to [peer] if a hybrid prekey is advertised. Returns the
  /// `pqdm1:` token (hybrid) or the original [content] (classical). Records the
  /// negotiated suite so the UI indicator is honest.
  Future<String> sealOutgoing(String peer, String content) async {
    final peerShort = _short(peer);
    // Control sentinels (__REACT__/__TYPING__/… and __CALL_REQUEST__) must stay
    // cleartext so the existing dispatch keeps working — never seal them.
    if (content.startsWith('__')) return content;
    // Already a token (re-send) — pass through.
    if (PqDmCodec.isHybridToken(content)) return content;

    final haveKey = await _prekeys.ensureKeyPair();
    if (!haveKey) {
      _state[peerShort] = PqConversationState.classical;
      return content;
    }
    final bundle = await _prekeys.fetchPeer(peerShort);
    final suite = PqDmCodec.negotiateSuite(
      localSupportsHybrid: true,
      peerIsHybrid: bundle.isHybrid,
    );
    if (suite != PqDmCodec.hybridSuite) {
      _state[peerShort] = PqConversationState.classical;
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
      return token;
    } catch (_) {
      // Sealing failed (bad bundle / no backend) → classical, don't drop the msg.
      _state[peerShort] = PqConversationState.classical;
      return content;
    }
  }

  /// Open an incoming [body] from [peer]. If it's a `pqdm1:` token, decapsulate +
  /// decrypt with this device's private key and flip the convo `hybrid-pq`.
  /// Non-token bodies are returned unchanged. A failed open returns a visible
  /// placeholder so the render loop never throws.
  Future<String> openIncoming(String peer, String body) async {
    if (!PqDmCodec.isHybridToken(body)) return body;
    final peerShort = _short(peer);
    final haveKey = await _prekeys.ensureKeyPair();
    final priv = _prekeys.privateKey;
    if (!haveKey || priv == null) {
      return '🔐 [post-quantum message — no key on this device]';
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
      return utf8.decode(clear);
    } catch (_) {
      // DowngradeDetected / malformed — surface, don't crash.
      return '🔐 [post-quantum message — could not decrypt]';
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
