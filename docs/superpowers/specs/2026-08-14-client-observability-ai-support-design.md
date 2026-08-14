# Client Observability and AI-First Support: Design

**Date:** 2026-08-14
**Repo:** skworld-app (Flutter client), with a small server assist in skchat.
**Status:** Proposed (design). Coord card `0a5b8e07` is the minimal seed of Phase 2.
**Driven by:** incident `inc-8c694c69`, problem `prb-acaa3b82`, known error `ke-40a2693d`.

## 1. Goal

Make the app explain itself. When something breaks, a non-engineer at 2am must be
able to see WHAT is broken in plain language, and get help with one tap, without
shell access to any server.

1. **See:** a health surface under Me that distinguishes healthy, broken, stalled,
   and "cannot tell", per backend dependency, honestly.
2. **Remember:** a bounded, structured, secret-free event log inside the client,
   so the last N minutes of truth survive to the moment someone asks "what happened".
3. **Report:** one button that captures a diagnostic snapshot (a core dump of
   whitelisted state), shows the operator exactly what it contains, uploads it,
   and opens a ticket in the existing ITIL system.
4. **Triage:** an AI agent reads the snapshot (it is machine-shaped on purpose),
   classifies it, checks the KEDB, dedupes against open incidents, and answers the
   operator in plain words with a ticket id and a workaround if one is known.

Design bias throughout: **silence must be distinguishable from health.** Every
decision below exists to prevent a specific failure we actually had.

### 1.1 The north star incident (why each piece exists)

On 2026-08-14, `skworld-100` (STT, TTS, LLM host) died mid voice-call. From the
operator's seat the only symptom was that Lumina stopped answering. Diagnosis took
shell access, journalctl, and an hour of wrong theories. Three separate silences
read as normal that night:

| Failure | What hid it | Design answer |
|---|---|---|
| Dependency outage invisible in the client | No health surface in the app at all | Phase 2: health matrix under Me, with an honest "unknown" state |
| `ERROR skchat.voice_engine.stt: STT failed:` (message EMPTY, `str()` on an httpx connect timeout is blank; `voice_engine/stt.py:127`) | Errors carried as free-form strings; an empty string is a legal log line | Phase 1: structured event codes with typed fields; the failure KIND and the dependency NAME are fields, not prose, so an information-free event cannot be produced |
| A poll loop idled 20 minutes with work waiting, logging nothing | A stuck loop and a healthy idle loop emit the same output: nothing | Phase 3: heartbeat registry; a loop that misses its own declared interval becomes a visible "stalled" state |
| A media test PASSED on pure silence (peak amplitude 2) | Byte counting: a track streams whether or not anyone talks | Phase 3: audio energy watchdog; "call active but no audio energy for N seconds" is an event, not nothing |

## 2. Current state (grounding)

What already exists in `skworld-app` (all paths under `lib/` unless noted):

- **Logging: greenfield.** No logging package, no central logger, 5 `debugPrint`
  sites total. Critically, `main.dart:22` replaces `debugPrint` with a no-op in
  release builds and swallows `FlutterError.onError` (a sovereign build must not
  write to the host console). Today errors go NOWHERE. The ring buffer becomes the
  sink that replaces that no-op.
- **Health, fragmented.** `services/skcomms_sync.dart` already models
  `DaemonStatus { connecting, online, offline, error }` with poll timers;
  `services/capabilities_service.dart` + `features/profile/widgets/capabilities_section.dart`
  render capability dots; `features/consciousness/backend_health_widget.dart` is
  the closest visual template for a per-backend up/down card. Nothing aggregates
  these, and nothing models "unknown" as distinct from "down".
- **Me screen.** `features/profile/profile_screen.dart`, sections are
  `_SectionLabel` + `GlassCard` entries in a ListView; the established card
  pattern is a self-contained ConsumerWidget in `features/profile/widgets/`
  that renders `SizedBox.shrink()` on error (see `capabilities_section.dart`,
  which splits Consumer from a stateless View for widget testing).
- **Networking.** dio only, no shared base client; each service builds its own
  Dio. The central seam is `services/operator_auth_interceptor.dart`
  (`buildOperatorAuthInterceptor`), attached by every operator-gated client. It is
  fail-open by contract. A diagnostics interceptor sits beside it the same way.
