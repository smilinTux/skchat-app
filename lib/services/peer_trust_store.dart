import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// A peer's trust tier. green is self/operator only, so a peer is red,
/// amber, or unverifiable. unverifiable means there is no real capauth key
/// to anchor trust to (fingerprint is null, empty, or a peerId fallback).
enum PeerTrustTier { red, amber, unverifiable }

/// One trust-on-first-use record for a peer, keyed by peerId.
class PeerTrustRecord {
  const PeerTrustRecord({
    required this.peerId,
    required this.fingerprint,
    required this.verified,
    required this.firstSeenAt,
    this.keyChanged = false,
  });

  final String peerId;
  final String fingerprint;
  final bool verified;
  final DateTime firstSeenAt;

  /// True when the current [fingerprint] replaced a DIFFERENT one that was
  /// previously seen for this peer (a key rotation), and it has not yet been
  /// cleared by a fresh [PeerTrustResolver.markVerified] call. This is
  /// separate from [verified]/first-sight TOFU so the UI can tell "never met
  /// this peer before" apart from "this peer's key just changed."
  final bool keyChanged;

  PeerTrustRecord copyWith({
    String? fingerprint,
    bool? verified,
    bool? keyChanged,
  }) =>
      PeerTrustRecord(
        peerId: peerId,
        fingerprint: fingerprint ?? this.fingerprint,
        verified: verified ?? this.verified,
        firstSeenAt: firstSeenAt,
        keyChanged: keyChanged ?? this.keyChanged,
      );

  Map<String, dynamic> toJson() => {
        'peerId': peerId,
        'fingerprint': fingerprint,
        'verified': verified,
        'firstSeenAt': firstSeenAt.toIso8601String(),
        'keyChanged': keyChanged,
      };

