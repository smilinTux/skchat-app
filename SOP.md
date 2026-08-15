# SKWorld App - Standard Operating Procedures

The Flutter GUI client for **SKChat** — the mobile/desktop/web surface of the
SKWorld sovereign comms layer. It renders, signs, and delegates: it does no
transport, identity, or crypto of its own — it speaks HTTP/WS to a **skchat /
skcomms** daemon, mints room tokens against the SKChat web-UI, joins **LiveKit**
SFU rooms for calls + data-lanes, and caches offline state in **Hive**.

## 0. Naming: the rename is SURFACE-ONLY

The GitHub repository was renamed from `skchat-app` to `skworld-app`, and the README
title and this SOP title were changed to match. **Nothing else was renamed.** Do not
assume the internal identifiers followed, because they did not:

| Identifier | Value today | Where |
|---|---|---|
| Dart package name | `skchat` | `pubspec.yaml:1` |
| pubspec description | still opens with `SKChat`, not SKWorld | `pubspec.yaml:2` |
| workspace members | 2 of the 5 are `skchat_*`: `packages/skchat_ui`, `apps/skchat_standalone` (the other 3 are `packages/skworld_module_api`, `packages/skcode_client`, `apps/skcode_standalone`) | `pubspec.yaml:26-31` |
| CI job checkout path + step names | `skchat-app` | `.github/workflows/ci.yml` |
| CI web build artifact | `skchat-web-<sha>` | `.github/workflows/ci.yml` |
| serving systemd unit | `skchat-app-web.service` | outside this repo, see section 5 |
| GitHub repo name | `skworld-app` (**changed**) | github.com/smilinTux/skworld-app |
| README title, this SOP title | SKWorld App (**changed**) | `README.md:1`, `SOP.md:1` |

So a `pubspec.lock`, a `package:skchat` import, a CI artifact URL, or a Dart
`import 'package:skchat_ui/...'` all still say `skchat`, and they are correct to. The
remaining rename is a real change with a blast radius (lockfiles, import paths across
every consumer, the deploy unit, the artifact contract) and is tracked separately.
Until it lands: **`skchat` is the package identity, `skworld-app` is the repo
identity.** Neither is a typo.

## 1. Overview

**Purpose.** A cross-platform (Android / iOS / Linux / macOS / Windows / web)
Flutter client that gives a human or AI agent one surface for 1:1 chat, groups,
voice/video calls, Spaces (shared rooms with in-call chat / whiteboard / doc /
screen-share / watch lanes), agent presence, and the coord board.

**What it owns.**
- The UI + client-side state (Riverpod providers, GoRouter navigation).
- The send/receive rendering pipeline (`ChatCrypto` sign-and-wrap → `MessageEnvelope` → daemon POST → Hive).
- The LiveKit call/room client (`LiveKitCallService`) and the client half of the data-lane substrate (`LaneService` over the LiveKit data channel).
- At-rest storage of the operator's key material via `flutter_secure_storage` (PGP keypair, PQ hybrid prekey) and offline message/conversation cache via Hive.

**What it explicitly does NOT do.**
- No message transport of its own — every byte goes through the SKComms daemon.
- No identity issuance — CapAuth (via the daemon) is the identity authority.
- No owned crypto primitives — DM sealing/opening is delegated to `sk_pqc`
  (`PqDmCodec` mirrors `skcomms/pqdm.py`); PGP sign/verify uses `pointycastle`;
  the app is a **consumer** of these, not their author. Call-media confidentiality
  is provided by LiveKit's **DTLS-SRTP** leg, not by this app.

## 2. Architecture

The app is a thin Riverpod-wired Flutter front-end. Two backend planes: the
**SKComms daemon** (chat transport, signaling, groups, files, consent) reached
over HTTP/WS, and the **SKChat web-UI + LiveKit SFU** (room-token mint + real-time
audio/video + data-lanes). Offline state lives in Hive.

