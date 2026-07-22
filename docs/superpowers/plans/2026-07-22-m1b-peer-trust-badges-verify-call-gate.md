# M1b: per-peer trust badges + verify + 1:1 call gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. The badge-placement tasks (5a-5d) are mutually independent and MAY be fanned out to parallel agents once Task 1 lands. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make per-peer trust visible (a red/amber badge on every peer surface) and enforced (a 1:1 call to an unverified peer is blocked), backed by a local trust-on-first-use record and a safety-number verify flow.

**Architecture:** A local `PeerTrustStore` (TOFU, keyed on the peer's capauth `soulFingerprint`) resolves a `PeerTrustTier` per peer, surfaced via a Riverpod family. Every peer surface reads that tier into the existing `TrustBadge`, and records the peer on first sight. A safety-number pure function drives a verify sheet that promotes red->amber. The 1:1 call button gates on the tier.

**Tech Stack:** Dart/Flutter, Riverpod, Hive (settings box persistence), crypto (SHA-256 for the safety number), qr_flutter (show-only QR). All already in pubspec.

## Global Constraints

- **Tiers:** peer tiers are **red** (TOFU/unverified, or key-changed danger) and **amber** (safety-number verified). green is self/operator only; a peer never shows green in this cut.
- **Trust source:** local TOFU only. NO server API changes. Key on `conversation.soulFingerprint` (the peer's CapAuth fingerprint). No fingerprint => no badge + treat as red for the gate.
- **Safety number:** deterministic AND symmetric: `safetyNumber(a,b) == safetyNumber(b,a)`. Sort the two fingerprints, SHA-256 the concatenation, render 60 decimal digits as 12 groups of 5.
- **Call gate:** blocks ONLY the 1:1 call path. red => blocked with a "Verify to call" affordance; amber+ => proceeds. Do NOT touch Spaces / group calls.
- **Widget reuse:** `TrustBadge` takes `SelfTrustTier`. Map `PeerTrustTier.red -> SelfTrustTier.red`, `PeerTrustTier.amber -> SelfTrustTier.amber` at the call site. Do not change TrustBadge's enum.
- **No em/en dashes** anywhere (code, comments, commits, docs).
- **Commit trailer (every commit):** `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- **Dart 80-col.** Run Flutter with `export PATH=/home/cbrd21/flutter/bin:$PATH`. Branch `feat/m1b-peer-trust` (already created).
- Persistence is best-effort: a storage error must never break chat/calls.

## File Structure

- Create `lib/services/peer_trust_store.dart` — `PeerTrustRecord`, `PeerTrustTier`, `PeerTrustStore` seam + Hive impl + `PeerTrustResolver` (tier logic) + Riverpod providers.
- Create `lib/services/safety_number.dart` — the pure `safetyNumber()` function.
- Create `lib/features/identity/verify_peer_sheet.dart` — the verify bottom sheet.
- Modify `lib/features/identity/widgets/trust_badge.dart` — add a `Semantics` label in compact mode.
- Modify `lib/features/conversation/conversation_screen.dart` — DM-header badge + call gate.
- Modify `lib/features/chats/*` (ConversationTile) — inbox-row badge.
- Modify the group member surface + `lib/features/spaces/space_room_screen.dart` — member/participant badges.
- Tests under `test/services/` and `test/features/`.

---

### Task 1: `PeerTrustStore` + tier resolver + providers (FOUNDATION)

**Files:**
- Create: `lib/services/peer_trust_store.dart`
- Test: `test/services/peer_trust_store_test.dart`

**Interfaces:**
- Produces:
  - `enum PeerTrustTier { red, amber }`
  - `class PeerTrustRecord { final String peerId, fingerprint; final bool verified; final DateTime firstSeenAt; }` with `toJson`/`fromJson`.
  - `abstract class PeerTrustStore { Future<Map<String,PeerTrustRecord>> load(); Future<void> save(Map<String,PeerTrustRecord>); }`
  - `class HivePeerTrustStore implements PeerTrustStore` (settings box, key `peer_trust_records`).
  - `class PeerTrustResolver` with `Future<PeerTrustTier> tierFor(String peerId, String? fingerprint)`, `Future<bool> recordSight(String peerId, String? fingerprint)` (returns true when a key change was detected), `Future<void> markVerified(String peerId, String fingerprint)`, and `Future<bool> isKeyChanged(String peerId, String? fingerprint)`.
  - Providers: `peerTrustResolverProvider`, `peerTrustTierProvider = FutureProvider.family<PeerTrustTier, ({String peerId, String? fingerprint})>`, and a `peerTrustControllerProvider` exposing `recordSight`/`markVerified` that invalidates the family.

- [ ] **Step 1: Write failing tests**

```dart
// test/services/peer_trust_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/peer_trust_store.dart';

class _MemStore implements PeerTrustStore {
  Map<String, PeerTrustRecord> _m = {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => Map.of(_m);
  @override
  Future<void> save(Map<String, PeerTrustRecord> m) async => _m = Map.of(m);
}

PeerTrustResolver _resolver([_MemStore? s]) =>
    PeerTrustResolver(s ?? _MemStore(), now: () => DateTime(2026, 7, 22));

void main() {
  test('first sight records red (TOFU), unverified', () async {
    final r = _resolver();
    await r.recordSight('bob', 'fp1');
    expect(await r.tierFor('bob', 'fp1'), PeerTrustTier.red);
  });

  test('no fingerprint resolves red', () async {
    final r = _resolver();
    expect(await r.tierFor('ghost', null), PeerTrustTier.red);
  });

  test('markVerified promotes to amber for the current fingerprint', () async {
    final r = _resolver();
    await r.recordSight('bob', 'fp1');
    await r.markVerified('bob', 'fp1');
    expect(await r.tierFor('bob', 'fp1'), PeerTrustTier.amber);
  });

  test('a changed fingerprint reverts to red + flags key change', () async {
    final s = _MemStore();
    final r = _resolver(s);
    await r.recordSight('bob', 'fp1');
    await r.markVerified('bob', 'fp1');
    expect(await r.tierFor('bob', 'fp1'), PeerTrustTier.amber);
    final changed = await r.recordSight('bob', 'fp2'); // key rotated
    expect(changed, isTrue);
    expect(await r.isKeyChanged('bob', 'fp2'), isTrue);
    expect(await r.tierFor('bob', 'fp2'), PeerTrustTier.red);
  });

  test('cannot verify against a stale fingerprint', () async {
    final r = _resolver();
    await r.recordSight('bob', 'fp2');
    await r.markVerified('bob', 'fp1'); // stale, ignored
    expect(await r.tierFor('bob', 'fp2'), PeerTrustTier.red);
  });

  test('records persist through the store (round-trip)', () async {
    final s = _MemStore();
    await _resolver(s).markVerifyFlow('bob', 'fp1'); // helper: record+verify
    final r2 = _resolver(s);
    expect(await r2.tierFor('bob', 'fp1'), PeerTrustTier.amber);
  });
}
```

Note: add a small test-only convenience `markVerifyFlow(peerId, fp)` on the resolver that calls `recordSight` then `markVerified`, OR inline both calls in the test. If you inline, drop the last test's helper usage.

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/peer_trust_store_test.dart`
Expected: FAIL (types not found).

- [ ] **Step 3: Implement**

```dart
// lib/services/peer_trust_store.dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// A peer's trust tier. green is self/operator only, so a peer is red or amber.
enum PeerTrustTier { red, amber }

/// One trust-on-first-use record for a peer, keyed by peerId.
class PeerTrustRecord {
  const PeerTrustRecord({
    required this.peerId,
    required this.fingerprint,
    required this.verified,
    required this.firstSeenAt,
  });

  final String peerId;
  final String fingerprint;
  final bool verified;
  final DateTime firstSeenAt;

  PeerTrustRecord copyWith({String? fingerprint, bool? verified}) =>
      PeerTrustRecord(
        peerId: peerId,
        fingerprint: fingerprint ?? this.fingerprint,
        verified: verified ?? this.verified,
        firstSeenAt: firstSeenAt,
      );

  Map<String, dynamic> toJson() => {
        'peerId': peerId,
        'fingerprint': fingerprint,
        'verified': verified,
        'firstSeenAt': firstSeenAt.toIso8601String(),
      };

  factory PeerTrustRecord.fromJson(Map<String, dynamic> j) => PeerTrustRecord(
        peerId: j['peerId'] as String,
        fingerprint: j['fingerprint'] as String,
        verified: j['verified'] as bool? ?? false,
        firstSeenAt:
            DateTime.tryParse(j['firstSeenAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
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

  Future<PeerTrustTier> tierFor(String peerId, String? fingerprint) async {
    if (fingerprint == null || fingerprint.isEmpty) return PeerTrustTier.red;
    final rec = (await _store.load())[peerId];
    if (rec == null) return PeerTrustTier.red;
    if (rec.fingerprint != fingerprint) return PeerTrustTier.red; // key change
    return rec.verified ? PeerTrustTier.amber : PeerTrustTier.red;
  }

  /// Record an observation. Returns true when this sight is a KEY CHANGE
  /// (an existing record had a different fingerprint). First sight persists a
  /// fresh unverified record. An unchanged sight is a no-op (no write).
  Future<bool> recordSight(String peerId, String? fingerprint) async {
    if (fingerprint == null || fingerprint.isEmpty) return false;
    final all = await _store.load();
    final rec = all[peerId];
    if (rec == null) {
      all[peerId] = PeerTrustRecord(
        peerId: peerId,
        fingerprint: fingerprint,
        verified: false,
        firstSeenAt: _now(),
      );
      await _store.save(all);
      return false;
    }
    if (rec.fingerprint == fingerprint) return false; // unchanged, no write
    // Key change: replace fingerprint, drop verification, keep firstSeenAt.
    all[peerId] = rec.copyWith(fingerprint: fingerprint, verified: false);
    await _store.save(all);
    return true;
  }

  /// True when a record exists for a DIFFERENT fingerprint than [fingerprint].
  Future<bool> isKeyChanged(String peerId, String? fingerprint) async {
    if (fingerprint == null || fingerprint.isEmpty) return false;
    final rec = (await _store.load())[peerId];
    return rec != null && rec.fingerprint != fingerprint;
  }

  /// Promote to amber, but only for the CURRENT fingerprint.
  Future<void> markVerified(String peerId, String fingerprint) async {
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
      all[peerId] = rec.copyWith(verified: true);
    } else {
      return; // stale fingerprint, ignore
    }
    await _store.save(all);
  }
}

// ── Riverpod wiring ──────────────────────────────────────────────────────────

final peerTrustResolverProvider = Provider<PeerTrustResolver>(
  (_) => PeerTrustResolver(const HivePeerTrustStore()),
);

typedef PeerTrustKey = ({String peerId, String? fingerprint});

final peerTrustTierProvider =
    FutureProvider.family<PeerTrustTier, PeerTrustKey>((ref, key) {
  return ref.watch(peerTrustResolverProvider).tierFor(key.peerId, key.fingerprint);
});

/// Controller for observation + verification; invalidates the tier family so
/// every surface re-resolves after a change.
class PeerTrustController {
  PeerTrustController(this._ref);
  final Ref _ref;

  Future<void> recordSight(String peerId, String? fingerprint) async {
    final changed =
        await _ref.read(peerTrustResolverProvider).recordSight(peerId, fingerprint);
    if (changed) _ref.invalidate(peerTrustTierProvider);
  }

  Future<void> markVerified(String peerId, String fingerprint) async {
    await _ref.read(peerTrustResolverProvider).markVerified(peerId, fingerprint);
    _ref.invalidate(peerTrustTierProvider);
  }
}

final peerTrustControllerProvider =
    Provider<PeerTrustController>((ref) => PeerTrustController(ref));
```

If the test uses a `markVerifyFlow` helper, add it to `PeerTrustResolver`:
```dart
Future<void> markVerifyFlow(String peerId, String fp) async {
  await recordSight(peerId, fp);
  await markVerified(peerId, fp);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/peer_trust_store_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/services/peer_trust_store.dart test/services/peer_trust_store_test.dart
git commit -m "feat(trust): local TOFU peer-trust store + tier resolver

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: `safety_number.dart` pure function (PARALLELIZABLE with Task 1)

**Files:**
- Create: `lib/services/safety_number.dart`
- Test: `test/services/safety_number_test.dart`

**Interfaces:**
- Produces: `String safetyNumber(String selfFingerprint, String peerFingerprint)` (60-digit grouped) and `String safetyCompareCode(String a, String b)` (short 8-char uppercase hex).

- [ ] **Step 1: Write failing tests**

```dart
// test/services/safety_number_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/safety_number.dart';

void main() {
  test('symmetric: order of the two fingerprints does not matter', () {
    expect(safetyNumber('aaa', 'bbb'), safetyNumber('bbb', 'aaa'));
    expect(safetyCompareCode('aaa', 'bbb'), safetyCompareCode('bbb', 'aaa'));
  });

  test('format: 60 digits in 12 space-separated groups of 5', () {
    final s = safetyNumber('aaa', 'bbb');
    final groups = s.split(' ');
    expect(groups.length, 12);
    expect(groups.every((g) => g.length == 5), isTrue);
    expect(s.replaceAll(' ', '').length, 60);
    expect(RegExp(r'^[0-9 ]+$').hasMatch(s), isTrue);
  });

  test('different fingerprints produce different numbers', () {
    expect(safetyNumber('aaa', 'bbb'), isNot(safetyNumber('aaa', 'ccc')));
  });

  test('compare code is 8 uppercase hex chars', () {
    expect(RegExp(r'^[0-9A-F]{8}$').hasMatch(safetyCompareCode('aaa', 'bbb')),
        isTrue);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/safety_number_test.dart`
Expected: FAIL (function not found).

- [ ] **Step 3: Implement**

```dart
// lib/services/safety_number.dart
//
// A stable, symmetric safety number for out-of-band peer verification. Both
// sides compute the SAME value by sorting the two fingerprints before hashing,
// so direction does not matter. This is an ADVISORY continuity check (it proves
// both sides hold the same two fingerprint strings), not a full authenticated
// key agreement.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Uint8List _digest(String a, String b) {
  final pair = [a, b]..sort();
  return Uint8List.fromList(
      sha256.convert(utf8.encode('${pair[0]}|${pair[1]}')).bytes);
}

/// A 60-digit decimal safety number rendered as 12 space-separated groups of 5.
/// Derived from 30 bytes of the digest, 5 digits per byte-pair chunk.
String safetyNumber(String selfFingerprint, String peerFingerprint) {
  final d = _digest(selfFingerprint, peerFingerprint);
  final sb = StringBuffer();
  // 12 groups of 5 digits: take a rolling 4-byte window per group, mod 100000.
  for (var g = 0; g < 12; g++) {
    var v = 0;
    for (var i = 0; i < 4; i++) {
      v = (v << 8) | d[(g * 4 + i) % d.length];
    }
    final group = (v % 100000).toString().padLeft(5, '0');
    if (g > 0) sb.write(' ');
    sb.write(group);
  }
  return sb.toString();
}

/// A short uppercase-hex compare code (first 4 digest bytes) for compact UI.
String safetyCompareCode(String a, String b) {
  final d = _digest(a, b);
  return d
      .sublist(0, 4)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}
```

(`crypto` was added as a dev-dep earlier; this uses it as a RUNTIME dep. Run `flutter pub add crypto` to move/confirm it as a normal dependency, then `flutter pub get`.)

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/services/safety_number_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/services/safety_number.dart test/services/safety_number_test.dart pubspec.yaml pubspec.lock
git commit -m "feat(trust): symmetric safety-number for peer verification

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: TrustBadge a11y + peer-tier mapping helper

**Files:**
- Modify: `lib/features/identity/widgets/trust_badge.dart`
- Create: `test/features/trust_badge_a11y_test.dart`

**Interfaces:**
- Consumes: `SelfTrustTier`, `PeerTrustTier` (Task 1).
- Produces: a compact `TrustBadge` that carries a `Semantics(label: ...)`; a top-level helper `SelfTrustTier selfTierForPeer(PeerTrustTier t)` in `trust_badge.dart` (maps red->red, amber->amber) so every surface maps once, consistently.

- [ ] **Step 1: Write failing test**

```dart
// test/features/trust_badge_a11y_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/identity/widgets/trust_badge.dart';
import 'package:skchat/services/peer_trust_store.dart';
import 'package:skchat/services/self_identity.dart';

void main() {
  testWidgets('compact TrustBadge exposes a Semantics label', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TrustBadge(tier: SelfTrustTier.red, compact: true),
      ),
    ));
    expect(find.bySemanticsLabel(RegExp('Untrusted')), findsOneWidget);
  });

  test('selfTierForPeer maps peer tiers to badge tiers', () {
    expect(selfTierForPeer(PeerTrustTier.red), SelfTrustTier.red);
    expect(selfTierForPeer(PeerTrustTier.amber), SelfTrustTier.amber);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/features/trust_badge_a11y_test.dart`
Expected: FAIL (no Semantics label in compact mode / `selfTierForPeer` undefined).

- [ ] **Step 3: Implement**

In `trust_badge.dart`: wrap the compact-mode colored dot in a `Semantics(label: _getDefaultLabel(), child: ...)` so the tier is announced even when no text shows. Add the top-level mapper:
```dart
import '../../../services/peer_trust_store.dart';

/// Map a peer tier onto the badge's self-tier enum (red->red, amber->amber).
SelfTrustTier selfTierForPeer(PeerTrustTier t) =>
    t == PeerTrustTier.amber ? SelfTrustTier.amber : SelfTrustTier.red;
```
Keep the existing non-compact behavior unchanged.

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/features/trust_badge_a11y_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/identity/widgets/trust_badge.dart test/features/trust_badge_a11y_test.dart
git commit -m "feat(trust): compact TrustBadge a11y label + peer-tier mapper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: verify_peer_sheet UI

**Files:**
- Create: `lib/features/identity/verify_peer_sheet.dart`
- Test: `test/features/verify_peer_sheet_test.dart`

**Interfaces:**
- Consumes: `peerTrustControllerProvider`, `peerTrustResolverProvider`, `peerTrustTierProvider` (Task 1); `safetyNumber`/`safetyCompareCode` (Task 2); `TrustBadge`, `selfTierForPeer` (Task 3); `selfIdentityProvider` for the self fingerprint.
- Produces: `Future<void> showVerifyPeerSheet(BuildContext, WidgetRef, {required String peerId, required String peerName, required String? peerFingerprint})`.

- [ ] **Step 1: Write failing test**

```dart
// test/features/verify_peer_sheet_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/identity/verify_peer_sheet.dart';
import 'package:skchat/services/peer_trust_store.dart';

void main() {
  testWidgets('Mark verified promotes the peer to amber', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Seed a sight so a record exists.
    await container
        .read(peerTrustControllerProvider)
        .recordSight('bob', 'fpBOB');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Consumer(builder: (context, ref, _) {
              return ElevatedButton(
                onPressed: () => showVerifyPeerSheet(context, ref,
                    peerId: 'bob', peerName: 'Bob', peerFingerprint: 'fpBOB'),
                child: const Text('open'),
              );
            }),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Safety number'), findsOneWidget);
    await tester.tap(find.text('Mark verified'));
    await tester.pumpAndSettle();
    expect(
        await container.read(peerTrustResolverProvider).tierFor('bob', 'fpBOB'),
        PeerTrustTier.amber);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/features/verify_peer_sheet_test.dart`
Expected: FAIL (`showVerifyPeerSheet` undefined).

- [ ] **Step 3: Implement**

Create `showVerifyPeerSheet` as a `showModalBottomSheet` that:
- Reads the self fingerprint from `selfIdentityProvider` (`.valueOrNull?.fingerprint ?? ''`).
- Renders: peer name + a `TrustBadge(tier: selfTierForPeer(tier), compact:false)`; a header "Safety number"; the `safetyNumber(selfFp, peerFingerprint ?? '')` in a large grouped monospace `Text`; the peer fingerprint; a show-only `QrImageView` (from `qr_flutter`) of `peerFingerprint`.
- If `await resolver.isKeyChanged(peerId, peerFingerprint)` is true, lead with a red warning Container: "Safety number changed. The peer's key differs from what you verified before. Only mark verified again if you trust this change."
- A "Mark verified" `ElevatedButton` -> `ref.read(peerTrustControllerProvider).markVerified(peerId, peerFingerprint!)` then `Navigator.pop`. Disable it when `peerFingerprint` is null/empty (nothing to anchor).
Follow the sheet style used by `call_device_picker.dart`'s `_DevicePickerSheet` (SovereignColors, rounded top). Keep it under 80 cols.

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/features/verify_peer_sheet_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/identity/verify_peer_sheet.dart test/features/verify_peer_sheet_test.dart
git commit -m "feat(trust): safety-number verify-peer sheet

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: 1:1 call gate

**Files:**
- Create: `lib/features/calls/call_gate.dart` (pure predicate + affordance helper)
- Modify: `lib/features/conversation/conversation_screen.dart` (the call button path around lines 400-410 + 675)
- Test: `test/features/call_gate_test.dart`

**Interfaces:**
- Consumes: `PeerTrustTier` (Task 1), `showVerifyPeerSheet` (Task 4).
- Produces: `bool canCall(PeerTrustTier tier)` (false for red, true for amber).

- [ ] **Step 1: Write failing test**

```dart
// test/features/call_gate_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/call_gate.dart';
import 'package:skchat/services/peer_trust_store.dart';

void main() {
  test('canCall blocks red, allows amber', () {
    expect(canCall(PeerTrustTier.red), isFalse);
    expect(canCall(PeerTrustTier.amber), isTrue);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/features/call_gate_test.dart`
Expected: FAIL (`canCall` undefined).

- [ ] **Step 3: Implement**

Create `call_gate.dart`:
```dart
import '../../services/peer_trust_store.dart';

/// A 1:1 voice/video call is allowed only to an amber+ peer. A red peer
/// (TOFU/unverified or key-changed) must be verified first (Chef's rule).
bool canCall(PeerTrustTier tier) => tier != PeerTrustTier.red;
```

In `conversation_screen.dart`: the call button (`Icons.call_outlined`, ~line 675) currently calls the start-call path (`svc.startCall(peerId)`, ~400-410). Before starting, resolve the peer tier via `ref.read(peerTrustResolverProvider).tierFor(peerId, peerFingerprint)` (the conversation carries `soulFingerprint`); if `!canCall(tier)`, do NOT start. Instead show a SnackBar "Verify <name> before calling" with a "Verify" action that calls `showVerifyPeerSheet(...)`. Also render the call `IconButton` visibly de-emphasized (e.g. reduced opacity + a small lock overlay) when the peer is red, reading the tier via `ref.watch(peerTrustTierProvider((peerId: peerId, fingerprint: peerFingerprint)))`. Do not block the group-call branch (the same button handles group vs 1:1; gate only the 1:1 `peerId` case).

- [ ] **Step 4: Run to verify it passes**

Run: `export PATH=/home/cbrd21/flutter/bin:$PATH && flutter test test/features/call_gate_test.dart && flutter analyze lib/features/conversation/conversation_screen.dart lib/features/calls/call_gate.dart`
Expected: PASS + analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add lib/features/calls/call_gate.dart lib/features/conversation/conversation_screen.dart test/features/call_gate_test.dart
git commit -m "feat(trust): gate 1:1 calls on peer verification

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Tasks 6a-6d: per-peer badge placements (INDEPENDENT, fan out to parallel agents)

Each task adds a compact `TrustBadge(tier: selfTierForPeer(tier), compact: true)` to one surface, reading `ref.watch(peerTrustTierProvider((peerId: <id>, fingerprint: <fp>))).valueOrNull ?? PeerTrustTier.red`, and calls `ref.read(peerTrustControllerProvider).recordSight(<id>, <fp>)` on first observation (guard against repeated writes by only calling once per build/mount, e.g. in an `initState`/`ref.listen` or a post-frame callback). No fingerprint => render nothing. Each touches a DIFFERENT file, so 6a-6d can run concurrently.

**6a — DM header badge**
- Modify: `lib/features/conversation/conversation_screen.dart` app bar title area (peer name). Add the badge next to the name using the conversation's `peerId` + `soulFingerprint`. (Coordinate with Task 5 which also edits this file: if both run, sequence 6a AFTER Task 5, or merge into Task 5's commit.)

**6b — inbox row badge**
- Modify: the `ConversationTile` widget used by `lib/features/chats/chats_screen.dart` (find its definition). Add a compact badge on non-group rows only (`!conversation.isGroup`), using `conversation.peerId` + `conversation.soulFingerprint`. Test: `test/features/inbox_badge_test.dart` pumping a ConversationTile with a seeded amber peer asserts an amber semantics label.

**6c — group member badge**
- Modify: the group member row surface (under `lib/features/groups/`; find the member list). Add a compact badge per member that has a resolvable fingerprint. Members without one show no badge.

**6d — Space participant badge**
- Modify: `lib/features/spaces/space_room_screen.dart` speaker/participant tiles. Add a small badge on each participant avatar using the participant identity + fingerprint IF the snapshot carries one; if `LiveKitParticipantSnapshot` has no fingerprint, SKIP this task and note that a fingerprint must be plumbed through the snapshot first (do not fabricate one).

Each 6x task: write a minimal widget test where practical, place the badge following the surrounding style, run `flutter analyze` on the touched file, commit with `feat(trust): <surface> peer badge`.

---

### Task 7: build + drive verification on .41

**Files:** none (verification).

- [ ] **Step 1:** Merge the branch state, build on .41 (`ssh laptop`, non-snap `~/flutter`, `flutter build linux --release --dart-define-from-file=config/lumina.json`), relaunch on `:0`.
- [ ] **Step 2:** Drive via xdotool + screenshots (window class `io.skworld.skchat`): open a DM, confirm a red badge on the peer; tap call, confirm it is blocked with "Verify to call"; open the verify sheet, confirm the safety number renders; tap "Mark verified", confirm the badge flips amber and the call is now allowed. Screenshot each step.
- [ ] **Step 3:** Record PASS/FAIL per surface. If a surface lacks a fingerprint (6c/6d), note it for a follow-up rather than faking one.
- [ ] **Step 4:** Use `superpowers:finishing-a-development-branch`.

---

## Self-Review

**Spec coverage:** PeerTrustStore/TOFU + tier (Task 1); safety number (Task 2); TrustBadge a11y + mapper (Task 3); verify sheet (Task 4); call gate (Task 5); badges on all four surfaces (6a-6d); build/drive verify (Task 7). All spec components covered. ✓

**Placeholder scan:** logic tasks (1,2,3,5) carry complete code; UI-integration tasks (4, 6a-6d) give the exact provider contract + widget usage + file/anchor and instruct fitting the existing tree (the correct level for UI placement). The one genuine unknown (does `LiveKitParticipantSnapshot` carry a fingerprint) is called out explicitly in 6d with a skip-and-report instruction, not hand-waved. ✓

**Type consistency:** `PeerTrustTier{red,amber}`, `PeerTrustResolver.{tierFor,recordSight,markVerified,isKeyChanged}`, `peerTrustTierProvider.family<PeerTrustTier, ({String peerId, String? fingerprint})>`, `selfTierForPeer`, `canCall`, `safetyNumber`/`safetyCompareCode`, `showVerifyPeerSheet` are named identically across all tasks. ✓