- **Platform seams.** Two established styles: injectable-parameter pure functions
  (`features/spaces/screen_share_helper.dart`) and conditional-import triples
  `_stub/_io/_web` behind a facade (`services/operator_token.dart`). Storage for
  the ring buffer uses the second style only if Hive proves insufficient; Hive
  (`hive_flutter`) already runs on web (IndexedDB) and native, opened
  corruption-tolerantly via `main.dart:_openBoxSafely`.
- **Calls.** `services/livekit_call_service.dart` already exposes broadcast
  streams: `connectionState`, `participants` (snapshots carry
  `connectionQuality`, `isSpeaking`, mute states), `micEnabledChanges`. Nothing
  calls `Room.getStats`; there is no amplitude measurement anywhere. UI precedent:
  `features/call_shared/connection_quality_bars.dart`.
- **Secrets on the client** (the reason redaction is a whitelist): operator raw
  token and session JWT in web localStorage (`services/operator_token.dart`,
  `services/operator_session_store.dart`), capauth audience tokens in memory,
  PGP identity keypair and PQ hybrid prekeys in secure storage
  (`services/identity_service.dart`, `services/pq_prekey_service.dart`), guest
  link invite JWT + fragment secret (`features/guest/guest_link.dart`), LiveKit
  room tokens in memory, the 24-word recovery phrase. Message content is also
  never observable by this layer.
- **Ticketing exists.** `skcapstone itil incident|problem|kedb` and
  `skcapstone coord` are live on every node. This design creates NO new ticket
  store; the snapshot path terminates in an ITIL incident.
- **Server.** skchat webui already serves `/health` and `/api/v1/status`; the
  voice engine (`skchat/src/skchat/voice_engine/`) knows its own STT/TTS/LLM
  endpoints but exposes no aggregated dependency health.

## 3. Decisions

1. **Structured events, not log lines.** An event is
   `{seq, ts, level, category, code, fields}`. `code` comes from a registered
   catalog; each code declares its allowed field keys and types. Free-form prose
   never enters the buffer. This is what makes the snapshot machine-triageable
   and what makes an empty "STT failed:" impossible to reproduce client-side.
2. **Redaction by construction, not by filtering.** Nothing scans output for
   secrets. Secrets never enter the pipeline because no event schema has a slot
   they could occupy, and the snapshot builder can only read explicitly
   registered whitelisted sections. There is no code path that serializes
   arbitrary state.
3. **Failure kind is a classification, not a string.** Network errors are mapped
   to an enum (`dns`, `refused`, `connectTimeout`, `readTimeout`, `tls`,
   `http4xx`, `http5xx`, `aborted`, `unknown`) plus target `host:port` and path
   TEMPLATE (never query strings). Exception `runtimeType` may be included;
   exception `message` never is (that is where URLs, tokens and payloads leak).
4. **"Unknown" is a first-class health state.** If the client cannot reach
   skchat, every downstream dependency renders "unknown (can't reach server)",
   with the last known state and its age. Unreachable is never rendered green
   and never rendered as a confident "down" for things we cannot see.
5. **Liveness is declared, then policed.** Loops and pipelines register an
   expected beat interval; missing it is a visible event and a "stalled" health
   state. Silence stops being ambiguous by fiat.
6. **The operator sees what ships.** A snapshot is captured, PREVIEWED on
   screen, and sent only on an explicit tap. No automatic background uploads.
7. **Everything is bounded.** Ring buffer capacity, persisted tail size, snapshot
   size, offline queue depth, server retention: all hard caps, enumerated below.
8. **Cheap when healthy.** No per-event disk writes, no polling faster than the
   surface needs, no stats sampling outside active calls, debug level off by
   default. Observability that degrades a call gets disabled and then protects
   nothing.
9. **Reuse the ITIL plane.** Upload terminates in `itil incident create`; triage
   refines via `itil incident update` and `itil kedb search`. No parallel ticket
   store, ever.

## 4. Architecture and components

New code lives in `lib/services/diag/` (service + provider per file, matching
repo convention) plus one Me card in `lib/features/profile/widgets/`.

### 4.1 DiagEvent and the code catalog (`diag_event.dart`)

```dart
class DiagEvent {
  final int seq;            // monotonic, session-scoped
  final DateTime ts;        // UTC
  final DiagLevel level;    // error | warn | info | debug
  final DiagCategory cat;   // net | call | voice | auth | store | health | ui | lifecycle
  final String code;        // from the catalog, e.g. 'net.request_failed'
  final Map<String, Object> fields; // keys validated against the catalog entry
}
```