```mermaid
flowchart TD
    subgraph APP["skworld-app (Flutter, package name still `skchat`)"]
      MAIN["main.dart<br/>ProviderScope + MaterialApp.router"]
      ROUTER["GoRouter (app_router.dart)<br/>chats · conversation · groups · calls · spaces · identity"]
      PROV["Riverpod providers<br/>daemonUrlProvider · backendConfigProvider<br/>skcommsClientProvider · liveKitCallServiceProvider"]
      LKS["LiveKitCallService<br/>(livekit_call_service.dart)"]
      LANE["LaneService<br/>data-lane substrate (spaces/)"]
      HIVE[("Hive<br/>offline cache:<br/>messages · conversations · settings")]
      SS[["flutter_secure_storage<br/>PGP keypair · PQ hybrid prekey"]]
      MAIN --> ROUTER --> PROV
      PROV --> LKS
      LKS --> LANE
      PROV --> HIVE
      PROV --> SS
    end

    DAEMON["skchat / skcomms daemon<br/>REST + WS (:9384 native / same-origin web)"]
    WEBUI["SKChat web-UI<br/>/livekit/token · /spaces/*/lanes/*"]
    SFU["LiveKit SFU<br/>(wss, DTLS-SRTP media)"]
    CAP["CapAuth (via daemon)<br/>PGP identity · QR pairing"]
    SKCAP["skcapstone daemon (:7777) + dashboard (:7778)<br/>agent presence · consciousness · coord board"]

    PROV <-->|"send · inbox · groups · consent (HTTP/WS)"| DAEMON
    PROV <-->|"who's online · coord"| SKCAP
    PROV <-->|"PGP sign · QR login"| CAP
    LKS -->|"POST /livekit/token (mint room JWT)"| WEBUI
    LKS <-->|"join room · publish/subscribe tracks + data"| SFU
    LANE -->|"mirror lane events (best-effort persist)"| WEBUI
    SFU -.->|"DataReceivedEvent ⇒ _dataCtl (receive-wire)"| LKS
```

> **Lane substrate note.** In-call chat and the whiteboard/doc lanes are provided
> by the **upstream Spaces lane substrate** (`lib/features/spaces/` +
> `LaneService`), which publishes/subscribes lane events over the LiveKit data
> channel. `LaneService.inbound` maps over `LiveKitCallService.dataChannel`
> (backed by the private `_dataCtl` stream). **This session added the `_dataCtl`
> receive-wire** — a `Room` `EventsListener` that forwards every
> `DataReceivedEvent` into `_dataCtl` — so the lanes now *actually receive*.
> Before it, `sendData` published fine but no inbound lane event ever arrived
> (send-only). See §7 and §8.

**Start here** (the files to open first):
- `lib/main.dart` — app entrypoint; `ProviderScope` + `MaterialApp.router`; eagerly starts sync, loads the PGP identity, and bootstraps the PQ prekey.
- `lib/core/router/app_router.dart` — the GoRouter route table (chats, conversation, groups, calls, spaces, identity, onboarding).
- `lib/services/livekit_call_service.dart` — the LiveKit room client: token mint, join/leave, track controls, the data-channel send (`sendData`) **and the new `_dataCtl` receive-wire**.
- `lib/services/lane_service.dart` — the client data-lane substrate that rides the LiveKit data channel and mirrors to the server lane store.
- `lib/services/daemon_config.dart` / `lib/services/backend_config.dart` — runtime-settable daemon + backend URLs (the "point it at my box" knobs).

## 3. Build

Requires the **Flutter SDK ^3.11** (Dart ^3.11).

```bash
flutter pub get          # resolve dependencies
```

**Codegen.** The tree uses `freezed_annotation` in `pubspec.yaml`, but the
committed source is **hand-written — no generated `*.g.dart` / `*.freezed.dart`
files are checked in and none are required to build.** `build_runner` is *not*
part of the normal build. Only run it if you introduce new `@freezed` /
`json_serializable` types:

```bash
dart run build_runner build --delete-conflicting-outputs   # only if you add codegen
```

**Platform builds:**

```bash
flutter build web        # web bundle → build/web/
flutter build apk        # Android
flutter build linux      # desktop (also scripts/launch-linux.sh)
# ios / macos / windows likewise
```

> **Local dependency note.** `sk_pqc` is pinned via a `dependency_overrides`
> path (`../sk-pqc-dart`) relative to the checkout root. A worktree or clone that
> does not have a sibling `sk-pqc-dart/` will fail `pub get` — symlink or clone it
> next to the app checkout first.

