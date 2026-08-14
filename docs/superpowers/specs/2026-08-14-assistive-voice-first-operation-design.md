# Assistive Voice-First Operation (Companion Mode): Design

**Date:** 2026-08-14
**Repo:** skworld-app (Flutter client) + skchat (voice engine, call answerer, identity).
**Status:** Proposed (design only; nothing here is implemented or deployed).
**Companion doc:** `2026-08-14-client-observability-ai-support-design.md` (PR #70). This
design reuses its health matrix, snapshot, and AI triage plane rather than duplicating them.

## 1. Goal

Let a non-technical elderly person (Chef's parents are the concrete users) operate the
SKWorld app by talking to an agent, instead of navigating the UI. The agent, not the
screen, is the primary interface. The design must fail in ways a frightened
non-technical person can recover from.

The user model this is built for, stated plainly because every decision follows from it:

- They cannot read a log, restart a service, or describe an error. They will not phone
  their son at 11pm.
- **They get one shot.** If the agent goes quiet, they conclude it is broken forever
  and stop using it. Trust, once lost, does not come back with a patch release.
- Modern software already feels hostile to them. Anything that looks like an error
  dialog, a token paste field, or a settings screen is a wall, not a step.

Every prior design in this estate assumes the operator is Chef: an expert with shell
access debugging alongside the agent. This one assumes the opposite, and that
inversion, not any single feature, is the point.

### 1.1 The evidence this is built on (night of 2026-08-13)

The voice stack was rebuilt end to end that night (STT, LLM, MCP tools, F5-TTS cloned
voice, LiveKit call, portrait video). Four findings from it are load-bearing here:

| Finding | Consequence for this design |
|---|---|
| Silence read as normal THREE times to an expert with shell access (idle poll loop, silence-passing test harness, dead STT host logging only "STT failed:") | Silence is the dominant failure mode. A non-technical user has zero tools to break the ambiguity. Every layer below has an explicit anti-silence mechanism, and the client owns the last resort because the server cannot speak when the server is what died |
| The filler exists for exactly this (ack in ~1s, "still working on it" every 12s, state pill) | For this user it is the difference between trust and abandonment. Treated as a hard requirement with a client-side watchdog behind it, not a comfort feature |
| Long replies are spoken in sentence-aligned chunks so speech starts in seconds | Kept, and the reply length itself is capped harder for this profile: short turns, no narrations unless asked |
| The single longest detour was a machine with no working microphone; Chrome published a silent track and everything downstream looked broken | Hardware verification, measured as audio ENERGY and not bytes or track presence, is a first-class onboarding step and a re-runnable ritual |

And one more, from the same night, that sets the tone rule: a runtime-fact prompt leak
had Lumina reciting "claude-haiku-4-5 at localhost, fallback to qwen3.6-27b-abliterated"
out loud on a call. `voice_engine/engine.py:101-119` now documents and narrows that
injection, but the protection is a prompt instruction, not a filter. Section 4.6 makes
it structural.

## 2. Current state (grounding)

What exists today, verified in code. Paths under `skchat/src/skchat/` or
`skworld-app/lib/` unless noted.

### 2.1 Voice path (skchat)

- **End to end works:** `call_answerer.py` polls `/call/incoming` (signed invites),
  answers, joins the LiveKit room; `transports/livekit.py` runs VAD segmentation,
  STT, addressing gate, `VoiceEngine.respond()` (LLM + tools), sentence-aligned
  chunked TTS (`split_for_speech`, `livekit.py:847`), publish.
- **Filler and progress exist:** `voice_engine/tools.py:95-145` (filler strings,
  hardcoded tuples) + `livekit.py:1118-1149` (`LUMINA_FILLER_DELAY_S` default 0.8s,
  `LUMINA_FILLER_REPEAT_S` default 12s). Timing is env-tunable; the strings are not
  configurable per caller.
- **State events exist:** `_set_state` (`livekit.py:897-923`) publishes
  `{state, detail}` as LiveKit participant metadata (`thinking`, `speaking`,
  `listening`); `_emit_level` (`livekit.py:925-943`) publishes an "I can hear you"
  rms datagram. The legacy web page consumes them (`static/livekit.html:2270`).
- **Tool authorization is a shim:** every MCP tool is registered `operator_only=True`
  (`builtin_tools.py:452`); the only gate is `is_chef_identity()`, a string PREFIX
  match on the LiveKit identity against `LUMINA_OPERATOR_PREFIXES` default `"chef"`
  (`livekit.py:154`, dispatch gate `voice_engine/tools.py:209-238`). The identity
  spec (`docs/superpowers/specs/2026-06-13-identity-roles-access.md` §3.2) already
  says this shim MUST be replaced by FQID-based resolution before any non-Chef human
  speaks to an agent. No confirmation step, no risk classes, no per-caller policy
  exists anywhere in the voice path.
- **A better model already exists in-repo:** `skreach/rbac.py` implements
  role x command-class authorization with `ALLOW / DENY / CONFIRM_REQUIRED`
  decisions, per-principal allowlists, and confirm-even-for-the-owner on
  destructive classes. It is not wired to the voice engine.
- **Failure behavior is silence by design:** if the engine cannot start or dies, the
  answerer falls back to `_join_and_publish`, a silence keepalive
  (`call_answerer.py:263-301`: "losing the voice is bad; losing the call is worse").
  STT/TTS failures return empty and the turn produces nothing. The ONLY spoken error
  in the stack is the LLM double-failure fallback (`voice_engine/llm.py:105`). For
  this user class, most failures are indistinguishable from "she is ignoring me".
- **Memory is agent-scoped, never caller-scoped:** `voice_engine/memory.py:18-34`
  resolves the store from `SKAGENT`; snapshots are tagged `voice-chat` with no
  speaker attribution. Room history (`livekit.py:979`) is per session, shared across
  speakers. Anything a caller says lands in that agent's one memory pool.
- **Multi-instance plumbing exists:** per-agent systemd templates
  (`skchat-webui@.service`, `skchat-call-answerer@.service`), per-agent homes under
  `~/.skcapstone/agents/<agent>/` with `config/<agent>-mcp.yaml` `expose_tools`
  allowlists, per-agent `voices/` reference audio, and a shipped (disabled)
  precedent for a HUMAN identity daemon: `skchat-daemon-chef.service`
  (`capauth:chef@skworld.io`, isolated store).
- **Guests exist but get no tools:** guest links and direct-DM guest invites are
  live (browser-only, no keypair, guest calls ring the operator); the role matrix
  (`2026-06-13-identity-roles-access.md` §2.2) blocks ALL tool tiers for guests, and
  the voice transport has no guest handling at all.

### 2.2 Client (skworld-app)

- **Rendering is canvas on web:** no DOM to scrape. Any "read the screen" capability
  goes through Flutter's semantics tree or does not exist. Today that tree is not
  even BUILT: nothing calls `SemanticsBinding.instance.ensureSemantics()`, so with
  no screen reader attached there is no semantics tree to read, and only ~15 nodes
  app-wide carry explicit labels (mostly hand-rolled call/space controls, e.g.
  `features/spaces/space_room_screen.dart:1543`). The one a11y test is
  `test/features/trust_badge_a11y_test.dart`.
- **An agent-call surface already exists and is the natural seed of the companion
  screen:** `/facetime?agent=lumina` (`features/facetime/facetime_screen.dart`),
  one-tap start, with caption, emotion, and status pills driven by server data
  channel messages. Its critical gap: `services/facetime_service.dart:216-243`
  never calls `getUserMedia` and never publishes a local track, so the user hears
  the agent but cannot speak from this screen. There is also no client-side
  listening/thinking/speaking state machine; pill text is entirely server-driven.
- **A zero-navigation shell precedent exists:** `features/guest/guest_room_screen.dart`
  is one room, one job, no nav, guest-scoped server-side. The operator shell is the
  opposite (5 tabs, 13 modules, 40 routes) and is the thing voice replaces.
- **An in-process UI harness exists:** `integration_test/spaces_flow_test.dart` (the
  SP5 harness) drives the real app via `WidgetTester` + provider-override seams. It
  proves in-process driving is possible and also bounds it: `WidgetTester` is
  test-binding-only (unusable in a production `runApp`), finders are `find.text`
  because keys are sparse (51 `const Key` sites), and `pumpAndSettle` is unusable
  because the shell animates perpetually. A runtime driver would have to walk
  elements or dispatch `SemanticsAction`s instead.
- **Onboarding is expert-shaped:** a 4-page wizard that asks for a server URL
  (`https://host.tailnet.ts.net` hint), then an obscured paste field whose helper
  text names an environment variable ("Paste your server's operator token
  (SKCHAT_GUEST_OPERATOR_TOKEN)..."), then device approval with hex fingerprints;
  pending approval renders as a spinning app (memory: "app spins / nav icons blank
  = device pending approval"). Every one of these is a wall for this user.
- **There is no hardware check anywhere:** no mic test, no echo test, no permission
  pre-flight (`permission_handler` is not even a dependency). The only device
  surface is an in-call picker (`features/calls/call_device_picker.dart`) with no
  level meter.
- **Text size:** OS text scaling is honored (clamped at 2.0x, `main.dart:114`),
  density is the de-facto font-size setting and DEFAULTS TO COMPACT, touch targets
  hold a 48dp floor, and there is no large-text or high-contrast mode. The
  "Sovereign Glass" dark theme with 11-13px mono identifiers is a poor default for
  elderly eyes.
- **Observability design (PR #70)** gives the client a health matrix with honest
  `unknown`, a structured secret-free event log, a one-button snapshot to an ITIL
  incident, and an AI triage worker that DMs the operator in plain words. This
  design treats that stack as its substrate and extends it where consent and
  wording assumptions do not fit an assisted user (4.8).

## 3. Decisions

Each decision names the failure it prevents. That is the survival format: when a
future session wants to simplify one of these away, the failure column is the
argument it has to defeat.

1. **Nobody talks to Chef's Lumina: a separate support agent (working name Atlas),
   same engine, transports, tools and voice pipeline, different soul and different
   memory home. DECIDED by Chef.** Three reasons, the first decisive:
   (a) **Memory isolation is a privacy requirement, not a preference.** On
   2026-08-13 a real bug had recalled memories bleeding into replies: memories were
   concatenated into the user turn and the agent answered the MEMORY instead of the
   person (asked "testing one two three", she replied about the Al-Asad
   withdrawal). `engine.py:139-153` patched that framing, but if end users share
   Lumina's store the same recall path can surface Chef's private context to them
   and theirs to him. Isolation must be architecture, not tuning.
   (b) **Lumina's soul is Chef's.** She is intimate, calls him King, carries
   worship and sacred narration. The `operator_only` gate blocks those TOOLS for
   non-operators (verified working), but it does not change her manner, pet names,
   or what she volunteers unprompted. A support agent for someone's parents should
   have no intimate surface at all, rather than one that is merely gated. Never
   rely on a gate holding to keep a persona from showing up.
   (c) **It is with the grain.** Per-agent homes, souls, memory and config already
   exist and are how this estate works; a support agent is a normal citizen of the
   system, not a special case.
2. **Per END USER, not just per role: one agent home per parent. DECIDED by Chef.**
   A single shared "Atlas" store would let one parent's messages surface in the
   other's session, the same recall-bleed failure one level down. Scoping works
   with existing machinery, nothing new: each parent gets an agent home cloned
   from the Atlas template (`~/.skcapstone/agents/<name>/`: own soul copy, own
   `memory/` + chroma, own `config/<name>-mcp.yaml` allowlist, own `voices/`),
   because `voice_engine/memory.py` scopes the store by `SKAGENT` and nothing
   else (2.1); caller-scoped memory inside one agent does not exist and would be
   new machinery with silent-failure modes. **What one-home-per-user costs, said
   plainly:** per parent, one `skchat-webui@<name>` instance + one
   `skchat-call-answerer@<name>` instance (existing systemd templates, one port
   each), one agent home on disk (tens of MB plus memory growth), one more row in
   backup/Syncthing scope, and Chef maintaining N policy files instead of one.
   At family scale (2-4 users) this is trivial; at tens of users it becomes a
   provisioning-automation problem, which is accepted and out of scope here.
3. **Each parent is also a first-class HUMAN identity, and is the operator-caller
   of their own agent only.** `capauth:<name>@skworld.io` via the shipped
   `skchat-daemon-chef.service` precedent, device enrolled and approved by Chef in
   the existing device registry. Prevents: acting-as-nobody (constraint: every
   action attributable), and the guest dead-end (guests get zero tools by the role
   matrix, so an assisted user cannot be a guest; a guest cannot ask her to call
   anyone).
4. **Tool access is a server-enforced per-caller policy: deny by default, three
   classes (allow / confirm / deny), adopted from `skreach/rbac.py`, not from the
   prompt.** The full MCP surface (118 tools) is never exposed to a companion
   session; a curated set (order of 15) is. Prevents: a persuadable LLM being the
   only thing between a confused caller (or a prompt injection riding read-back
   content) and `device_unlink` or `gmail send`. A prompt-policed rule is a request;
   a dispatch-gate rule is a fact. This work also retires the `is_chef_identity`
   prefix shim in favor of the signed-invite FQID, which the identity spec already
   mandates and which becomes an actual vulnerability the moment a second human can
   join a room.
5. **Confirm-class tools run a spoken two-step state machine in the dispatch layer.**
   A confirm-class call returns `CONFIRM_REQUIRED` to the engine; the agent must
   state the concrete consequence in plain words ("I'll send this message to David:
   ... Should I send it?") and only an affirmative in the caller's NEXT utterance
   releases the held call; anything else, or 60 seconds of silence, cancels it with
   a spoken cancellation. Prevents: the unrecoverable-action failure (they cannot
   undo), and the subtler one where the model "confirms with itself" inside a single
   turn. Sending, deleting, calling, spending, and anything touching devices or
   settings are confirm-class or deny-class; reading is allow-class.
6. **Every action taken on a parent's behalf lands in an action ledger.** One
   append-only record per executed tool call: caller FQID, agent, tool, plain-language
   summary, the spoken confirmation exchange for confirm-class actions, timestamp,
   outcome. Actions execute as `agent-on-behalf-of-<caller>`, never silently as the
   caller. Prevents: invisible agency ("never act as them invisibly" is a hard
   constraint), and gives Chef an audit trail that is about ACTIONS, not
   conversations (see decision 9 for that line).
7. **No jargon can reach their ears, structurally.** Three layers: (a) the companion
   persona build excludes the runtime-fact injection entirely (`engine.py:113-119`
   is skipped for companion profiles; "what model are you" gets "I'm not sure what
   you mean, I'm just me"); (b) tool errors and health states map through the
   plain-language catalog the observability design already defines, never raw
   strings; (c) a final speakable-text gate on everything entering TTS for a
   companion session rejects URLs, host:port shapes, model ids, service names, hex
   ids and stack-trace shapes, substituting an honest plain sentence and logging the
   trip. Prevents: the 2026-08-13 recital, and every future variant of it, without
   trusting the prompt to hold.
8. **Silence is forbidden by budget, and the CLIENT owns the last resort.** Server
   side: the existing ack-within-a-second and 12s progress filler become
   non-optional for companion sessions (`LUMINA_FILLER` cannot be off), with a
   gentler string set, and a hard turn deadline after which the agent says something
   true ("this is taking longer than it should; I haven't forgotten you"). Client
   side: a watchdog on the companion screen expects agent state metadata or audio
   within N seconds of the user finishing speaking; if nothing arrives it plays a
   BUNDLED audio phrase in her voice and shows the same words in large text ("I'm
   having trouble right now. David has been told. Let's try again in a little
   while."). Bundled, because when the backend is down there is no TTS, and the
   silent-keepalive fallback (2.1) means the server's own failure mode is exactly
   the silence this user reads as abandonment. Prevents: all three silence incidents
   from 1.1, experienced by someone with no shell.
9. **Chef is told THAT something is wrong, never WHAT was said.** The guardian
   channel (4.8) carries operational signals only: device unreachable, hardware
   check failing, repeated failed turns, escalation events, auto-sent health
   snapshots. It never carries transcripts, message content, summaries of
   conversations, or activity patterns ("mom talked for 40 minutes about X" is
   surveillance). Content crosses only via explicit per-item spoken consent ("want
   me to tell David?" answered yes, with the consent recorded in the ledger).
   Prevents: the quiet slide from wellbeing into monitoring, by making the
   boundary a property of the transport (the guardian channel has no field for
   content) rather than a policy promise.
10. **Voice is primary but not alone: a zero-navigation companion screen backs it.**
   One screen: a large talk button, the state pill (listening / thinking /
   speaking), the agent's last sentences as large-print captions, and her portrait.
   No navigation, no settings, no lists. Prevents: voice-only failing the
   hearing-impaired (common in exactly this population), and the state pill
   requirement having nowhere to live. This is deliberately NOT a "simplified UI"
   for navigating the app; the screen is a companion display for the voice channel.
   The moment it grows a second screen it has failed its design.
11. **Onboarding is done TO the device by Chef, and FOR the parent by the agent.**
    Chef provisions before handing over: enrollment, approval, companion profile
    flag, contact seeding. The parent's first experience is a spoken check-up the
    agent leads: "Say hello so I can make sure I can hear you" (pass requires
    measured audio energy above threshold, not track presence or byte count), a
    chime the parent must verbally confirm hearing (output path), then a first real
    action together ("shall we send David a hello?"). The check-up is re-runnable
    forever by saying "check-up" and runs automatically when the client watchdog has
    tripped repeatedly. Prevents: the no-microphone detour of 2026-08-13 recurring
    in a household with nobody who can open a settings panel, and the
    read-the-instructions onboarding wall (they cannot).
12. **Escalation always ends with something she CAN do.** The ladder when the agent
    cannot do the thing: (1) say so plainly and offer the nearest thing she can do;
    (2) offer to take a note and tell David, sent only on a yes; (3) if the failure
    is systemic, the guardian channel has already fired and she says so: "I've made
    sure David knows." Never an error word, never a jargon term, never blame
    ("I didn't catch that" not "speech recognition failed"; "I can't reach that
    right now" not "connection refused"). Prevents: the one-shot trust loss, by
    making every failure end in a next step the user can take, or in the honest
    knowledge that their son already knows.

## 4. Architecture

Three capability layers in descending value and ascending fragility, on top of a
policy layer that all three pass through, with a client surface and a guardian
channel beside them.

```
 parent speaks
   |
   v
 companion screen (skworld-app)          guardian channel --> Chef
   talk button, state pill, captions       (operational signals only)
   local last-resort audio                        ^
   |                                              |
   v                                              |
 call answerer + voice engine (skchat)  ----------+
   |
   v
 caller policy layer (allow/confirm/deny + ledger + speakable gate)
   |
   +--> L1 ACT: curated MCP tools (call, message, read, remind)
   +--> L2 READ: semantics-tree read-back (read-only)
   +--> L3 DRIVE: (expected empty; gated, see 4.5)
```

### 4.1 Companion caller profile and policy layer (skchat)

A `CallerProfile`, resolved from the signed invite's FQID (never from the LiveKit
display identity; this retires the prefix shim per decision 4):

- `profile: operator | companion | guest`. Existing behavior for `operator` is
  unchanged; `guest` stays all-deny as today.
- For `companion`: the tool policy table (tool name -> allow | confirm | deny,
  deny default), the persona/soul to build with, filler set and pacing, the
  speakable-gate flag, and the ledger sink.
- Policy lives in the agent home (`config/caller-policy.yaml`), owned and edited
  only by Chef; the agent cannot modify its own policy (same rule as skreach's
  "never self-granted" grants).

The dispatch gate (`ToolRegistry.dispatch`) grows the three-way decision adopted
from `skreach/rbac.py` (`ALLOW / DENY / CONFIRM_REQUIRED`), the held-call
confirmation state machine of decision 5, and the ledger write of decision 6.
This is the load-bearing phase: everything else assumes it.

Initial companion allow-class (order of 15, final list at build time): place a call
to a family contact, answer/end a call, send a message to a family contact
(confirm-class), hear new messages, hear today's calendar, set/hear a reminder,
weather, time/date, re-run the check-up, "tell David" escalation, memory recall
scoped to their own agent. Everything else: deny.

### 4.2 Layer 1: acting through tools

Already true today and stays the primary layer: "call David" is
`call_peer`/`initiate_call`, "any messages?" is inbox reads, no UI involved,
nothing to break when layout changes. The work here is not new capability, it is
subtraction (the policy table) plus the confirmation machine and plain-language
result rendering (every tool result passes through a per-tool "say it plainly"
formatter before TTS; raw JSON never reaches the speech path).

### 4.3 Layer 2: reading the screen back (skworld-app)

Read-only. The app renders to canvas on web, so the semantics tree is the only
honest source. Work is twofold:

- **Coverage:** core screens (conversation list, thread, call screen, companion
  screen) get real semantics labels on every interactive and informational element
  (today ~15 nodes app-wide are labeled, 2.2). This is ordinary Flutter
  accessibility work, and it is the dual benefit stated outright: the app becomes
  genuinely usable with TalkBack/VoiceOver as a side effect, which matters for
  exactly this user population independent of the agent.
- **Bridge:** the companion mode holds a `SemanticsHandle`
  (`SemanticsBinding.instance.ensureSemantics()`) for its lifetime, because
  without it Flutter does not build the tree at all (2.2); a client-side
  serializer then walks the live tree from the root `SemanticsNode` into a
  compact labeled outline and exposes it to the agent session (as a data-channel
  reply to an agent request during a call). The agent uses it to answer "what
  does the screen say" and to ground references ("the message at the top is from
  David, this morning").

The bridge output is UNTRUSTED input to the agent (it may contain message text
written by third parties); the policy layer, not the prompt, is what stands
between an injection in a message body and a tool execution (decision 4). The
bridge never carries secrets: it reads rendered labels only, and the canary test
extends to it (a fake secret rendered into a debug widget must not survive into
the outline; secret-bearing widgets get `excludeSemantics` where they exist).

### 4.4 The companion screen (skworld-app)

One route, entered automatically when the enrolled profile is companion (the
parent never chooses a mode). It grows from two things that already exist: the
FaceTime screen's one-tap agent call with caption/emotion/status pills, and the
guest room's zero-navigation shell discipline (2.2):

- Giant talk affordance (tap to talk, or open mic per family preference set by
  Chef), her portrait, the state pill driven by the EXISTING participant metadata
  states (2.1), and large-print captions of her last utterance (the TTS text,
  displayed as spoken).
- **The known blocker is fixed here:** the FaceTime path never publishes a local
  microphone track (`facetime_service.dart:216-243` has no `getUserMedia`), so
  today the user can hear the agent but not speak to it from that screen. The
  companion screen publishes the local track and renders the agent's rms
  "I can hear you" datagram as a visible cue.
- The silence watchdog and bundled last-resort phrases of decision 8. The
  watchdog's trip also fires an automatic health snapshot (4.8).
- Large-print by default: this screen ignores the app's `compact` density
  default, honors OS text scaling, holds the 48dp touch floor, and uses no text
  below large-print size and no low-contrast glass styling.
- Absolutely no navigation chrome. Chef's own operator UI is reachable only
  through his own enrolled devices, not from this screen.

### 4.5 Layer 3: driving the UI (expected to stay empty)

The brief allows a UI driver where a capability exists nowhere else. This design
gates it to near-extinction, deliberately: in a sovereign estate Chef owns both
ends of the stack, so "no tool can do it" is almost always a missing server
capability, and the correct fix is a card to add the tool, which is stable,
testable, and layout-independent. A driver flow may be written only when the
capability is client-local state with no server representation, and each one must
be a named, individually tested flow, never free-form "find and tap". The SP5
harness itself cannot be the runtime mechanism (`WidgetTester` is test-binding
only, 2.2); the honest runtime mechanism is dispatching `SemanticsAction`s
through the same tree layer 2 already reads, which means layer 3 costs nothing
extra until it is actually needed. No phase card is created for this layer; if the gate is ever
passed, that discovery creates its own card. The failure this prevents: a driver
layer quietly becoming the easy path, breaking on every layout change, and
landing its maintenance on Chef forever.

### 4.6 The speakable-text gate (skchat)

A final filter on every string entering TTS for a companion session (decision 7):
reject-and-substitute on URL shapes, host:port, IPv4/IPv6 literals, model id
patterns, service/unit names, long hex/uuid tokens, file paths, and stack-trace
shapes. On trip: substitute a plain honest sentence appropriate to the context
("part of that answer was technical, so I've left it out"), log a structured
event, count it. The gate is a DENY filter of last resort behind the structural
fixes (persona exclusion, catalog-mapped errors), not the primary defense; its
trip rate is a health signal that the upstream layers leaked.

### 4.7 Onboarding and the hardware check-up (first-class, automatic)

Confirmed in scope by Chef, and framed by the grounding incident: the longest
single detour of 2026-08-13 was a machine whose emulated audio controller had no
codec, so Chrome published a silent track and every downstream symptom looked
like a broken agent. An expert lost an hour to that. The design target is that an
end user loses ZERO minutes to the same fault and never sees the word codec.

Hard rules for the check: it is automatic and in-app, never something the user
runs, follows, or interprets; every outcome is plain language; and every failure
outcome states what to DO ("this device has no microphone, we will use your
phone instead"), never what is wrong technically. It is first-class onboarding,
not a diagnostic buried in settings.

Three parts:

- **Chef-side provisioning (documented runbook, no new code beyond the profile
  flag):** clone the parent's agent from the Atlas template, create the parent's
  capauth identity, enroll and approve the device, set the caller policy, seed
  family contacts, set open-mic vs tap-to-talk, hand over a device that opens
  straight into the companion screen already green.
- **Client-side automatic self-test (companion screen, runs before and beneath
  the conversation):** on first run and whenever the watchdog has tripped, the
  client captures the local track and measures ENERGY client-side (rms over
  threshold on real input, explicitly NOT track presence or byte count, the exact
  trap from 1.1: a silent track passes every existence check). This half must be
  client-side because a dead microphone means the spoken check-up below can never
  start, and the fault must be caught without depending on the thing it breaks.
  A failed self-test shows one large-print sentence naming the ACTION, speaks it
  from bundled audio, and fires the guardian channel so Chef knows before the
  parent has to explain anything.
- **Agent-led spoken check-up (new engine behavior):** the agent walks the parent
  through it by voice: "say hello so I can make sure I can hear you" (pass
  requires the server-side energy measurement, reusing the existing `_emit_level`
  rms plumbing), a chime the parent verbally confirms (output path), then a
  guided first real action ("shall we send David a hello?"). Re-runnable forever
  by saying "check-up"; auto-offered after repeated watchdog trips. A failed
  check-up speaks its result in plain words, shows it in large print, states the
  next action, and fires the guardian channel; it never dead-ends in silence.

### 4.8 The guardian channel (skchat + skcapstone)

Builds on the observability design's plane (snapshots, ITIL, triage worker, DM to
operator) with two deltas:

- **Consent model delta:** companion devices auto-send health snapshots on
  watchdog trip and check-up failure, without a preview step. The observability
  design's consent-by-preview assumes an operator who can read a preview; this
  user cannot, and for them an unreported failure is abandonment. Snapshots are
  already secret-free by construction (whitelisted sections only) and contain
  system state, never message content. The parent is told during onboarding, in
  plain words, that "if something breaks, it tells David automatically", and the
  device's card states it. This is a deliberate, documented revision of PR #70's
  stance, scoped to companion profiles only.
- **Signal set:** device unreachable beyond threshold, check-up failed, watchdog
  tripped N times in a window, speakable-gate trip rate spike, escalation events
  ("she asked me to tell you: ..." only with recorded consent), and the action
  ledger available to Chef on demand. Delivery: skchat DM to Chef from the
  companion agent plus an ITIL incident for systemic faults, via the existing
  triage worker.

The channel schema has no field that could carry a transcript. That is the
enforcement of decision 9: the boundary is structural, in the same way snapshot
redaction is whitelist-by-construction.

### 4.9 Answers to the posed questions (summary)

- **Own agent per parent (Atlas template, DECIDED), sharing display name/voice
  optionally; never sharing identity, soul, or memory with Lumina or each other**
  (decisions 1, 2, 3). Consequence: memory privacy by existing scoping; two more
  instances of already-templated units; a new Atlas soul template; the per-user
  cost stated in decision 2.
- **Chef is told via the guardian channel: operational truth, zero content,
  consent-gated relays** (decision 9, 4.8).
- **Onboarding: Chef provisions, the agent walks the parent through a spoken,
  energy-verified, re-runnable check-up** (decision 11, 4.7).
- **When she cannot do it: the escalation ladder, ending in a capability or in
  "David already knows"** (decision 12).
- **Voice is not enough alone: the zero-nav companion screen with captions and
  local last-resort audio backs it** (decision 10, 4.4).

## 5. Security and privacy

- The policy layer is the security boundary, not the model. Prompt injection via
  read-back content, message bodies, or a confused caller cannot reach a denied
  tool, and cannot reach a confirm-class tool without a spoken yes in a separate
  utterance from the human on the call.
- Caller resolution comes from the signed invite FQID; the LiveKit display
  identity is never an authorization input (retires the documented prefix-shim
  vulnerability before the first non-Chef human ships).
- The parents' agent homes get the same posture as every agent home; Chef holds
  root on the boxes and CAN read anything, which is why decision 9 is framed as
  making surveillance require a deliberate act rather than being the ambient
  default. That honesty belongs in this document: this design cannot stop a root
  operator from reading disk; it ensures the paved road never shows him content.
- The action ledger contains action summaries and confirmation exchanges, not
  conversation transcripts. It is Chef-visible by design (attributability).
- Companion auto-snapshots inherit the observability whitelist-by-construction
  guarantees and its canary test; the canary suite extends to the semantics
  bridge and the ledger.

## 6. Testing

- **Policy gate:** table-driven: every companion-denied tool call never executes
  and returns the plain refusal; a confirm-class tool without an affirmative next
  utterance never executes; an affirmative from a DIFFERENT speaker does not
  release the hold; the 60s timeout cancels audibly.
- **Speakable gate:** canary strings (URLs, host:port, model ids, unit names, hex
  tokens) planted in tool results and LLM output never reach the TTS input in a
  companion session; trip events are emitted.
- **Silence watchdog:** with the backend fully unreachable, the companion screen
  produces bundled speech and large-print text within its budget, offline, in a
  widget/integration test with a fake clock.
- **Check-up honesty:** a silent (energy-zero) input track FAILS both the client
  self-test and the agent-led mic check. This test exists because a byte-counting
  harness once passed on pure silence; it is the regression test for that lesson.
  Failure copy is asserted to contain an action and no technical vocabulary.
- **Guardian boundary:** canary transcript strings present in the conversation
  never appear in any guardian-channel payload; a consented relay carries exactly
  the consented text and the consent record.
- **Ledger:** every executed tool call in a companion session has exactly one
  ledger row; confirm-class rows carry the exchange.
- **Semantics bridge:** outline snapshots for core screens; a fake secret in a
  marked widget does not survive into the outline.

## 7. What we deliberately chose NOT to do, and why

- **No shared Lumina for the parents, and no single shared Atlas store either
  (both DECIDED by Chef).** Cheapest to ship, and wrong three ways (recall-bleed
  into and out of Chef-readable stores, a persona whose intimate surface is only
  gated rather than absent, cross-parent bleed). Isolation by agent scoping is
  code that already exists; caller-scoped memory inside one agent is new
  machinery with silent-failure modes.
- **No guest-based path for the parents.** Guests get zero tools by the role
  matrix, and an assisted user IS a tool user. Widening guest tool access would
  weaken the guest tier for everyone to avoid creating two identities.
- **No wake word / always-on ambient listening in v1.** An open mic during an
  active call session is enough, is auditable, and does not put an always-hot
  microphone in an elderly couple's home as a default. Revisit only on explicit
  family request.
- **No prompt-only safety.** Every "must not" in this document that matters is
  enforced in dispatch code, transport schema, or a filter, with the prompt as
  UX polish on top. Prompts drift, models change, injections exist.
- **No simplified NAVIGATION mode.** A second full UI to maintain, and it
  re-imports the original problem (they still have to find things). The
  companion screen displays the conversation; it never becomes a menu.
- **No UI-driver phase.** Expected empty (4.5); building it speculatively
  guarantees its maintenance cost without evidence of need.
- **No auto-send of anything beyond health state.** Auto-snapshots carry system
  truth only. Messages, notes to David, and relays always take a spoken yes.
- **No new ticket store, notification plane, or health stack.** Everything rides
  the observability design and ITIL; a parallel plane would fork truth exactly
  where reliability matters most.
- **No feelings-faking on failure.** The last-resort phrases are honest ("I'm
  having trouble") and never pretend the system is fine. Comfort comes from the
  next step being named, not from pretending.

## 8. What this design cannot do (honest limits)

- It cannot make silence impossible; it makes silence SHORT and always followed
  by a truthful sound. A dead device with a dead battery is still a dead device;
  the guardian unreachable-threshold alert is the only net under that.
- It cannot prevent a root operator reading disk (5). It makes the paved road
  content-free.
- It cannot verify WHO is physically speaking. Speaker identity is the enrolled
  device plus the call session, not a voiceprint. A visitor in their home talking
  to her is a household-trust matter, mitigated by the deny-default policy and
  confirm-class gates, not solved.
- The one-shot trust model cuts both ways: a bad week of infrastructure can still
  end adoption permanently. This design narrows the window; it cannot close it.
- The LLM can still misunderstand a request within its allowed tools (call the
  wrong David). Confirm-class covers the irreversible cases; reversible
  misunderstandings remain conversational repairs.

## 9. Open items (left for a human on purpose)

1. **Family-facing name and voice for the parents' agents.** The engineering
   identity is decided (separate Atlas-template agents, decision 1); whether they
   PRESENT to the parents as "Lumina" with her cloned voice, as "Atlas", or with
   their own names and voices is a family decision (Chef asks his parents), not
   an engineering one.
2. **Open mic vs tap-to-talk default** per parent (dexterity vs privacy
   trade-off), and whether the call is long-lived (always connected during the
   day) or per-interaction. Needs a real trial with the actual users.
3. **The final companion tool allow-list** (4.1 sketches ~15). Chef should strike
   or add items against what his parents actually want in week one.
4. **Guardian thresholds** (unreachable hours, watchdog trip counts) and whether
   guardian alerts also reach a second family member.
5. **PR #70 consent-stance amendment** (4.8): the auto-snapshot delta for
   companion profiles should be reflected in the observability spec's open item 5
   (guest-facing reporting) by whoever lands that phase.
6. **Hardware selection** for the parents' device (tablet on a stand vs
   repurposed laptop; speakerphone quality matters more than screen). Affects
   nothing structural here but decides real-world audio quality.
7. **Legal/consent formalities, if any, for recording the action ledger** in
   their jurisdiction; the ledger stores action summaries, not audio, so this is
   likely trivial, but a human should say so.

## 10. Delivery phases (one coord card each)

Ordered so each ships alone and is useful alone; 1 is load-bearing for all.

1. **Phase 1 (skchat): caller profiles, policy gate, confirmation machine,
   ledger, speakable gate.** FQID-resolved `CallerProfile`, allow/confirm/deny
   dispatch adopted from skreach rbac, held-call spoken confirmation, action
   ledger, companion persona build without runtime facts, TTS speakable gate.
   The security and tone foundation; no client work.
2. **Phase 2 (skchat + runbook): Atlas agents and the spoken check-up.**
   Atlas soul template, per-parent agent + human identity provisioning
   runbook, agent-led energy-verified check-up, re-runnable by voice, plain
   action-stating failure outcomes.
3. **Phase 3 (skworld-app): the companion screen.** Zero-nav route, talk
   affordance with a published local mic track, state pill from existing
   metadata, large-print captions, silence watchdog with bundled last-resort
   audio, the automatic client-side hardware self-test, auto health snapshot on
   trip.
4. **Phase 4 (skchat + skcapstone): the guardian channel.** Operational signal
   set, content-free schema, consent-gated relays, delivery via observability
   triage plane to Chef, ledger surfacing.
5. **Phase 5 (skworld-app): semantics coverage and the read-back bridge.**
   Labels on core screens (the accessibility dual benefit), the semantics
   outline bridge to the agent, canary extension.

Dependencies outward: Phase 3's watchdog snapshot and Phase 4's delivery ride
the observability design's snapshot intake and triage worker (PR #70 phases 4
and 5); until those land, Phase 3 degrades to local-only last resort (still
worth shipping) and Phase 4 delivers via plain skchat DM.