The catalog (`diag_codes.dart`) is a compile-time map from `code` to the set of
allowed field keys with expected types. `DiagLog.emit` drops (in debug: asserts
on) any field not declared for the code. Initial catalog, roughly 25 codes:

- `net.request_failed` fields: `kind` (failure enum from Decision 3), `host`,
  `port`, `pathTemplate`, `method`, `status?`, `durationMs`
- `net.request_slow` fields: `host`, `port`, `pathTemplate`, `durationMs`
- `auth.retry`, `auth.session_expired`, `auth.mint_failed` fields: `credential`
  (enum: session|audience|operator, never the value), `status?`
- `call.state` fields: `state`, `room` (sha256 short hash, not the name),
  `peerCount`
- `call.quality` fields: `quality`, `participant` (local|remote index, not identity)
- `call.media_silent` fields: `directionEnum`, `silentForMs`, `trackActive`
- `voice.turn` fields: `stage` (heard|transcribing|thinking|speaking), `durationMs?`
- `health.change` fields: `dep`, `from`, `to`, `probe` (client|server)
- `beat.missed` fields: `loop`, `expectedMs`, `silentForMs`
- `store.box_corrupt`, `store.flush_failed` fields: `box`, `bytes?`
- `lifecycle.start`, `lifecycle.resume`, `lifecycle.error` fields: `buildId`,
  `errorType?` (runtimeType name only)

Adding a code is a code review event: the reviewer sees exactly which keys the
event may carry. That review IS the privacy gate.

### 4.2 DiagLog ring buffer (`diag_log.dart`)

- In-memory ring, hard cap **1000 events** (a plain fixed-size list with a write
  cursor; no dependency).
- Persistence: a tail of the most recent **300 events, max 256 KB** encoded, is
  flushed to Hive box `diag_log` (opened via the `_openBoxSafely` pattern) on:
  a 30 second debounce timer, app pause/detach, and snapshot capture. Never per
  event. On startup the persisted tail is prepended so a crash keeps its last
  moments.
- Level policy: `debug` events go to the in-memory ring only and are excluded
  from the persisted tail and from snapshots by default. `info` and above
  everywhere.
- Sinks installed in `main.dart`, replacing today's swallow: `FlutterError.onError`
  and `PlatformDispatcher.instance.onError` emit `lifecycle.error` (error
  runtimeType + a stack HASH, not the stack text, see 8. Privacy), then delegate
  to the previous handler in debug builds.
- Exposed as `diagLogProvider` (Notifier), plus a `Stream<DiagEvent>` for the
  live view in the Me surface.

### 4.3 Network breadcrumbs (`diag_interceptor.dart`)

`buildDiagInterceptor(DiagLog)` returns an `InterceptorsWrapper` attached
immediately AFTER `buildOperatorAuthInterceptor` wherever that one is attached
(skcomms_client, device_list_service, skcapstone_client, pq_prekey_service,
livekit token minting). It records:

- on error: one `net.request_failed` with the classified kind (mapping
  `DioException.type` + `SocketException` details to the enum). This is the
  client-side fix for the empty `STT failed:` lesson: classification happens at
  the type level, `e.toString()` is never consulted.
- on response slower than 5 s: `net.request_slow`.
- NEVER: request/response bodies, headers, query strings, full URLs.

Like the auth interceptor, it is fail-open: a diagnostics failure must never
fail a request (wrap the whole handler in a try/catch that gives up silently).

### 4.4 Heartbeat registry (`diag_heartbeat.dart`) [Phase 3]

`HeartbeatRegistry.register(name, expectedInterval)` returns a handle; the owner
calls `beat()` each cycle, optionally with counters (`{polled: n, handled: m}`).
A single 30 s watchdog timer scans registrations; a loop silent for
`> 3 x expectedInterval` emits `beat.missed` and flips a `stalled` flag the
health matrix consumes. First registrants: `skcomms_sync`'s two poll timers,
`incoming_call_watcher`, and the voice turn loop while a call is active.

This is the client half of the "20 minutes of idle with work waiting" fix. The
same discipline is recommended server-side but is out of scope here (see 10).