## 4. Test

The gate is **analyze-clean + tests-green**:

```bash
flutter analyze          # static analysis — must be clean (info-level lints OK)
flutter test             # unit/widget tests — must pass
```

Both must pass before merge (see `CONTRIBUTING.md`). CI-equivalent local run:
`flutter pub get && flutter analyze && flutter test`.

**What CI actually gates** (`.github/workflows/ci.yml`, Flutter pinned `3.41.2`), in
order, because the local two-liner above is a subset:

1. **`import-gate` job** (pure bash, no Flutter toolchain, so a resolution failure
   cannot mask it). Four scripts, each run as its own step:
   `packages/skchat_ui/tool/import_gate.sh`,
   `apps/skchat_standalone/tool/standalone_import_gate.sh`,
   `packages/skcode_client/tool/import_gate.sh`,
   `apps/skcode_standalone/tool/standalone_import_gate.sh`. They prove the module
   packages import only `skworld_module_api` plus Flutter/Dart core, and that the
   standalone runners never import the app shell (`package:skchat`).
2. **`flutter` job.** Checks this repo out at `skchat-app/` and the **sibling**
   `smilinTux/sk-pqc-dart` at `sk-pqc-dart/`, because `dependency_overrides` pins
   `sk_pqc` to `../sk-pqc-dart` (`pubspec.yaml:168-170`) and pub applies overrides
   unconditionally. Then it **builds liboqs `0.12.0` from source** (ML-KEM-768, cached)
   because the PQ tests exercise the real backend through sk_pqc's FFI.
3. `flutter analyze --no-fatal-infos` (warnings stay fatal; pre-existing info-level
   hints do not gate).
4. **Five separate `flutter test` invocations**, not one: the root app, then
   `packages/skchat_ui`, `apps/skchat_standalone`, `packages/skcode_client`,
   `apps/skcode_standalone`. Workspace members are **not** run by the root
   `flutter test`, so a green root run proves nothing about them.
5. `flutter build web --release --base-href /app/`, then a preflight that fails if any
   of `index.html`, `main.dart.js`, `flutter_bootstrap.js`, `sk_pqc_noble.js` is
   missing from `build/web` (a green build with a missing `sk_pqc_noble.js` breaks
   hybrid DMs at runtime).
6. Uploads the bundle as artifact `skchat-web-<sha>`.

## 5. Release / Deploy

Multi-platform Flutter client — there is no server to deploy, only artifacts to
build and (for web) to serve.

- **Native (mobile/desktop):** `flutter build <apk|ios|linux|macos|windows>` →
  ship the platform artifact. Point the build at a specific backend with
  `--dart-define` (see §6).
- **Web:** `flutter build web --release --base-href /app/` produces a static bundle in
  `build/web/`. Two serving paths exist and they are not the same thing: same-origin
  behind the SKChat web-UI reverse proxy, and the direct `0.0.0.0:8088` static server
  that skchat ships. Both are described under Front-end / Exposure below.

### Front-end / Exposure

**Tier `T0` client. This repo binds nothing.** On every platform (Android, iOS,
Linux, macOS, Windows, web) the app only opens **outbound** HTTP/WS/WSS connections.
There is no listener in this codebase and no `:443` route it owns.

Every surface listed below belongs to a **different repo**. They are recorded here so
a reader of this SOP is not surprised by them, and each row names its real owner. Do
not treat any of them as a fact this repo can assert or change.

| Surface | Where it binds | Owned by |
|---|---|---|
| the built web bundle (`build/web`) | **`0.0.0.0:8088`** (see below) | **skchat** |
| SKChat web-UI reverse proxy (`/api/v1`, `/daemon`, `/access`, `/spaces`, `/livekit/token`) | funnel / tailnet | skchat |
| skcomms daemon | `:9384` (see below) | skcomms |
| LiveKit SFU | `wss` (default `:8443` in `backend_config.dart`) | the LiveKit deployment |
| skcapstone daemon / dashboard | `:7777` / `:7778` | skcapstone |
| skbloom | `:8774` | skbloom |