  factory PeerTrustRecord.fromJson(Map<String, dynamic> j) => PeerTrustRecord(
        peerId: j['peerId'] as String,
        fingerprint: j['fingerprint'] as String,
        verified: j['verified'] as bool? ?? false,
        firstSeenAt: DateTime.tryParse(j['firstSeenAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        keyChanged: j['keyChanged'] as bool? ?? false,
      );
}

/// Persistence seam so tests use an in-memory fake instead of Hive.
abstract class PeerTrustStore {
  Future<Map<String, PeerTrustRecord>> load();
  Future<void> save(Map<String, PeerTrustRecord> records);
}

const _kSettingsBox = 'settings';
const _kRecordsKey = 'peer_trust_records';

/// Production store: one JSON blob in the shared settings Hive box.
class HivePeerTrustStore implements PeerTrustStore {
  const HivePeerTrustStore();

  @override
  Future<Map<String, PeerTrustRecord>> load() async {
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      final raw = box.get(_kRecordsKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(k, PeerTrustRecord.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> save(Map<String, PeerTrustRecord> records) async {
    try {
      final box = await Hive.openBox<String>(_kSettingsBox);
      await box.put(_kRecordsKey,
          jsonEncode(records.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (_) {
      // Best-effort: a persistence failure must not break chat.
    }
  }
}

/// TOFU tier logic over a [PeerTrustStore].
class PeerTrustResolver {
  PeerTrustResolver(this._store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final PeerTrustStore _store;
  final DateTime Function() _now;

  /// A fingerprint anchors real trust only when it is non-null, non-empty,
  /// and not merely the peerId echoed back (the `chats_provider` fallback
  /// `peer.fingerprint ?? peerId` uses the peerId when there is no real
  /// capauth key; that must never be treated as a key).
  bool _isRealKey(String peerId, String? fp) =>
      fp != null && fp.isNotEmpty && fp != peerId;

  Future<PeerTrustTier> tierFor(String peerId, String? fingerprint) async {
    if (!_isRealKey(peerId, fingerprint)) return PeerTrustTier.unverifiable;
    final rec = (await _store.load())[peerId];
    if (rec == null || rec.fingerprint != fingerprint) {
      return PeerTrustTier.red; // no record, or key change
    }
    return rec.verified ? PeerTrustTier.amber : PeerTrustTier.red;
  }

  /// Record an observation. Returns true only for a genuine ROTATION of a
  /// previously VERIFIED key (worth surfacing as a spoof alarm). Sights
  /// without a real key (null/empty/peerId-fallback fingerprint) are
  /// ignored entirely so they can never overwrite or churn a real record.
  /// First sight of a real key persists a fresh unverified record. A
  /// changed fingerprint on an unverified record is updated silently (no
  /// alarm, since nobody had verified that peer yet).
  Future<bool> recordSight(String peerId, String? fingerprint) async {
    if (!_isRealKey(peerId, fingerprint)) return false;
    final fp = fingerprint!;
    final all = await _store.load();
    final rec = all[peerId];
    if (rec == null) {
      all[peerId] = PeerTrustRecord(
        peerId: peerId,
        fingerprint: fp,
        verified: false,
        firstSeenAt: _now(),
      );
      await _store.save(all);
      return false;
    }
    if (rec.fingerprint == fp) return false; // unchanged, no write
    if (rec.verified) {
      // Rotation of a trusted key: drop verification and flag it so
      // isKeyChanged can surface the alarm.
      all[peerId] = rec.copyWith(
        fingerprint: fp,
        verified: false,
        keyChanged: true,
      );
      await _store.save(all);
      return true;
    }
    // Nobody had verified this peer, so a fingerprint change is a silent
    // update, not a spoof alarm.
    all[peerId] = rec.copyWith(
      fingerprint: fp,
      verified: false,
      keyChanged: false,
    );
    await _store.save(all);
    return false;
  }

  /// True only when a real-key record exists whose stored fingerprint
  /// matches [fingerprint] and whose `keyChanged` flag is set (an actually
  /// rotated, previously-verified key).
  Future<bool> isKeyChanged(String peerId, String? fingerprint) async {
    if (!_isRealKey(peerId, fingerprint)) return false;
    final rec = (await _store.load())[peerId];
    return rec != null && rec.fingerprint == fingerprint && rec.keyChanged;
  }

  /// Promote to amber, but only for a real key whose CURRENT fingerprint
  /// matches. Verifying also clears any pending key-change flag, since the
  /// new key is now confirmed.
  Future<void> markVerified(String peerId, String fingerprint) async {
    if (!_isRealKey(peerId, fingerprint)) return;
    final all = await _store.load();
    final rec = all[peerId];
    if (rec == null) {
      all[peerId] = PeerTrustRecord(
        peerId: peerId,
        fingerprint: fingerprint,
        verified: true,
        firstSeenAt: _now(),
      );
    } else if (rec.fingerprint == fingerprint) {
      all[peerId] = rec.copyWith(verified: true, keyChanged: false);
    } else {
      return; // stale fingerprint, ignore
    }
    await _store.save(all);
  }

  /// Test convenience: record the sight then verify it in one call.
  Future<void> markVerifyFlow(String peerId, String fp) async {
    await recordSight(peerId, fp);
    await markVerified(peerId, fp);
  }
}

// -- Riverpod wiring ---------------------------------------------------------

final peerTrustResolverProvider = Provider<PeerTrustResolver>(
  (_) => PeerTrustResolver(const HivePeerTrustStore()),
);

typedef PeerTrustKey = ({String peerId, String? fingerprint});

final peerTrustTierProvider =
    FutureProvider.family<PeerTrustTier, PeerTrustKey>((ref, key) {
  return ref
      .watch(peerTrustResolverProvider)
      .tierFor(key.peerId, key.fingerprint);
});

/// Controller for observation + verification; invalidates the tier family so
/// every surface re-resolves after a change.
class PeerTrustController {
  PeerTrustController(this._ref);
  final Ref _ref;

  Future<void> recordSight(String peerId, String? fingerprint) async {
    final changed = await _ref
        .read(peerTrustResolverProvider)
        .recordSight(peerId, fingerprint);
    if (changed) _ref.invalidate(peerTrustTierProvider);
  }

  Future<void> markVerified(String peerId, String fingerprint) async {
    await _ref
        .read(peerTrustResolverProvider)
        .markVerified(peerId, fingerprint);
    _ref.invalidate(peerTrustTierProvider);
  }
}

final peerTrustControllerProvider =
    Provider<PeerTrustController>((ref) => PeerTrustController(ref));