### 4.5 Media truth watchdog (`diag_media_watch.dart`) [Phase 3]

Active only while a call/space is connected (cheap-when-healthy). Sources, in
order of preference:

1. LiveKit `isSpeaking` + participant audio level from participant snapshots.
2. Where available, `Room.getStats` audio outbound/inbound `audioLevel` /
   `totalAudioEnergy` deltas (currently untapped in the codebase).

Rule: if the call is active, the relevant track is published and unmuted, and no
audio energy has been observed in either direction for **20 s**, emit
`call.media_silent` and surface a soft in-call hint ("No audio is flowing").
This converts the "test harness passed on peak amplitude 2" class of failure
into a visible state: bytes moving is not audio; energy is.

### 4.6 Health model (`health_matrix.dart`) [Phase 2]

```dart
enum DepState { ok, degraded, down, stalled, unknown }
class DepHealth {
  final String id;          // 'skchat', 'stt', 'tts', 'llm', 'livekit'
  final String plainName;   // 'Speech to text (her hearing)'
  final DepState state;
  final DateTime? lastOkAt;
  final DateTime checkedAt; // staleness is rendered from this, always shown
  final String? hint;       // catalog-keyed plain-language hint, not raw error
}
```

Two tiers, because the client can only truthfully vouch for what it can reach:

- **Tier 1 (client-probed):** skchat webui (`/api/v1/status` via the existing
  `skcomms_sync` machinery) and the LiveKit signaling URL when a call surface is
  open. These the client may call `down` with confidence.
- **Tier 2 (server-reported):** STT, TTS, LLM, and anything else the voice
  engine depends on, from a new endpoint `GET /api/v1/health/deps` (see 4.8).
  If Tier 1 says skchat is unreachable, every Tier 2 entry becomes
  `unknown` with its last known state and age preserved. **Unreachable never
  renders green** (hard constraint 2), and never renders a confident `down`
  either, because we cannot see.

Polling: 60 s baseline; 15 s while the Health card is visible or a call is
active; zero extra requests otherwise (Tier 1 rides the existing skcomms_sync
poll). Every state CHANGE emits `health.change` into the ring buffer, which
gives the snapshot a timeline of when things fell over.

### 4.7 Me > Health and Logs surface [Phase 2]

Completes coord card `0a5b8e07`. A `HealthSection` in
`features/profile/widgets/health_section.dart` following the
`CapabilitiesSection` split (Consumer wrapper + stateless View for widget
tests), inserted as a new labeled section on `profile_screen.dart`:

- One row per dependency: plain name, state chip (color + word, not color
  alone), "checked 12 s ago" age. `unknown` renders grey with the reason
  ("can't reach server"), `stalled` renders amber with the loop name.
- Wording is for a non-engineer: "Lumina's hearing (speech to text)",
  "Lumina's voice (text to speech)", "Lumina's thinking (language model)",
  "Calling (LiveKit)", "Server (skchat)".
- Tapping a row opens a filtered recent-events view (from the ring buffer,
  category-filtered, newest first, plain-language rendering of each code with a
  "technical details" expander showing the raw fields).
- A **Get help** button lives on this card (Phase 4 wires it; Phase 2 ships it
  disabled with "coming soon" hidden, or simply omits it).
- Renders honestly when offline: last known states, ages, everything `unknown`
  where the server would have to answer. Never `SizedBox.shrink()` for the whole
  card (unlike passive cards, this one's job is precisely to be present when
  things are broken); it degrades row by row instead.

### 4.8 Server assist: `GET /api/v1/health/deps` (skchat) [Phase 2]

Small FastAPI route in skchat webui. Returns, per configured dependency of the
voice engine + SFU:

```json
{"deps": [{"id": "stt", "url_host": "192.168.0.100:18794", "state": "down",
            "kind": "connectTimeout", "checked_at": "...", "latency_ms": null}],
 "checked_at": "...", "cache_age_s": 14}
```