**The web build is served on `0.0.0.0:8088`.** This SOP previously omitted the
serving surface entirely. The serving script is `scripts/serve-app-web.sh` **in the
skchat repo, not this one** (a wrapper over `serve_app_web.py`: correct content types,
no-cache on `index.html`, immutable cache on hashed filenames, autoindex disabled).
The unit `skchat-app-web.service` that skchat ships sets `SKCHAT_APP_WEB_PORT=8088`
and `SKCHAT_APP_WEB_BIND=0.0.0.0`, so `:8088` is reached **directly on the LAN and
tailnet**, not funnel-fronted. The script's own default bind is `127.0.0.1`; the unit
overrides it. To change any of that, change it in **skchat**. Note also that the app
must be built with `--base-href /app/` to match the production serve path (CI does
this), or the deployed bundle 404s its assets and never boots.

**On `:9384`, correcting an earlier revision of this SOP.** That revision claimed
second-hand that the reverse proxy meant "no daemon port is exposed". **Do not repeat
that claim.** This repo does not own the skcomms bind and cannot verify it from its own
tree; observed on a live node, `:9384` binds `0.0.0.0`, so it is reachable across the
LAN and the tailnet. The skcomms daemon's exposure is **skcomms' documented fact**;
read it there. Design client behaviour (URL handling, mixed content, CORS) without
assuming a same-origin-only daemon.

**What this repo can still say honestly:** prefer the same-origin web-UI proxy so the
browser is not making cross-origin or mixed-content calls, never point a production
build at a plain-HTTP daemon across an untrusted path, and remember that repointing is
a one-field operation for the user (`setCustomHost()` in `backend_config.dart:333`
derives the whole backend stack from one `scheme://host[:port]`), so a bad default
propagates everywhere at once.

Versioning: SemVer plus a build number in `pubspec.yaml` `version:` (`X.Y.Z+build`);
bump it there, add a `CHANGELOG.md` entry, and tag on release (see §9).

## 6. Configuration / Usage

**Daemon + backend URLs.** Two reactive config layers, both persisted in the
Hive `settings` box and both repointable at runtime from the Profile screen:

| Provider | Default | Override |
|---|---|---|
| `daemonUrlProvider` (`daemon_config.dart`) | native `http://localhost:9384`; **web = same origin** the app was served from | `--dart-define=SKCOMMS_URL=...` or Profile screen |
| `backendConfigProvider` (`backend_config.dart`) | web-UI `https://noroc2027.tail204f0c.ts.net`; LiveKit SFU `wss://localhost:8443`; skcapstone `:7777` / dash `:7778`; skbloom `:8774` | `--dart-define=SKCHAT_WEBUI_URL / LIVEKIT_URL / LIVEKIT_WEBUI_URL / SKCAPSTONE_URL / SKCAPSTONE_DASHBOARD_URL / SKBLOOM_URL` or presets |

Built-in **federation presets** (`kBackendPresets`): `lumina @ .158` and
`jarvis @ .41` repoint every backend (including the daemon URL) to one host.
`setCustomHost()` derives the whole stack from a single `scheme://host[:port]`.

Example (run against a remote box):

```bash
flutter run -d linux \
  --dart-define=SKCOMMS_URL=https://noroc2027.tail204f0c.ts.net \
  --dart-define=SKCAPSTONE_URL=http://noroc2027.tail204f0c.ts.net:7777
```

**Secure storage.** `flutter_secure_storage` holds, keyed:
- `pgp_public_key` / `pgp_private_key` / `pgp_fingerprint` — the local PGP identity (`identity_service.dart`).
- `pqc_hybrid_public_hex` / `pqc_hybrid_private_hex` / `pqc_hybrid_key_id` / `pqc_device_id` — the per-device PQ hybrid prekey (`pq_prekey_service.dart`).

Offline state (messages, conversations, settings) lives in Hive boxes; keys are
platform keystore-backed (Keychain / Keystore / libsecret / DPAPI).

## 7. API / Reference

**Key providers** (entry points for callers/tests):

