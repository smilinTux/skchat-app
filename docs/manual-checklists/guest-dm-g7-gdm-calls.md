# Manual web checklist: guest-dm G7 (gdm calls + file smoke)

Card G7 (guest-dm epic `8685ede6`). Mirrors the C5 guest-leg checklist (PR
[#50](https://github.com/smilinTux/skworld-app/pull/50), "Manual web checklist
(guest-leg, part 3)") for the promoted-group case: a `gdm` has several guests
in it, so the thing worth hand-verifying is that everyone (the operator AND
every guest) lands in the SAME LiveKit room, and that the operator's ring
banner never fabricates who is calling.

## Prereqs

- The web app running against a live daemon (same setup C5's checklist used).
- One operator session (logged in, sees the AppShell + Chats tab).
- A gdm room with **at least 2 guests** seated in it: either promote an
  existing 1:1 guest DM (G5 "Add another guest") or start a fresh "New guest
  group" and mint 2 per-person invite links.
- Two separate browser sessions (or two browsers/profiles) for the two guest
  invite links, so each guest gets its own WebCrypto keypair (returning-guest
  auto-join uses a cached key per browser).

## Checklist

- [ ] Web guest 1 opens their `/g/<token>` invite link, joins the gdm room
      (shows the group name + who-is-here strip, per G6).
- [ ] Web guest 2 opens their **own** `/g/<token>` invite link, joins the
      **same** gdm room. Guest 1 sees the join line on its next 3s poll.
- [ ] From inside the gdm room, web guest 1 taps the composer call button
      (tooltip "Start call") to start the group call.
- [ ] Operator sees the `GuestRingBanner` (the C5 banner, unchanged
      mechanism) on the Chats shell.
  - [ ] If the server named a caller (`ringers` non-empty): the banner reads
        `Incoming group call from <caller> in <room name>` - `<caller>` is
        alias-wins (operator's private alias) or `guest: <name>` styled
        untrusted (warning color + italic) when there is no alias. It is
        NEVER the room's own name standing in for a person.
  - [ ] If the server named nobody (older server, or no ringer resolved): the
        banner degrades to `Incoming group call in <room name>` - no
        fabricated "from" a person.
- [ ] Operator taps **Answer**. The banner clears immediately (dismissed) and
      the operator lands in the LiveKit call screen.
- [ ] Web guest 2 also joins the call (composer call button, or the
      in-progress-call affordance if the room shows one).
- [ ] **The 3-party check**: operator + guest 1 + guest 2 are all in the
      SAME derived room.
  - Fastest tell: the top bar of the call screen reads `3 participants`
    once all three are connected (`N participant(s)` label in
    `livekit_call_screen.dart`).
  - Confirm by identity too: each side's tile list should show the other
    two (guest tiles show their alias-wins/guest: title, per G6's roster
    rule; the operator's own tile is suffixed `(you)`).
- [ ] **What it looks like when it's wrong** (do not skip this if the count
      is off): the "Joining room…" splash under the spinner shows the room
      name each client connected to - if the operator's room name and either
      guest's room name differ, they derived DIFFERENT rooms and are NOT
      actually in a call together even though each side looks "connected."
      That is the bug to chase, not a UI glitch.
- [ ] File smoke: a guest attaches a file (composer "Attach file") -> the
      operator sees it in the thread and can download it (same S6/C5 file
      path, now exercised inside a promoted gdm).
- [ ] A revoked guest's call attempt does not ring the operator
      (server-enforced, same guarantee C5 verified for a 1:1).
- [ ] Guest UI never shows a ring banner anywhere in the guest room, for
      either guest, at any point in the above (there is no `GuestRingBanner`
      in the guest route's widget tree at all - see
      `test/features/calls/guest_ring_no_guest_ui_test.dart` for the
      structural pin; this step is the human confirmation that nothing
      slipped through visually).
