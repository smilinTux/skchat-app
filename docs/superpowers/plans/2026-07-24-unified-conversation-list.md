# Unified Conversation List (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold group conversations into the single Chats list (iMessage-style) with composite group avatars and one aggregate trust badge per group, and retire the separate Groups surface.

**Architecture:** The server already returns groups in the conversation list (`is_group:true`). This phase (1) adds per-member `participants` (with server-resolved `soul_fingerprint`) to that payload, (2) parses them into a new `Conversation.members` seam on the client, (3) renders group tiles inline in `ConversationTile` (composite avatar + aggregate badge folded from each member's `peerTrustTierProvider` tier), and (4) removes every entry point to the standalone `GroupsScreen`, routing group tiles into the existing `ConversationScreen` group mode. Group management stays in `group_info_screen`; group creation stays in `create_group_screen`.

**Tech Stack:** Flutter + Riverpod (`flutter_riverpod`), `go_router`, Hive (trust store), `mocktail`/`flutter_test`; Python server (`skchat` daemon_proxy, FastAPI), `pytest`.

## Global Constraints

- **No em/en dashes** anywhere (code, comments, docs, commit messages). Use commas, colons, parentheses, or new sentences. A stop hook enforces this on chat.
- **Reuse, do not fork** these existing seams: `peerTrustTierProvider` / `PeerTrustResolver` (trust), `TrustBadge` + `selfTierForPeer` (badge render), `member_to_app` + `fingerprint_for_identity` (server member shape). No client-side identity->fingerprint resolution: the fingerprint is always server-set (the M1b unspoofability invariant).
- **Keyless == no badge.** A member/peer whose fingerprint is null, empty, or equal to its peerId is `unverifiable` and must render no trust dot, ever. Never fabricate a key.
- **Trust store in widget tests must be in-memory.** Real Hive I/O never completes under widget-test fake async and leaves the tier provider stuck on `AsyncLoading`, masking the real render. Override `peerTrustResolverProvider` with `PeerTrustResolver(_MemStore())` (pattern in `test/features/chats/conversation_tile_badge_test.dart`).
- **Python style:** line length 99, ruff (E, W, F, I; ignore E501). Run server tests from `~` (never from `smilintux-org/`) to avoid the `skmemory` namespace collision: `cd ~ && ~/.skenv/bin/python -m pytest tests/ -q`.
- **Flutter tests:** run from the repo root: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test <path>`.

---

## File Structure

**Client (`skchat-app`):**
- `lib/models/conversation.dart` (MODIFY) — add `ConversationMember` class + `Conversation.members` field + `participants` parse.
- `lib/features/chats/group_trust.dart` (CREATE) — pure `foldGroupTier()` aggregate function.
- `lib/features/chats/widgets/group_composite_avatar.dart` (CREATE) — stacked member-initial avatar for group tiles.
- `lib/features/chats/widgets/conversation_tile.dart` (MODIFY) — render group mode (composite avatar + aggregate badge).
- `lib/features/chats/chats_screen.dart` (MODIFY) — remove the app-bar "Groups" button.
- `lib/features/shell/app_shell.dart` (MODIFY) — drop `AppRoutes.groups` from the Ops-highlight set.
- `lib/features/hub/hub_screen.dart` (MODIFY) — remove the "Groups" Ops tile.
- `lib/core/modules/module_registry.dart` (MODIFY) — remove the "Groups" module entry.
- `lib/core/router/app_router.dart` (MODIFY) — remove the bare `/groups` list route + `GroupsScreen` import (keep `/groups/:groupId/info` and `/groups/new`).
- `lib/features/groups/group_info_screen.dart` (MODIFY) — repoint post-leave nav `AppRoutes.groups` -> `AppRoutes.chats`.
- `lib/features/groups/create_group_screen.dart` (MODIFY) — repoint post-create nav `AppRoutes.groups` -> `AppRoutes.chats`.
- `lib/features/groups/groups_screen.dart` (DELETE) — the retired surface.
- `test/models/conversation_members_test.dart` (CREATE)
- `test/features/chats/group_trust_test.dart` (CREATE)
- `test/features/chats/group_composite_avatar_test.dart` (CREATE)
- `test/features/chats/conversation_tile_group_test.dart` (CREATE)
- `test/features/shell/app_shell_nav_test.dart` (MODIFY)
- `test/features/hub/hub_screen_test.dart` (MODIFY)
- `test/features/groups/groups_screen_test.dart` (DELETE)

**Server (`skchat`):**
- `src/skchat/daemon_proxy_groups.py` (MODIFY) — `group_to_conversation()` gains a `fingerprint_for` callable and emits `participants`.
- `src/skchat/daemon_proxy.py` (MODIFY) — `_group_conversations()` passes the resolver.
- `tests/test_daemon_proxy_groups.py` (MODIFY) — participant-embedding tests.

**Kept as-is (reused, not forked):** `lib/services/peer_trust_store.dart`, `lib/features/identity/widgets/trust_badge.dart`, `lib/features/groups/group_info_screen.dart` (management), `lib/features/groups/create_group_screen.dart` (compose target), `src/skchat/daemon_proxy_groups.py:member_to_app`, `src/skchat/daemon_proxy.py:fingerprint_for_identity`.

---

## Task 1: `Conversation.members` data seam

**Files:**
- Modify: `lib/models/conversation.dart`
- Test: `test/models/conversation_members_test.dart`

**Interfaces:**
- Consumes: nothing (leaf model).
- Produces:
  - `class ConversationMember { final String identityUri; final String displayName; final String? soulFingerprint; }` with `ConversationMember.fromJson(Map<String,dynamic>)`.
  - `Conversation.members` -> `List<ConversationMember>` (default `const []`), populated from the JSON `participants` array. Present on `Conversation`'s constructor + `copyWith` + `fromJson`.

- [ ] **Step 1: Write the failing test**

Create `test/models/conversation_members_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/models/conversation.dart';

void main() {
  group('ConversationMember.fromJson', () {
    test('parses identity, name, and soul_fingerprint', () {
      final m = ConversationMember.fromJson({
        'identity_uri': 'capauth:lumina@skworld.io',
        'display_name': 'Lumina',
        'soul_fingerprint': '02BC0EB3CAD31DB691A753C70C5629AB893F9746',
      });
      expect(m.identityUri, 'capauth:lumina@skworld.io');
      expect(m.displayName, 'Lumina');
      expect(m.soulFingerprint, '02BC0EB3CAD31DB691A753C70C5629AB893F9746');
    });

    test('reads the fingerprint alias when soul_fingerprint absent', () {
      final m = ConversationMember.fromJson({
        'identity_uri': 'steward@skworld.io',
        'display_name': 'Steward',
        'fingerprint': '4E06A71935D1DF1FB9848112D8634AB3E7B55236',
      });
      expect(m.soulFingerprint, '4E06A71935D1DF1FB9848112D8634AB3E7B55236');
    });

    test('missing fields default to empty / null', () {
      final m = ConversationMember.fromJson({});
      expect(m.identityUri, '');
      expect(m.displayName, '');
      expect(m.soulFingerprint, isNull);
    });
  });

  group('Conversation.members', () {
    test('defaults to empty when no participants key', () {
      final c = Conversation.fromJson({
        'peer_id': 'steward@skworld.io',
        'display_name': 'Steward',
      });
      expect(c.members, isEmpty);
    });

    test('parses group participants into members', () {
      final c = Conversation.fromJson({
        'peer_id': 'g-1',
        'display_name': 'Penguins',
        'is_group': true,
        'member_count': 2,
        'participants': [
          {
            'identity_uri': 'capauth:lumina@skworld.io',
            'display_name': 'Lumina',
            'soul_fingerprint': 'AAAA1111',
          },
          {
            'identity_uri': 'steward@skworld.io',
            'display_name': 'Steward',
            'fingerprint': 'BBBB2222',
          },
        ],
      });
      expect(c.isGroup, isTrue);
      expect(c.members, hasLength(2));
      expect(c.members[0].displayName, 'Lumina');
      expect(c.members[0].soulFingerprint, 'AAAA1111');
      expect(c.members[1].soulFingerprint, 'BBBB2222');
    });

    test('copyWith preserves members', () {
      final c = Conversation.fromJson({
        'peer_id': 'g-1',
        'display_name': 'Penguins',
        'is_group': true,
        'participants': [
          {'identity_uri': 'a@x', 'display_name': 'A', 'soul_fingerprint': 'FP'},
        ],
      });
      final c2 = c.copyWith(unreadCount: 3);
      expect(c2.members, hasLength(1));
      expect(c2.members.first.soulFingerprint, 'FP');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/models/conversation_members_test.dart`
Expected: FAIL — `ConversationMember` is undefined and `Conversation` has no `members`.

- [ ] **Step 3: Write minimal implementation**

In `lib/models/conversation.dart`, add the member class ABOVE `class Conversation`:

```dart
/// One participant of a group conversation, carrying the identity plus the
/// real capauth soul-fingerprint needed to anchor a per-member trust tier
/// (and the folded aggregate group badge). Mirrors GroupMemberInfo's parse
/// keys so the server emits ONE member shape for both /groups/:id/members and
/// the participants embedded in /conversations.
class ConversationMember {
  const ConversationMember({
    required this.identityUri,
    required this.displayName,
    this.soulFingerprint,
  });

  final String identityUri;
  final String displayName;

  /// Real capauth fingerprint from the peer store (server-resolved). Null or
  /// empty for a keyless member (keyless -> no badge, never a fabricated key).
  final String? soulFingerprint;

  factory ConversationMember.fromJson(Map<String, dynamic> json) {
    return ConversationMember(
      identityUri: json['identity_uri'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      // Server emits both the conversation-contract key and the peer alias.
      soulFingerprint: (json['soul_fingerprint'] as String?) ??
          (json['fingerprint'] as String?),
    );
  }
}
```

In `class Conversation`: add the field, constructor param, copyWith param + wiring, and fromJson parse.

Add to the constructor parameter list (after `this.avatarUrl,`):
```dart
    this.members = const [],
```

Add the field (after `final String? avatarUrl;`):
```dart
  /// Group participants (empty for a 1:1). Populated from the server
  /// `participants` array; drives the composite avatar + aggregate badge.
  final List<ConversationMember> members;
```

Add to `copyWith` signature (after `String? avatarUrl,`):
```dart
    List<ConversationMember>? members,
```
and to its returned `Conversation(...)` (after `avatarUrl: avatarUrl ?? this.avatarUrl,`):
```dart
      members: members ?? this.members,
```

Add to `fromJson`'s returned `Conversation(...)` (after `avatarUrl: json['avatar_url'] as String?,`):
```dart
      members: (json['participants'] as List<dynamic>?)
              ?.map((e) =>
                  ConversationMember.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/models/conversation_members_test.dart`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/models/conversation.dart test/models/conversation_members_test.dart
git commit -m "feat(chats): add Conversation.members participant seam"
```

---

## Task 2: Server embeds group `participants` with soul_fingerprint

**Files:**
- Modify: `src/skchat/daemon_proxy_groups.py:556` (`group_to_conversation`)
- Modify: `src/skchat/daemon_proxy.py:824` (`_group_conversations`)
- Test: `tests/test_daemon_proxy_groups.py`

**Interfaces:**
- Consumes: existing `member_to_app(member, *, online_uris, fingerprint)` and `fingerprint_for_identity(identity, index)`.
- Produces: `group_to_conversation(group, *, online_uris=None, fingerprint_for=None)` now returns a dict that includes `"participants": [ member_to_app(...) ]` (empty fingerprints when `fingerprint_for` is None). The Flutter `Conversation.fromJson` from Task 1 reads this array.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_daemon_proxy_groups.py` (imports `GroupChat`, `MemberRole`, and `daemon_proxy_groups as G` already exist at the top of the file):

```python
def test_group_to_conversation_embeds_participants_with_fingerprints():
    group = GroupChat(name="Ops", kem_suite="rsa-pgp-wrap-v1")
    group.add_member("capauth:lumina@skworld.io", role=MemberRole.ADMIN)
    group.add_member("steward@skworld.io", role=MemberRole.MEMBER)

    fps = {
        "capauth:lumina@skworld.io": "AAAA1111",
        "steward@skworld.io": "BBBB2222",
    }
    conv = G.group_to_conversation(group, fingerprint_for=lambda i: fps.get(i, ""))

    assert conv["is_group"] is True
    parts = conv["participants"]
    assert {p["identity_uri"] for p in parts} == set(fps)
    by_id = {p["identity_uri"]: p for p in parts}
    assert by_id["capauth:lumina@skworld.io"]["soul_fingerprint"] == "AAAA1111"
    assert by_id["steward@skworld.io"]["soul_fingerprint"] == "BBBB2222"


def test_group_to_conversation_participants_default_empty_fingerprint():
    group = GroupChat(name="Ops", kem_suite="rsa-pgp-wrap-v1")
    group.add_member("capauth:chef@skworld.io", role=MemberRole.ADMIN)
    conv = G.group_to_conversation(group)  # no resolver passed
    assert conv["participants"][0]["soul_fingerprint"] == ""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~ && ~/.skenv/bin/python -m pytest ~/clawd/skcapstone-repos/skchat/tests/test_daemon_proxy_groups.py -q -k participants`
Expected: FAIL — `group_to_conversation` has no `fingerprint_for` kwarg / no `participants` key.

- [ ] **Step 3: Write minimal implementation**

In `src/skchat/daemon_proxy_groups.py`, ensure `Callable` is imported. Find the typing import near the top (it already imports `Optional`) and add `Callable`:
```python
from typing import Any, Callable, Optional
```
(Merge with whatever `typing` names are already imported; do not duplicate the line.)

Change the `group_to_conversation` signature and body:

```python
def group_to_conversation(
    group,
    *,
    online_uris: Optional[set[str]] = None,
    fingerprint_for: Optional[Callable[[str], str]] = None,
) -> dict:
    """Map a ``GroupChat`` to the app conversation shape (``is_group:true``).

    Matches ``Conversation.fromJson`` + ``GroupsNotifier`` expectations:
    ``peer_id`` (== group id), ``display_name``, ``is_group``, ``member_count``,
    ``last_message``, ``last_message_time``. When [fingerprint_for] is given,
    each participant carries the member's real capauth ``soul_fingerprint`` so
    the unified list can fold an aggregate group trust badge (empty string ->
    keyless -> no badge; never a fabricated key).
    """
    participants = [
        member_to_app(
            m,
            online_uris=online_uris,
            fingerprint=(fingerprint_for(m.identity_uri) if fingerprint_for else ""),
        )
        for m in group.members
    ]
    return {
        "peer_id": group.id,
        "display_name": group.name,
        "last_message": (group.metadata.get("last_message") or ""),
        "last_message_time": (group.metadata.get("last_message_time") or group.updated_at.isoformat()),
        "soul_fingerprint": group.id,
        "is_online": False,
        "is_agent": False,
        "unread_count": 0,
        "last_delivery_status": "delivered",
        "is_group": True,
        "member_count": group.member_count,
        "avatar_url": "",
        "description": group.description,
        "acl": _acl(group),
        "participants": participants,
        # Observable encryption posture: the app can render a lock/warning and the
        # operator can always tell sealed vs cleartext vs degraded (flag on, not
        # sealing) — no silent state.
        "encryption": group_encryption_status(group),
    }
```

Then in `src/skchat/daemon_proxy.py`, update `_group_conversations` to pass the resolver (reusing the same peer-fingerprint index the members route builds):

```python
def _group_conversations() -> list[dict]:
    """All persisted groups in the app conversation shape (``is_group:true``),
    each carrying per-member ``participants`` with server-resolved
    ``soul_fingerprint`` so the unified list can fold an aggregate group badge.
    """
    from skchat import daemon_proxy_groups as G

    out: list[dict] = []
    try:
        idx = _peer_fingerprint_index()
        for grp in G.list_groups():
            out.append(
                G.group_to_conversation(
                    grp,
                    fingerprint_for=lambda i: fingerprint_for_identity(i, idx),
                )
            )
    except Exception:
        logger.exception("group conversation list failed")
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~ && ~/.skenv/bin/python -m pytest ~/clawd/skcapstone-repos/skchat/tests/test_daemon_proxy_groups.py -q`
Expected: PASS (new participant tests pass; the pre-existing `test_conversation_exposes_encryption_status` and others still pass, since only an additive `participants` key was introduced).

- [ ] **Step 5: Commit**

```bash
cd ~/clawd/skcapstone-repos/skchat
git add src/skchat/daemon_proxy_groups.py src/skchat/daemon_proxy.py tests/test_daemon_proxy_groups.py
git commit -m "feat(daemon_proxy): embed per-member soul_fingerprint in group participants"
```

---

## Task 3: Aggregate group trust fold (pure function)

**Files:**
- Create: `lib/features/chats/group_trust.dart`
- Test: `test/features/chats/group_trust_test.dart`

**Interfaces:**
- Consumes: `PeerTrustTier` enum (`red`, `amber`, `unverifiable`) from `lib/services/peer_trust_store.dart`.
- Produces: `PeerTrustTier? foldGroupTier(Iterable<PeerTrustTier?> memberTiers)`. Returns `red` if any keyed member is unverified, `amber` if all keyed members are verified, and `null` (no badge) when no member has a real key. `null` entries (tier still resolving / member with no key) are treated as not-keyed.

- [ ] **Step 1: Write the failing test**

Create `test/features/chats/group_trust_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/group_trust.dart';
import 'package:skchat/services/peer_trust_store.dart';

void main() {
  group('foldGroupTier', () {
    test('no keyed members -> null (no badge)', () {
      expect(foldGroupTier([]), isNull);
      expect(foldGroupTier([null, null]), isNull);
      expect(
        foldGroupTier([PeerTrustTier.unverifiable, PeerTrustTier.unverifiable]),
        isNull,
      );
    });

    test('any keyed-but-unverified member -> red', () {
      expect(
        foldGroupTier([PeerTrustTier.amber, PeerTrustTier.red]),
        PeerTrustTier.red,
      );
      expect(
        foldGroupTier([PeerTrustTier.unverifiable, PeerTrustTier.red]),
        PeerTrustTier.red,
      );
    });

    test('all keyed members verified -> amber', () {
      expect(
        foldGroupTier([PeerTrustTier.amber, PeerTrustTier.amber]),
        PeerTrustTier.amber,
      );
      expect(
        foldGroupTier([PeerTrustTier.unverifiable, PeerTrustTier.amber]),
        PeerTrustTier.amber,
      );
    });

    test('a still-loading (null) tier does not force a badge on its own', () {
      expect(foldGroupTier([null, PeerTrustTier.unverifiable]), isNull);
      expect(foldGroupTier([null, PeerTrustTier.amber]), PeerTrustTier.amber);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/chats/group_trust_test.dart`
Expected: FAIL — `foldGroupTier` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/chats/group_trust.dart`:

```dart
import '../../services/peer_trust_store.dart';

/// Fold each group member's trust tier into ONE aggregate tier for the tile.
///
/// - Only members with a real key count (tier `red` or `amber`); a `null`
///   (still resolving, or watched-but-keyless) or `unverifiable` tier is
///   ignored, exactly like a keyless 1:1 peer shows no dot.
/// - `red` if ANY keyed member is unverified (weakest link wins).
/// - `amber` if every keyed member is verified.
/// - `null` if no member has a real key -> the tile shows no badge.
PeerTrustTier? foldGroupTier(Iterable<PeerTrustTier?> memberTiers) {
  var anyKeyed = false;
  for (final t in memberTiers) {
    if (t == PeerTrustTier.red) return PeerTrustTier.red;
    if (t == PeerTrustTier.amber) anyKeyed = true;
  }
  return anyKeyed ? PeerTrustTier.amber : null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/chats/group_trust_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/chats/group_trust.dart test/features/chats/group_trust_test.dart
git commit -m "feat(chats): aggregate group trust fold"
```

---

## Task 4: Group composite avatar widget

**Files:**
- Create: `lib/features/chats/widgets/group_composite_avatar.dart`
- Test: `test/features/chats/group_composite_avatar_test.dart`

**Interfaces:**
- Consumes: `ConversationMember` (Task 1); `SovereignColors.fromFingerprint` + `SovereignColors.textSecondary` from `lib/core/theme/sovereign_colors.dart`.
- Produces: `class GroupCompositeAvatar extends StatelessWidget` with `const GroupCompositeAvatar({required List<ConversationMember> members, required Color fallbackColor, this.size = 48})`. Renders up to 3 stacked soul-color initial chips; falls back to a single group-icon disc when `members` is empty.

- [ ] **Step 1: Write the failing test**

Create `test/features/chats/group_composite_avatar_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/theme/sovereign_colors.dart';
import 'package:skchat/features/chats/widgets/group_composite_avatar.dart';
import 'package:skchat/models/conversation.dart';

ConversationMember _m(String name, {String? fp}) =>
    ConversationMember(identityUri: '$name@x', displayName: name, soulFingerprint: fp);

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('renders one initial per member, capped at 3', (tester) async {
    await tester.pumpWidget(_host(GroupCompositeAvatar(
      members: [
        _m('Lumina', fp: 'AAAA1111'),
        _m('Steward', fp: 'BBBB2222'),
        _m('Chef'),
        _m('Opus'),
      ],
      fallbackColor: SovereignColors.textSecondary,
    )));

    // First initial of the first three members, in order; the 4th is dropped.
    expect(find.text('L'), findsOneWidget);
    expect(find.text('S'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('O'), findsNothing);
  });

  testWidgets('empty members falls back to a group icon', (tester) async {
    await tester.pumpWidget(_host(const GroupCompositeAvatar(
      members: [],
      fallbackColor: SovereignColors.textSecondary,
    )));
    expect(find.byIcon(Icons.group_rounded), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/chats/group_composite_avatar_test.dart`
Expected: FAIL — `GroupCompositeAvatar` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/features/chats/widgets/group_composite_avatar.dart`:

```dart
import 'package:flutter/material.dart';
import '../../../core/theme/sovereign_colors.dart';
import '../../../models/conversation.dart';

/// Composite avatar for a group tile: up to 3 stacked soul-color initial chips,
/// derived purely from the member list. Falls back to a single group-icon disc
/// when there are no members. Pure presentational (no providers) so it is cheap
/// to rebuild inside a ListView and trivially widget-testable.
class GroupCompositeAvatar extends StatelessWidget {
  const GroupCompositeAvatar({
    super.key,
    required this.members,
    required this.fallbackColor,
    this.size = 48,
  });

  final List<ConversationMember> members;
  final Color fallbackColor;
  final double size;

  Color _memberColor(ConversationMember m) {
    final fp = m.soulFingerprint;
    if (fp != null && fp.isNotEmpty) {
      return SovereignColors.fromFingerprint(fp);
    }
    return fallbackColor;
  }

  String _initial(ConversationMember m) {
    final n = m.displayName.trim();
    return n.isNotEmpty ? n[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: fallbackColor.withValues(alpha: 0.6), width: 2),
          color: fallbackColor.withValues(alpha: 0.12),
        ),
        child: Center(
          child: Icon(Icons.group_rounded, color: fallbackColor, size: size * 0.46),
        ),
      );
    }

    final shown = members.take(3).toList();
    final chip = size * 0.62;
    // Two anchor points top row, one centered below, so 1-3 chips all read as a
    // cluster within the standard 48px avatar footprint.
    final offsets = <Offset>[
      Offset(0, 0),
      Offset(size - chip, 0),
      Offset((size - chip) / 2, size - chip),
    ];

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: offsets[i].dx,
              top: offsets[i].dy,
              child: _InitialChip(
                initial: _initial(shown[i]),
                color: _memberColor(shown[i]),
                diameter: chip,
              ),
            ),
        ],
      ),
    );
  }
}

class _InitialChip extends StatelessWidget {
  const _InitialChip({
    required this.initial,
    required this.color,
    required this.diameter,
  });

  final String initial;
  final Color color;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.22),
        border: Border.all(color: SovereignColors.surfaceBase, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontSize: diameter * 0.42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/chats/group_composite_avatar_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/features/chats/widgets/group_composite_avatar.dart test/features/chats/group_composite_avatar_test.dart
git commit -m "feat(chats): group composite avatar widget"
```

---

## Task 5: Render group tiles inline in `ConversationTile`

**Files:**
- Modify: `lib/features/chats/widgets/conversation_tile.dart`
- Test: `test/features/chats/conversation_tile_group_test.dart`

**Interfaces:**
- Consumes: `foldGroupTier` (Task 3), `GroupCompositeAvatar` (Task 4), `Conversation.members` (Task 1), existing `peerTrustTierProvider` + `TrustBadge` + `selfTierForPeer`.
- Produces: a `ConversationTile` that, when `conversation.isGroup`, renders the composite avatar and one aggregate trust badge (folded from each member's watched tier). 1:1 rendering is unchanged.

- [ ] **Step 1: Write the failing test**

Create `test/features/chats/conversation_tile_group_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/widgets/conversation_tile.dart';
import 'package:skchat/features/chats/widgets/group_composite_avatar.dart';
import 'package:skchat/features/identity/widgets/trust_badge.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/peer_trust_store.dart';

/// In-memory trust store (Hive-free) so the tier resolver settles under widget
/// test fake async instead of sticking on AsyncLoading.
class _MemStore implements PeerTrustStore {
  final Map<String, PeerTrustRecord> _m;
  _MemStore([Map<String, PeerTrustRecord>? seed]) : _m = seed ?? {};
  @override
  Future<Map<String, PeerTrustRecord>> load() async => _m;
  @override
  Future<void> save(Map<String, PeerTrustRecord> records) async {
    _m
      ..clear()
      ..addAll(records);
  }
}

Conversation _group(List<ConversationMember> members) => Conversation(
      peerId: 'g-1',
      displayName: 'Penguins',
      lastMessage: 'hi team',
      lastMessageTime: DateTime(2026, 7, 24, 12),
      isGroup: true,
      memberCount: members.length,
      members: members,
    );

ConversationMember _m(String name, {String? fp}) =>
    ConversationMember(identityUri: '$name@skworld.io', displayName: name, soulFingerprint: fp);

Widget _host(Conversation c, {PeerTrustStore? store}) => ProviderScope(
      overrides: [
        peerTrustResolverProvider
            .overrideWithValue(PeerTrustResolver(store ?? _MemStore())),
      ],
      child: MaterialApp(
        home: Scaffold(body: ConversationTile(conversation: c, onTap: () {})),
      ),
    );

void main() {
  testWidgets('group tile renders a composite avatar', (tester) async {
    await tester.pumpWidget(_host(_group([
      _m('Lumina', fp: 'AAAA1111'),
      _m('Steward', fp: 'BBBB2222'),
    ])));
    await tester.pumpAndSettle();
    expect(find.byType(GroupCompositeAvatar), findsOneWidget);
  });

  testWidgets('any keyed-but-unverified member shows the aggregate badge (red)',
      (tester) async {
    await tester.pumpWidget(_host(_group([
      _m('Lumina', fp: 'AAAA1111'), // keyed, never verified -> red
      _m('Chef'), // keyless
    ])));
    await tester.pumpAndSettle();
    expect(find.byType(TrustBadge), findsOneWidget);
  });

  testWidgets('all-keyless group shows NO badge', (tester) async {
    await tester.pumpWidget(_host(_group([
      _m('Chef'),
      _m('Guest'),
    ])));
    await tester.pumpAndSettle();
    expect(find.byType(TrustBadge), findsNothing);
  });

  testWidgets('all-verified group shows the aggregate badge (amber)',
      (tester) async {
    final store = _MemStore();
    // Pre-verify both keyed members so their tier resolves to amber.
    final r = PeerTrustResolver(store);
    await r.markVerifyFlow('Lumina@skworld.io', 'AAAA1111');
    await r.markVerifyFlow('Steward@skworld.io', 'BBBB2222');

    await tester.pumpWidget(_host(
      _group([_m('Lumina', fp: 'AAAA1111'), _m('Steward', fp: 'BBBB2222')]),
      store: store,
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TrustBadge), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/chats/conversation_tile_group_test.dart`
Expected: FAIL — group rows currently render `SoulAvatar` (not `GroupCompositeAvatar`) and never a badge, so the composite-avatar and red/amber assertions fail.

- [ ] **Step 3: Write minimal implementation**

In `lib/features/chats/widgets/conversation_tile.dart`:

Add imports (after the existing `import '../../../services/peer_trust_store.dart';` line):
```dart
import '../group_trust.dart';
import 'group_composite_avatar.dart';
```

Replace the tier-resolution block (currently lines ~37-47, the `final tier = _isDirect ? ... ;` through `final showBadge = ...;`) with a branch that also folds the group aggregate:

```dart
    // 1:1 tier: resolve for any direct row (the provider maps a
    // missing/keyless/peerId-fallback fingerprint to `unverifiable`).
    final directTier = _isDirect
        ? ref
            .watch(peerTrustTierProvider(
                (peerId: conversation.peerId,
                    fingerprint: conversation.soulFingerprint)))
            .valueOrNull
        : null;

    // Group tier: watch each member's tier (memoized per (peerId,fingerprint)
    // across the app) and fold to one aggregate. red if any keyed member is
    // unverified, amber if all keyed are verified, null if keyless.
    final PeerTrustTier? groupTier = _isDirect
        ? null
        : foldGroupTier(conversation.members.map((m) => ref
            .watch(peerTrustTierProvider(
                (peerId: m.identityUri, fingerprint: m.soulFingerprint)))
            .valueOrNull));

    final PeerTrustTier? badgeTier = _isDirect ? directTier : groupTier;
    // A badge only makes sense for a REAL key (red = unverified, amber =
    // verified); unverifiable/none shows nothing.
    final showBadge =
        badgeTier == PeerTrustTier.red || badgeTier == PeerTrustTier.amber;
```

Replace the avatar (`SoulAvatar(...)`, currently ~lines 67-73) with a group/direct branch:

```dart
            if (_isDirect)
              SoulAvatar(
                soulColor: soul,
                initials: conversation.resolvedInitials,
                isOnline: conversation.isOnline,
                isAgent: conversation.isAgent,
                size: 48,
              )
            else
              GroupCompositeAvatar(
                members: conversation.members,
                fallbackColor: soul,
                size: 48,
              ),
```

Update the badge render (currently `TrustBadge(tier: selfTierForPeer(tier!), compact: true)`) to use `badgeTier`:

```dart
                      if (showBadge) ...[
                        const SizedBox(width: 6),
                        TrustBadge(
                            tier: selfTierForPeer(badgeTier!), compact: true),
                      ],
```

(The `_RecordPeerSight` block stays gated on `if (_isDirect)` unchanged; groups do not record a single-peer sight.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/chats/conversation_tile_group_test.dart test/features/chats/conversation_tile_badge_test.dart`
Expected: PASS (new group tests pass; the two pre-existing 1:1 badge tests still pass, proving no direct-row regression).

- [ ] **Step 5: Commit**

```bash
git add lib/features/chats/widgets/conversation_tile.dart test/features/chats/conversation_tile_group_test.dart
git commit -m "feat(chats): render group tiles inline (composite avatar + aggregate badge)"
```

---

## Task 6: Retire the standalone Groups surface

**Files:**
- Modify: `lib/features/chats/chats_screen.dart:86-92` (remove the "Groups" app-bar button)
- Modify: `lib/features/shell/app_shell.dart:65-66` (drop `AppRoutes.groups` from the Ops-highlight set)
- Modify: `lib/features/hub/hub_screen.dart:95-101` (remove the "Groups" Ops tile)
- Modify: `lib/core/modules/module_registry.dart:~133-138` (remove the "Groups" module entry)
- Modify: `lib/core/router/app_router.dart` (remove `import '.../groups_screen.dart';` and the bare `/groups` list `GoRoute`)
- Modify: `lib/features/groups/group_info_screen.dart:1018` (`AppRoutes.groups` -> `AppRoutes.chats`)
- Modify: `lib/features/groups/create_group_screen.dart:456` (`AppRoutes.groups` -> `AppRoutes.chats`)
- Delete: `lib/features/groups/groups_screen.dart`
- Delete: `test/features/groups/groups_screen_test.dart`
- Modify: `test/features/shell/app_shell_nav_test.dart` (drop the `/groups` case)
- Modify: `test/features/hub/hub_screen_test.dart` (drop any "Groups" tile assertion)

**Interfaces:**
- Consumes: `AppRoutes.chats`, `AppRoutes.conversationPath` (unchanged); group management still reached via `AppRoutes.groupInfo` from the conversation header, and group creation via `AppRoutes.createGroup` from the compose sheet.
- Produces: no route or nav entry to a standalone group list; group tiles live only in the unified Chats list. `/groups/:groupId/info` and `/groups/new` remain.

- [ ] **Step 1: Write the failing test (update the nav test to encode the new contract)**

In `test/features/shell/app_shell_nav_test.dart`, remove `AppRoutes.groups` from BOTH places:
- the route list inside `_app(...)`: delete the line `            AppRoutes.groups,` (currently line 62).
- the `cases` map: delete the line `    AppRoutes.groups: 'ops',` (currently line 107).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test test/features/shell/app_shell_nav_test.dart test/features/hub/hub_screen_test.dart`
Expected: FAIL to COMPILE or FAIL at runtime — `groups_screen.dart` is still imported by `app_router.dart` and `hub_screen.dart`/`chats_screen.dart` still reference the retired button/tile; `hub_screen_test.dart` still asserts the Groups tile. (This drives the removals below.)

- [ ] **Step 3: Write minimal implementation**

`lib/features/chats/chats_screen.dart` — delete the entire "Groups" `IconButton` from `_buildAppBar` actions (currently lines 86-92, the block with `key: const Key('chats-open-groups')`), leaving the Search and New-message actions.

`lib/features/shell/app_shell.dart` — in `_indexFor`, remove the groups branch from the Ops-highlight condition. Change:
```dart
        location.startsWith(AppRoutes.recordings) ||
        location.startsWith(AppRoutes.groups)) {
      return 3;
```
to:
```dart
        location.startsWith(AppRoutes.recordings)) {
      return 3;
```

`lib/features/hub/hub_screen.dart` — delete the "Groups" `_OpsTile` block (currently lines 95-101, `label: 'Groups'` ... `onTap: () => context.go(AppRoutes.groups),`).

`lib/core/modules/module_registry.dart` — delete the module entry whose `title: 'Groups'` / `route: AppRoutes.groups` (currently around lines 133-138). Remove the whole map/record entry so the module drawer no longer lists it.

`lib/core/router/app_router.dart` — remove `import '../../features/groups/groups_screen.dart';` (line 6) and delete the `GoRoute` for the bare list route (currently lines ~313-316, `path: AppRoutes.groups, builder: (...) => const GroupsScreen()`). Keep the `/groups/:groupId/info` and `/groups/new` routes and their imports. Leave the `AppRoutes.groups` constant defined (still used as the string prefix for the info/new routes and harmless if otherwise unreferenced).

`lib/features/groups/group_info_screen.dart:1018` — change `context.go(AppRoutes.groups)` to `context.go(AppRoutes.chats)` (after leaving a group, land on the unified list).

`lib/features/groups/create_group_screen.dart:456` — change `context.go(AppRoutes.groups)` to `context.go(AppRoutes.chats)` (after creating a group, land on the unified list).

Delete the retired files:
```bash
git rm lib/features/groups/groups_screen.dart test/features/groups/groups_screen_test.dart
```

`test/features/hub/hub_screen_test.dart` — remove any expectation that references `Groups` (search the file for `Groups`). If the file asserts a specific Ops-tile count, decrement that expected count by 1. If it only checks individual labels, delete the `Groups` label expectation.

- [ ] **Step 4: Run tests to verify they pass**

Run the touched suites plus a full-suite guard for no regressions:
```bash
cd ~/clawd/skcapstone-repos/skchat-app
flutter analyze
flutter test test/features/shell/app_shell_nav_test.dart \
  test/features/hub/hub_screen_test.dart \
  test/features/chats/
```
Expected: `flutter analyze` reports no errors (no dangling `GroupsScreen` reference), and all listed suites PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(chats): retire standalone Groups surface; groups live in the unified list"
```

---

## Task 7: Full-suite regression + docs

**Files:**
- Modify: `CHANGELOG.md`, `SECURITY.md` (per sk-standards doc SOP)

**Interfaces:** none (verification + docs).

- [ ] **Step 1: Run the full client suite**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && flutter test`
Expected: PASS, except the known pre-existing failures documented in the handoff (the 6 `test/features/spaces/space_share_sheet_test.dart` share_plus MissingPluginException cases). Confirm no NEW failures were introduced by comparing against a clean `git stash` baseline if any unexpected red appears.

- [ ] **Step 2: Run the full server suite**

Run: `cd ~ && ~/.skenv/bin/python -m pytest ~/clawd/skcapstone-repos/skchat/tests/ -q -m 'not integration'`
Expected: PASS, except the known pre-existing `test_message_log_shadow_write_when_flag_on` failure (message_log subsystem, documented in the handoff).

- [ ] **Step 3: Update docs**

Add a `CHANGELOG.md` entry under both repos:
- skchat-app: `feat(chats): unified conversation list — groups render inline with composite avatars and one aggregate trust badge; the standalone Groups surface is retired.`
- skchat: `feat(daemon_proxy): /conversations group threads now carry per-member participants with server-resolved soul_fingerprint.`

Add a `SECURITY.md` note (skchat-app): the aggregate group badge folds each member's `peerTrustTierProvider` tier over the SERVER-set `soul_fingerprint` (no client-side identity->fingerprint resolution), so the M1b unspoofability invariant holds unchanged; a keyless member contributes no key and cannot raise a group to verified.

- [ ] **Step 4: Verify docs render**

Run: `cd ~/clawd/skcapstone-repos/skchat-app && git diff --stat CHANGELOG.md SECURITY.md`
Expected: both files show additions.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md SECURITY.md
git commit -m "docs: unified conversation list (Phase 1) changelog + security note"
```

---

## Deferred to follow-on plans (approved enrichments, NOT this plan)

The spec folds several tap-economy enrichments across the phases. Each is an independent, stateful subsystem that deserves its own brainstorm + right-sizing (per superpowers:writing-plans Scope Check), so they are intentionally OUT of this plan and tracked as follow-ons under epic `4187787c`:

- **Pinned section + pin/mute/archive persistence** — a new persisted per-conversation flag store + a re-sort of `chatsProvider`. New provider, new Hive seam, optimistic writes.
- **Swipe actions on tiles** (mute/archive one way, pin/mark-read the other) — `Dismissible`/slidable wiring over the tile; depends on the pin/mute store above.
- **Long-press quick-action sheet** (Call, Mute, Pin, Verify, Mark read) — a bottom sheet + intent dispatch; one-tap-call entry point feeds Phase 2.
- **@mention badge on group tiles** — requires a server signal (does this group mention me since last read?) that does not exist yet; server + client work.
- **Unified search across DMs + groups + message contents** — needs server-side message full-text search; a separate subsystem and its own plan.

Recommendation: land Tasks 1-7 (the core unification, which closes the card's stated goal and the "start here" scope), review, then plan the enrichments as a second Phase-1b pass.

---

## Self-Review

**1. Spec coverage (Phase 1 section of the design doc):**
- "Add a `members` list to `Conversation`" -> Task 1. ✅
- "server assist: include per-member `soul_fingerprint`" -> Task 2. ✅
- "composite avatar for groups" -> Task 4 + wired in Task 5. ✅
- "one aggregate trust badge derived from members (red/amber/none rule)" -> Task 3 (fold) + Task 5 (render). ✅
- "Retire `GroupsScreen` from the shell/Ops; group tile routes into the existing `ConversationScreen`; management stays in `group_info`; compose opens New chat/New group" -> Task 6 (the New chat/New group compose sheet ALREADY exists in `chats_screen._showComposeMenu`, so no new work there). ✅
- "memoize composite avatar + aggregate tier; lazy ListView" -> composite avatar is a pure presentational widget, aggregate folds over the already-memoized `peerTrustTierProvider`; the list stays `ListView.builder`. No extra task needed. ✅
- Tap-economy enrichments + unified search -> explicitly deferred to follow-on plans with rationale. ✅ (scoped out, not dropped)
- Testing (widget tests for composite avatar / aggregate badge; server participant test; no regressions) -> Tasks 1-5 tests + Task 7 full-suite guard. ✅

**2. Placeholder scan:** No "TBD", no "add error handling", no "similar to Task N", every code step shows real code. The one search-and-adjust step (Task 6 Step 3, `hub_screen_test.dart`) gives an exact search term and a concrete rule (decrement the count or delete the label expectation), because that test file was not read verbatim into the plan.

**3. Type consistency:** `ConversationMember` fields (`identityUri`, `displayName`, `soulFingerprint`) are identical across Tasks 1, 4, 5. `foldGroupTier(Iterable<PeerTrustTier?>) -> PeerTrustTier?` is defined in Task 3 and consumed with that exact signature in Task 5. `GroupCompositeAvatar({required List<ConversationMember> members, required Color fallbackColor, double size})` is defined in Task 4 and constructed with those exact named args in Task 5. Server `group_to_conversation(group, *, online_uris=None, fingerprint_for=None)` is defined in Task 2 and called with `fingerprint_for=` in the same task's `_group_conversations`. `MemberRole.ADMIN` / `MemberRole.MEMBER` match the enum casing in `src/skchat/group.py`. ✅