| Provider | Role |
|---|---|
| `daemonUrlProvider` / `daemonWsUrlProvider` | live SKComms daemon HTTP + WS base |
| `backendConfigProvider` | live web-UI / LiveKit / skcapstone / skbloom URLs |
| `skcommsClientProvider` | REST/WS client to the daemon (send, inbox, groups) |
| `liveKitCallServiceProvider` | scoped `LiveKitCallService` (auto-disposes on config change) |
| `identityServiceProvider` / `identityKeyPairProvider` | local PGP identity load/save |
| `pqPrekeyServiceProvider` / `pqBootstrapProvider` | PQ hybrid prekey generate + publish |
| `spacesServiceProvider` | Spaces directory + room-token mint |
| `skCapstoneClientProvider` | agent presence, consciousness, coord board |

**LiveKit data-lane message shapes.** The Spaces lanes (upstream substrate,
`lib/features/spaces/`) exchange UTF-8 JSON over the LiveKit data channel via
`LaneService`. Every event carries a `"lane"` key; `LaneService.inbound` filters
on it. Observed shapes:

```jsonc
// chat lane        (space_chat_panel.dart)
{ "lane": "chat", "from": "<identity>", "text": "<string>", "ts": <epoch_ms> }

// whiteboard lane  (whiteboard_panel.dart) — snapshot: latest full state wins
{ "lane": "whiteboard", "from": "<identity>", "strokes": [ /* serialized strokes */ ] }

// doc lane         (doc_panel.dart)
{ "lane": "doc", ... }
```

`LiveKitCallService.sendData({topic, payload, reliable, destinationIdentities})`
publishes to the room; **`LiveKitCallService.dataChannel`** is the inbound
stream `({String topic, List<int> payload, String senderIdentity})`. That stream
is fed by the private `_dataCtl` **receive-wire added this session**: a
`Room` `EventsListener` `.on<DataReceivedEvent>` handler that forwards
`{topic, data, participant.identity}` into `_dataCtl`. Without it the lanes were
send-only. `LaneService.publish()` additionally best-effort mirrors each event to
`POST /spaces/{id}/lanes/event`, and `catchUp(lane)` replays persisted state from
`GET /spaces/{id}/lanes/{lane}/state` on join.

**Message pipeline.** `ChatCrypto.signAndWrap` → `MessageEnvelope`
(`{skchat_envelope: true, …}` JSON) → `POST /api/v1/send` on the daemon;
inbound envelopes are parsed (`tryParse`, graceful fallback to raw text),
cached in Hive, and rendered. DMs may additionally be sealed by `PqDmCodec`
(hybrid `x25519-mlkem768` KEM + HKDF-SHA256 + AES-256-GCM, via `sk_pqc`),
byte-for-byte interoperable with the daemon's `pqdm.py`.

## 8. Troubleshooting

