# skchat-app — Session Handoff (2026-06-15): duplicate-message fix

## TL;DR for next session
The desktop chat duped **your own message** (shows once olive/outbound, once green/inbound)
**and** duped **Lumina's reply**. Root cause found and fixed this session. Fix is committed +
pushed to `main` as **`47db93b`**. It compiles clean and the dedup unit tests pass, but it has
**NOT yet been verified in the running GUI**. Next session: build on .41, relaunch, visually
confirm single bubbles. If still duping, see "If it still dupes" below.

## Current git state
- Repo: `github.com/smilinTux/skchat-app` (origin, both boxes on `main`).
- `main` HEAD = **`47db93b`** (this session's fix). Pushed.
- Baseline tag before the fix: **`baseline-dup-64f58ab`** (= the still-buggy `64f58ab`).
- `.158` (this box, noroc2027) working tree: clean at 47db93b.
- `.41` (laptop): was clean at `64f58ab`; **needs `git pull`** to get 47db93b, then rebuild.

## What was actually wrong (the real root cause)
Commit `64f58ab` *claimed* it had reduced ingestion to a single path, and added a unit test
(`test/message_dedup_test.dart`) for `dedupForDisplay()` — which passed. **But the live app still
duped**, because the duplicate was created **upstream** of `dedupForDisplay`:

`lib/services/skcomms_sync.dart` → `_pollInbox()` was still calling `_dispatchIncoming()` for
**every** inbox message, marking each `isOutbound: false` and pushing it into
`conversationProvider`. So:
- the operator's own message got re-injected as a **green inbound** copy, and
- every agent reply got a **second** inbound copy.

The comment in the code said "_pollInbox is kept only for the call-request sentinel" but the code
did not actually enforce that. The dedup unit tests couldn't catch it because they only test the
pure display function, not the two-path ingestion.

## The fix (commit 47db93b, file `lib/services/skcomms_sync.dart`)
- `_pollInbox()` now `continue`s past any message whose content does **not** start with
  `__CALL_REQUEST__:`. Only call sentinels travel this path.
- `_dispatchIncoming()` trimmed to sentinel-only (routes to `_handleIncomingCallRequest`).
- Removed dead code: `_pollSkchatCli()`, `_dispatchCliMessage()`, `_cliPollTimer`,
  `_cliPollInterval`, and three now-unused imports.
- **Invariant going forward:** `ConversationNotifier._fetchFromDaemon` (in
  `lib/features/conversation/conversation_provider.dart`, polls `skchat history --json` both
  directions every 4 s) is the **single** chat-message ingestion path. The only other inserts are
  the optimistic outbound add in `conversation_screen.dart onSend`, which collapses with the
  history copy via `dedupForDisplay` (outbound wins).

## Verified this session
- `flutter analyze lib/services/skcomms_sync.dart` → **No issues found**.
- `flutter test test/message_dedup_test.dart` → **4/4 pass** (on .158).

## NOT yet verified — do this first next session
1. On **.41**: `cd ~/clawd/skcapstone-repos/skchat-app && git checkout -- . && git pull --ff-only`
   (the `checkout --` matters: a dirty tree silently blocked `git pull` all last session — the
   original meta-bug. Confirm pull lands `47db93b`).
2. Build: `export PATH=$HOME/flutter/bin:$PATH && flutter build linux --debug`
   (full GUI toolchain — clang/cmake/ninja/gtk — exists on .41, NOT on .158).
3. Relaunch the desktop app, send a test message to Lumina, and confirm:
   - your message appears **once**, on the right (olive/outbound) — no green copy;
   - Lumina's reply appears **once**, on the left (green/inbound) — not doubled.
4. Optional belt-and-suspenders: clear `messages_*.hive` only (NOT `conversations.hive`, or the
   chat list goes empty) before relaunch.

## If it still dupes after this fix
The remaining suspects (in order):
- **Content mismatch** between the optimistic copy and the `skchat history` copy (e.g. trailing
  whitespace, a prefix, or reformatting) so `dedupForDisplay`'s content-equality misses. Check by
  logging both copies' exact `content`.
- **`addMessage` 10-s dedup window** in `conversation_provider.dart`: if the two copies of an agent
  reply arrive >10 s apart, the near-dup guard won't fire. Consider widening or keying on a stable id.
- A real **second reply from the bridge** (server-side): check the store with
  `skchat history lumina --json` on the box running the daemon — if the store itself has two
  replies, the dup is in `scripts/lumina-bridge.py`, not the app.
- Add a real **regression test**: a `ProviderContainer` test that overrides `skcommsClientProvider`
  with a fake `SKCommsClient` returning one normal (non-sentinel) `InboxMessage` and asserts
  `conversationProvider(peer)` stays empty. (Needs also overriding `messageRepositoryProvider` to a
  Hive-free fake.) This is the test that would have caught 64f58ab's gap.

## Environment notes (important)
- **ssh alias is `laptop`** (or `cbrd21-laptop`), **not `.41`** — `ssh .41` fails to resolve.
- **Flutter installed on .158 this session**: `~/flutter` (3.44.2 stable, Dart 3.12.2).
  `export PATH=$HOME/flutter/bin:$PATH`. Good for `flutter analyze` / `flutter test` (headless).
- **.158 disk is at 99% (~5G free)** — CAUTION. Do NOT run a full `flutter build linux` on .158
  (needs apt-installed clang/cmake/ninja/gtk which are missing, and would risk filling the disk
  that also hosts Postgres `skmem-pg`). Do GUI builds on **.41**. If you need to free space on
  .158, the flutter clone (`~/flutter`) and `~/.pub-cache` are removable.
- GUI-over-SSH launch recipe (from .41, last session): source a full session env
  (`DISPLAY/XAUTHORITY/DBUS_SESSION_BUS_ADDRESS/XDG_RUNTIME_DIR`) + `setsid`, screenshot with
  `import -window <wid>`. Launching without that env renders a black window (no GL surface).

## Security TODOs (carried over — still pending Chef)
- Rotate the 1-year `sk-ant-oat01-…` Claude OAuth token (in `.41:~/.claude/.credentials.json`).
- Rotate `NVIDIA_API_KEY=nvapi-…` (in .158 skchat-lumina-call systemd unit).
- Rotate the admin GitHub PAT (`ghp_…`, full admin scope) that was copied to .41.
- Using Claude subscription OAuth via skgateway is against Anthropic ToS (account risk) — qwen is
  the safe default backend; claude-opus is Chef's explicit sovereign call.

## Related working pieces (already done earlier, for context)
- SKGateway on .41 (`:18780`): `local` qwen3.6-27b @ 192.168.0.100:8082, `anthropic` claude-opus
  via OAuth (refresh + cooldown). In-app model picker (`ModelPickerButton`) for AI agents.
- Bridge (`scripts/lumina-bridge.py`): SKGateway reply w/ selected model → qwen fallback →
  "⚠️ No models available through SKGateway" notice (never passthrough-echo).
- daemon `GET/POST /api/v1/agent/model`; `skchat history --json`; notifications off
  (`SK_DESKTOP_NOTIFY=0`); timestamps `.toLocal()`; auto-scroll-to-bottom; mark-all-read.