- Probes are lightweight (HEAD/GET on each service's health path, 2 s timeout),
  executed server-side on a 30 s cache; the endpoint never fans out per client
  request. Failure kinds use the same enum as the client (shared vocabulary).
- Auth: same data-plane gating as other `/api/v1` routes. The client MUST attach
  `buildOperatorAuthInterceptor` (documented trap: a gated route 401s before its
  handler when the client sends only the pasted token).
- This endpoint is also the server-side seed for fixing `ke-40a2693d` properly
  (the voice engine learning to name its dead dependency), but rewriting voice
  engine error handling is a skchat work item, referenced, not designed here.

### 4.9 Snapshot: the core dump (`diag_snapshot.dart`) [Phase 4]

A versioned JSON document, `{"snapshot_schema": 1, ...}`, built by
`SnapshotBuilder`, which can ONLY assemble sections from an explicit registry of
`DiagSection` providers. Each section is a pure function of already-whitelisted
state. The full section list IS the whitelist; anything not listed cannot ship:

| Section | Contents |
|---|---|
| `build` | `kAppVersion`, `kBuildId` (from `core/build_info.dart`), schema version |
| `platform` | OS family, browser family (web), form factor, locale. No device ids, no user agent string |
| `backend` | For each `BackendConfig` entry: host, port, scheme. Never credentials, never query strings, never the operator token/session (they live elsewhere and no section reads them) |
| `flags` | Feature flag names + boolean values (`core/config/feature_flags.dart`) |
| `health` | Current `DepHealth` matrix + the `health.change` timeline |
| `beats` | Heartbeat registry: loop names, expected intervals, last beat ages |
| `events` | The ring buffer, `info`+ only, oldest dropped first to fit the cap |
| `call` | If a call is active or ended < 10 min ago: state timeline, durations, quality history, participant COUNT, peer capauth URI (see 8), media-silent events. Never room tokens, never message or audio content |
| `storage` | Box names + entry counts + approximate sizes (spot a runaway store) |
| `operator_note` | Optional free text typed by the operator at capture time, marked as operator-provided |

- Hard cap: **256 KB of JSON, 128 KB gzipped target**; the builder drops oldest
  `events` first, then truncates `call` history, and stamps `"truncated": true`.
- The canary test (see 9) plants fake secrets in every secret store and asserts
  no snapshot byte sequence matches any of them.

### 4.10 Capture, preview, upload, queue [Phase 4]

Flow, from the Get help button (Health card, and from in-call error surfaces):

1. **Capture** synchronously (builder reads providers; no I/O besides the Hive
   tail, already in memory).
2. **Preview screen**: the operator sees the actual sections that will be sent,
   human-rendered, with the raw JSON one expander away, plus a one-line text
   field "What were you trying to do?". Nothing sends without the Send tap.
3. **Send**: `POST /api/v1/support/snapshot` (multipart, reusing the
   `FormData.fromMap` precedent from `skcomms_client.dart:526`), through
   `buildOperatorAuthInterceptor`. Response: `{snapshot_id, incident_id?}`.
4. **Offline / failed**: the snapshot is queued in Hive box `diag_outbox`
   (max **3** snapshots; oldest evicted with a visible note), retried when
   `skcomms_sync` transitions back to online. The UI says "Saved. It will send
   when the server is reachable", which is the honest sentence, not an error.
5. **Confirmation**: the app shows the incident id and keeps the last sent
   snapshot viewable ("what I sent") until the next capture.

### 4.11 Server: snapshot intake + incident creation (skchat) [Phase 4]

`POST /api/v1/support/snapshot` (operator-gated, added to
`_ROUTE_CAPABILITY_RULES`):

- Validates schema version and the size cap (reject > 512 KB, defense in depth).
- Stores under `~/.skchat/support/snapshots/<snapshot_id>.json.gz`, retention
  **30 days or 50 snapshots**, whichever bounds first (pruned on write).
- Creates the incident SYNCHRONOUSLY via the skcapstone ITIL Python API
  (same venv, same box): sev4 default, title from a deterministic classifier
  over the snapshot's event codes (e.g. "App report: STT unreachable
  (connectTimeout)"), service tags from the health section, tag
  `source:app-snapshot`, snapshot id in the incident record. Returns
  `incident_id` so the 2am operator leaves with a ticket number in hand.
- If ITIL creation fails, the snapshot is still stored and the response carries
  only `snapshot_id`; the triage agent (4.12) creates the incident on pickup.
  Fail-soft in both directions: intake never depends on triage being alive.
- A spool marker (`support/spool/<snapshot_id>`) queues it for triage.

### 4.12 AI triage worker [Phase 5]

A worker in the existing agent plane (systemd timer or spool watcher running as
lumina; implementation home decided at build time, skchat scripts/ or
skcapstone, NOT a new service framework). Per spooled snapshot:

1. **Deterministic pre-classification first.** Most real cases need no LLM:
   `health.deps.stt == down && kind == connectTimeout` maps straight to a known
   playbook. The event-code vocabulary was designed so that this step is a table.
2. **KEDB**: `skcapstone itil kedb search <classified terms>`; a hit attaches
   the known error id and its workaround verbatim.
3. **Dedupe**: open incidents sharing a service tag within a 4 h window get an
   `itil incident update --note` instead of a duplicate; the operator's reply
   references the existing ticket.
4. **LLM assist** for the summary and the unclassified remainder: skgateway at
   `http://localhost:18780/v1`, model `sk-default` (never a hardcoded model).
   Input is the snapshot JSON, not prose logs. Output: a plain-language summary,
   probable cause ranked list, and suggested severity, folded into the incident
   via `itil incident update`.
5. **Close the loop with the human**: a skchat DM to the operator from the
   agent: what it thinks is wrong, in plain words, the ticket id, and the
   workaround if the KEDB had one. This is the "AI-first support" surface: the
   operator's next step arrives in the same app the problem happened in.
6. All drafted OUTBOUND communication beyond that DM (e.g. anything leaving the
   sovereign plane) stays draft-by-default per house rule.

## 5. Data flow (the 2am path, end to end)

```
skworld-100 dies mid-call
  -> client: STT-dependent replies stop; server /api/v1/health/deps flips stt: down
  -> health matrix: 'Lumina's hearing: DOWN (connection timed out), checked 8s ago'
  -> health.change event lands in ring buffer with timestamp
  -> operator opens Me > Health, sees one red row naming the thing, taps Get help
  -> snapshot captured, previewed, sent -> {snapshot_id, inc-xxxxxxxx}
  -> triage: deterministic classify -> KEDB hit ke-40a2693d -> incident updated
  -> DM to operator: "Her hearing (speech to text on skworld-100) is unreachable.
     Ticket inc-xxxxxxxx. Known issue: restarting the answerer will NOT help;
     the .100 host or its STT service needs to come back."
```

Compare with the real night: an hour of theories, a nearly-reverted good PR, and
five skimmed, empty error lines.

## 6. Error handling (of the observability layer itself)

- Every diag component is fail-open and self-limiting: an exception inside a
  sink, interceptor, watchdog or builder is caught, counted (`store.flush_failed`
  style events, themselves capped), and never propagates to app logic.
- The Hive `diag_log` box failing to open falls back to memory-only operation.
- The watchdog scanning loop is itself registered in the heartbeat registry
  (who watches the watchdog: the health matrix does).
- The snapshot endpoint being down is a first-class expected state (that is the
  moment snapshots matter most), handled by the offline queue.

## 7. Security and privacy

- **Whitelist by construction** (Decision 2): the section registry and the event
  code catalog are the only paths into a snapshot; both are code-reviewed
  surfaces. No blacklist scrubbing exists to get out of date.
- Secrets enumerated in section 2 have no representation in any schema. Auth
  events name the credential KIND only.
- Stack traces: `lifecycle.error` records error runtimeType and a stable hash of
  the top frames (dedupe key), not the trace text. Web release builds are
  minified anyway; a symbolication story is deliberately out of scope (see 10).
- Peer identity: the `call` section includes the peer's capauth URI. Rationale:
  this is operator-owned infrastructure, the operator initiated the report, and
  triage is useless without knowing which agent went silent. Guest DISPLAY names
  and guest link material are excluded. If multi-tenant use ever ships, this
  line item must be revisited (flagged in 10).
- The operator note is the ONLY free text in a snapshot and is labeled as such,
  so triage prompts can treat it as untrusted input.
- Transport: same origin + operator-authed route as every other `/api/v1` call;
  snapshots at rest on the server are inside `~/.skchat` with the same posture
  as message history. Retention bounds in 4.11.
- The snapshot preview is not a courtesy, it is the consent mechanism.

## 8. Testing

- **Canary redaction test (the load-bearing one):** a fixture app state seeds
  fake values into every secret store (operator token, session JWT, prekeys,
  guest link secret, recovery phrase words); the test captures a snapshot and
  asserts none of the seeded byte sequences appear anywhere in it. This test
  failing blocks merge, and every new section or code lands with it green.
- Catalog conformance: emitting an unregistered code or field key fails in
  debug; a test enumerates the catalog and round-trips every code.
- Ring buffer: overflow drops oldest, persisted tail respects both caps, corrupt
  box falls back cleanly (reuse `_openBoxSafely` test patterns).
- Health matrix: table-driven state machine tests, including the two honesty
  cases as named tests: "unreachable server never yields ok" and "unreachable
  server yields unknown, not down, for tier-2 deps".
- Heartbeat: a registered loop that stops beating flips to stalled within
  3 intervals; a beating loop never does (no flaky timing: fake clock).
- Interceptor: classified kinds for each `DioExceptionType`; asserts the emitted
  event contains no query string and no body for a request that had both.
- Widget tests for `HealthView` (stateless split) covering all five states plus
  the offline rendering.
- Server: intake size-cap rejection, retention pruning, ITIL-down fail-soft
  (snapshot stored, no 5xx to the client).

## 9. What we deliberately chose NOT to do, and why

- **No third-party telemetry (Sentry, Crashlytics, hosted OTel).** Sovereignty
  is the point of this stack; shipping operator behavior and error context to a
  cloud vendor is the exact failure mode the whitelist exists to prevent.
- **No automatic crash/snapshot upload.** Consent-by-preview is cheap and keeps
  the trust model simple. Cost: a crash the operator does not report is not
  seen. Accepted; the persisted tail means the NEXT session's manual report
  still carries the evidence.
- **No verbose log shipping or remote log streaming into the client.** Server
  logs stay on servers; the client reports what the client knows. Streaming
  journalctl into the app is an ops-console feature, out of scope, and an auth
  surface we do not want on the operator app.
- **No metrics time-series store or dashboards in the client.** The health
  matrix is now-and-recent; fleet history belongs to the fleet control plane.
- **No blacklist scrubber** (regex-for-tokens). It would rot silently; the
  first credential format it does not know about ships in a snapshot.
- **No new ticket system, no parallel support inbox.** ITIL incidents + KEDB +
  coord already exist and sync fleet-wide; a second store would fork truth.
- **No stack symbolication pipeline** for minified web traces in v1. The error
  runtimeType + hash gets dedupe and counting; symbolication is real work with
  low marginal value while the team can reproduce locally.
- **No log-level settings UI** in v1. One switch (debug on/off, default off,
  session-scoped) hidden behind the build label tap, at most.

## 10. Open items (left for a human on purpose)

1. **Peer identity in snapshots** (7): acceptable now on operator-owned infra;
   must be revisited before any multi-tenant or guest-initiated reporting.
2. **Where the triage worker lives** (skchat scripts/ vs skcapstone vs the
   suggestion-engine plane) and its trigger (timer vs spool watcher).
3. **Server-side heartbeat discipline** for the voice engine loops themselves
   (the other half of prb-acaa3b82) is a skchat design of its own; this spec
   only fixes the client's view of it.
4. **Severity policy**: should a snapshot during an ACTIVE call auto-raise sev3?
   Current design says sev4 always, triage raises. A human should own the rule.
5. **Guest-facing reporting**: guests hit the same outages; this design is
   operator-only. Decide whether Phase 4's button appears for guests with a
   further-reduced snapshot, or not at all.

## 11. Delivery phases (one coord card each)

1. **Phase 1: Diagnostic event core.** DiagLog ring buffer, code catalog,
   error sinks replacing the release no-op, dio breadcrumb interceptor, canary
   redaction test. Foundation; no UI beyond a debug listing.
2. **Phase 2: Health matrix + Me surface + server deps endpoint.** Completes
   coord `0a5b8e07`. The honest-unknown model, the plain-language card, and
   `GET /api/v1/health/deps` in skchat.
3. **Phase 3: Silence detectors.** Heartbeat registry over existing loops and
   the in-call media truth watchdog. Makes stalled and silent visible states.
4. **Phase 4: Snapshot capture, preview, upload, ticket.** The core dump,
   the Get help flow, offline queue, server intake, synchronous ITIL incident.
5. **Phase 5: AI triage.** Deterministic classifier, KEDB match, incident
   dedupe, LLM summary via skgateway, operator DM reply.

Each phase ships alone and is useful alone; nothing in a later phase is load
bearing for an earlier one.