| Symptom | Check |
|---|---|
| In-call chat / whiteboard shows my own messages but never peers' | The `_dataCtl` receive-wire (`_bindRoomListeners` in `livekit_call_service.dart`). If a build predates it, `dataChannel` never emits — lanes are send-only. |
| "daemon offline" on web after moving hosts | `daemonUrlProvider` seeds from the served origin; a stale persisted `settings/skcomms_daemon_url` (esp. one ending in `/api`) mis-routes. Reset via Profile or clear the Hive `settings` box. |
| `pub get` fails: `could not find package sk_pqc at "../sk-pqc-dart"` | `dependency_overrides` points at a sibling `sk-pqc-dart/`. Clone/symlink it next to the checkout root (worktrees resolve `../` from the worktree dir). |
| Calls connect but never see remote video/audio | LiveKit SFU URL (`backendConfigProvider.livekitUrl`) unreachable, or the server returned a `livekit_url` that routes off your tailnet. Verify `wss://…:8443` reachability. |
| Web build served but browser blocks daemon calls | Cross-origin / mixed content. The bundle can be reached two ways: same-origin behind the web-UI reverse proxy, or directly on `:8088` (skchat's static server), where the daemon is *not* same-origin. Prefer the proxy path, or set an explicit daemon URL. See §5. |
| Web build loads a blank page and 404s its assets | Built without `--base-href /app/`, which must match the production serve path. CI builds with it, a hand build may not. |
| Messages send unsigned | No local keypair loaded yet (mid-onboarding). Signing is best-effort; complete identity pairing (`identity_service.dart`). |
| PQ badge never shows / DMs stay classical | `pqBootstrapProvider` failed to publish the prekey, or the peer has no published prekey. Check `pq_prekey_service.dart` publish and the daemon's prekey store. |

## 9. Maturity-tier + Version reference

- **Maturity tier: `T0 — Classical` (app layer).** Per
  [`CRYPTOGRAPHY_STANDARD` maturity tiers](https://github.com/smilinTux/sk-standards),
  this app is a **crypto consumer, not a crypto owner**: it holds key material at
  rest in the platform keystore (PGP keypair; PQ hybrid prekey) and *invokes*
  hybrid sealing, but the primitives are **delegated** to `sk_pqc`, `skcomms`, and
  `skchat`. The DM lane it plumbs uses `sk_pqc`'s hybrid `x25519-mlkem768` KEM
  (a T2-class posture **owned by `sk_pqc`**, not asserted here). Call-media
  confidentiality is LiveKit **DTLS-SRTP** — a classical transport leg, stated
  honestly, not a post-quantum guarantee.
- **VERSION_LIFECYCLE phase:** Active (default, all new work) — see
  [`VERSION_LIFECYCLE`](https://github.com/smilinTux/sk-standards).
- **Version: read it from `pubspec.yaml`, not from here.** The single source of truth
  is the `version: X.Y.Z+build` field at `pubspec.yaml:5` (SemVer plus a build
  number). Bump it there, add a `CHANGELOG.md` entry, and tag on release. This
  document deliberately does not quote a number: an earlier revision of both this SOP
  and `README.md` pinned it at `1.0.0` with build `1`, which was **four minor
  versions** behind the tree by the time anyone read it. The evidence block at the end
  of this file fails if a literal `X.Y.Z+N` is ever written back into either doc.

---

_Honest-claims note: no part of this repo is "quantum-proof", "quantum-safe", or
"unbreakable". Post-quantum protection is limited to the DM KEM surface provided
by `sk_pqc`; the call-media leg is DTLS-SRTP (classical)._

<!-- docs-evidence
verified: 2026-08-15
checks:
  - name: Dart package name is still skchat (section 0 surface-only-rename claim)
    run: grep -qxF "name: skchat" pubspec.yaml
  - name: documented workspace member paths exist and are declared
    run: grep -qxF "  - packages/skchat_ui" pubspec.yaml && grep -qxF "  - apps/skchat_standalone" pubspec.yaml && test -d packages/skchat_ui && test -d apps/skchat_standalone
  - name: version lives in pubspec.yaml and is NOT hardcoded into SOP.md or README.md
    run: grep -qE "^version: [0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$" pubspec.yaml && ! grep -qE "[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+" SOP.md README.md
  - name: documented entry point lib/main.dart still has the async main
    run: grep -qxF "Future<void> main() async {" lib/main.dart
  - name: sk_pqc still resolves via the sibling ../sk-pqc-dart path override
    run: grep -qxF "    path: ../sk-pqc-dart" pubspec.yaml
  - name: all four documented import-gate scripts exist and are wired into CI
    run: for s in packages/skchat_ui/tool/import_gate.sh apps/skchat_standalone/tool/standalone_import_gate.sh packages/skcode_client/tool/import_gate.sh apps/skcode_standalone/tool/standalone_import_gate.sh; do test -f "$s" && grep -qF "bash $s" .github/workflows/ci.yml || exit 1; done
  - name: CI still runs exactly the five documented flutter test invocations
    run: test "$(grep -cE "^ +run: flutter test$" .github/workflows/ci.yml)" -eq 5
  - name: CI still builds the documented liboqs 0.12.0 from source
    run: grep -qF -- "--branch 0.12.0" .github/workflows/ci.yml && grep -qxF "          key: liboqs-0.12.0-\${{ runner.os }}" .github/workflows/ci.yml
  - name: web build still uses the documented production base href /app/
    run: grep -qxF "        run: flutter build web --release --base-href /app/" .github/workflows/ci.yml
  - name: CI web artifact name is still skchat-web (section 0 rename claim)
    run: grep -qxF "          name: skchat-web-\${{ github.sha }}" .github/workflows/ci.yml
-->

