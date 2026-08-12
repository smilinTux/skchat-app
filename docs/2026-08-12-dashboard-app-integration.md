# SKWorld App × SKDashboard: One Interface or Two?

**Date:** 2026-08-12
**Status:** Design / recommendation (no implementation in this doc)
**Question (Chef):** "Should we have two different interfaces, the skdashboard and native app? Can we import the skdashboard into the native app somehow? I think we already started but its link is busted / doesn't render properly." Plus: a model-cards / "model dex" view should be available in the app.

**Short answer:** One interface. The umbrella-shell embed of skdashboard was already built and is 90% live; it is broken by (1) a missing build flag in the deploy script and (2) an asset-auth gap in the embed design. Fix those (about a day), keep skdashboard as the embedded ops engine, and build the model dex as a **native Flutter screen**, whose data plumbing already exists end to end.

---

## 1. Current state, grounded in the code

### 1.1 The two surfaces

| | skworld-app | skdashboard |
|---|---|---|
| Tech | Flutter, deployed as a **web** build served at `/app` by the skchat webui | Python/Starlette console on `:7778` (loopback) |
| Views | Chats, Spaces, Code, Activity, Me + drawer operator surfaces (Cluster, skos Files/Control, Coord Board, Recordings), declared in `skworld-app/lib/core/modules/module_registry.dart:24-149` | Status, ITIL Cockpit, CMDB, Kanban Board, Assistant, Trust, Models (`skdashboard/src/skdashboard/dashboard.py:706-708`, `static/*.html`) |
| Auth | Operator session Bearer via interceptors | **None of its own**; protected only by loopback bind + the gated proxy |

They already overlap twice, and both overlaps are **native screens against shared APIs**, not embeds:

* **Coord Board**: `skworld-app/lib/features/coord/coord_board_screen.dart` renders the same board the dashboard's Kanban shows, via `GET /api/board` proxied same-origin by the webui (`skchat/src/skchat/daemon_proxy.py:1481` forwards to `127.0.0.1:7778/api/board`; capability-gated at `skchat/src/skchat/dataplane_auth.py:135`; the web client swaps the `:7778` base for the served origin at `skworld-app/lib/services/skcapstone_client.dart:174-183`).
* **Manage Models**: `skworld-app/lib/features/profile/manage_models_screen.dart:6-10` writes the same gateway advertise allowlist as the dashboard's Models console. Both go through the single source of truth, skgateway `/admin/models[,/advertise]` (app path: daemon `/api/v1/models/manage` -> `skchat/src/skchat/agent_model.py:295-366`; dashboard path: `skdashboard/src/skdashboard/dashboard.py:664-708`).

### 1.2 The integration that "we already started" (umbrella shell)

A complete Grade B web-embed subapp system exists (card e378d895, umbrella epic 22bcf855):

* **Discovery**: `GET /api/v1/shell/modules` on the webui (`skchat/src/skchat/webui.py:977-993`) aggregates every subapp manifest (`skchat/src/skchat/shell_modules.py:207-301`), rewrites skdashboard's loopback entry URL onto the same-origin `/skdashboard` proxy path (`shell_modules.py:240-247`), strips the operator facet, and (with `SKCHAT_SHELL_REQUIRE_SIGNED=1`) emits only capauth-signed modules tagged `verified: true`.
* **Client loader**: `skworld-app/lib/core/modules/external_modules.dart` fetches that aggregate and merges discovered modules (Board, OS) into the nav (`module_registry.dart:200-206`); route host `/x/:moduleId` (`app_router.dart:69`, `:443-447`) renders `skworld-app/lib/features/shell/external_module_pane.dart`, an **iframe** pane (`skworld-app/lib/features/skcode/skcode_web_embed.dart`) sandboxed without `allow-same-origin` (A3 containment, `skcode_web_embed.dart:32`).
* **Gated reverse proxy**: `/skdashboard/*` -> `:7778` (`webui.py:792-845`), requiring an operator Bearer OR a short-lived module-scoped `embed_token` (`webui.py:544-580`); the authenticated app mints tokens via `POST /api/v1/embed-token` (`webui.py:881-960`; client side `skworld-app/lib/services/embed_token_service.dart`), `rw` allowed only for skdashboard (`external_modules.dart:77`, `webui.py:863-878`).
* **Embed plumbing**: proxied HTML gets root-absolute `href`/`src` rewritten onto `/skdashboard` (`webui.py:360-396`) and a runtime `fetch`/XHR shim injected that re-prefixes API calls and appends the token (`webui.py:404-450`).

**Live server state verified on this node:** `SKCHAT_EMBED_TOKENS=1` and `SKCHAT_SHELL_REQUIRE_SIGNED=1` (`~/.config/skchat/webui-lumina.env:88,92`); all four manifests signed in `~/.skcapstone/shell/modules/`; a live curl of `/api/v1/shell/modules` returns skdashboard with `entry.url = https://noroc2027.tail204f0c.ts.net/skdashboard/` and `verified: true`. The server side is done and healthy.

### 1.3 Root cause of the busted embed

**Primary: the deployed app is compiled with discovery OFF, so the whole path is tree-shaken out.**
`kUseShellDynamicModules` is a compile-time constant defaulting to **false** (`external_modules.dart:28-29`); it only turns on with `--dart-define=USE_SHELL_DYNAMIC_MODULES=true`. The canonical deploy script passes **only** `APP_VERSION` and `BUILD_ID` (`skchat/scripts/deploy-app-web.sh:83-85`). Verified in the shipped bundle (`skchat/src/skchat/static/app`, `.source_commit` = `7753f27`): `main.dart.js` contains **zero** occurrences of the discovery endpoint string `shell/modules`. The Board/OS tabs therefore cannot appear in the production app at all; the only board the deployed app shows is the native Coord screen. Any "Board" tab Chef saw came from a dev build with the flag on.

**Secondary: with the flag on, the pane loads but renders as unstyled dead HTML, because static assets cannot authenticate.**
The embed auth design covers three request classes, and the third one has a hole:

1. Initial iframe navigation: `?embed_token=...` in the URL. Authorized, HTML rewritten, shim injected. Works.
2. Runtime `fetch`/XHR: the injected shim appends the token (`webui.py:404-450`). Works.
3. **`<link>`/`<script>` subresource loads** (`/skdashboard/static/css/board.css`, `.../js/*.js`): the HTML rewriter only re-prefixes them, it does **not** attach the token. They were assumed to be authorized by the path-scoped `SameSite=Lax` `HttpOnly` cookie set on first navigation (`webui.py:583-610`; the assumption is written down at `webui.py:419-421`: the cookie "authorizes the `<link>`/`<script>` asset loads fine"). But the pane is sandboxed **without** `allow-same-origin` (`skcode_web_embed.dart:32`), so its document origin is opaque: for SameSite purposes every request it makes is cross-site, and a Lax cookie is not attached (sandboxed opaque-origin documents effectively have no cookie access at all). Each asset therefore hits the gated proxy credential-less and 401s. Verified live: unauthenticated `GET /skdashboard/` and `GET /skdashboard/static/css/board.css` both return **401** (dataplane auth is on). Result: bare HTML, no CSS, no JS, "doesn't render properly."
   *Confirm in devtools (5 min): load the pane in a flag-on build and check whether the asset requests carry the `skdashboard_embed` cookie. Everything else above is verified from code and live curls.*

**Also latent: the `/skos` pane has the same class of bug, worse.** `skos_proxy` calls `_reverse_proxy` with **no** `html_prefix` and no embed token (`webui.py:848-860`), so skos HTML gets neither the asset/nav rewrite nor the fetch shim. Any root-absolute path in the skos surface escapes the prefix or 401s.

It was NOT: base-href (the deploy script and `tests/test_deployed_app_bundle.py` guard that), CSP, or the proxy path rewrite (the HTML rewrite at `webui.py:360-396` fixed the original blank-pane bug and is idempotent; `models.html` is even prefix-aware itself, `static/models.html:95-99`).

---

## 2. One interface vs two: options

**Constraint worth naming first:** "no webview" (`skworld-app/lib/features/spaces/watch_video_stub.dart:24-26`) applies to **native** builds. The app today ships as Flutter **web**, where the Grade B panes are plain same-origin iframes via `HtmlElementView`, no webview dependency, already working for skcode. So embedding IS viable now, but every Grade B pane goes dark on a future Android/iOS/desktop build unless a webview dep is added. That asymmetry drives the recommendation.

### A. Keep two separate interfaces
Zero work. But skdashboard has no auth of its own, is loopback-bound, is invisible from phone/funnel, and two consoles drift apart. Contradicts the single-pane-of-glass direction and the fleet-control-plane north star. **Rejected.**

### B. Embed skdashboard in the shell, fix the embed, stop there
Maximum reuse, about a day. All seven dashboard tabs appear under one nav, gated by real operator auth over the funnel. Costs: iframe UX (theming mismatch, nested scrolling, no deep links into panes), and everything embedded dies on a future native build. Fine as a floor, wrong as a ceiling.

### C. Rebuild every dashboard view as native Flutter, retire the dashboard UI
Cleanest end state, but rebuilding ITIL Cockpit, CMDB, Kanban, Assistant, and Trust is weeks of work for heavy, low-frequency, desktop-shaped ops views, most of which the AI operator consumes through APIs anyway. Violates reuse-not-rebuild. **Rejected as a program**, correct as a per-view tactic.

### D. Hybrid: one shell, embedded ops engine, native screens where a view earns it. **RECOMMENDED**
The app is **the** interface. skdashboard stops being a second product and becomes two things:

1. **A data/API layer** behind same-origin proxies, which it already is for the two views that matter daily: Coord Board and Models are already native in the app against the same backends (section 1.1). This is the proven pattern in the tree.
2. **An embedded Grade B pane** (fixed per section 4) for the heavy ops views: ITIL Cockpit, CMDB, Kanban, Assistant, Trust. These stay reused, not rebuilt, reachable from the app's nav on any browser, behind operator auth.

Promotion rule going forward: a dashboard view gets a native Flutter screen only when it is user-facing or mobile-relevant enough to justify it, and always against the **same** shared API, never a parallel store. The model dex is the first such promotion (section 3). The standalone `:7778` surface remains loopback-only for dev, never a second front door.

---

## 3. The model dex: native Flutter screen

**Recommendation: native.** Three reasons:

1. **The dex is user-facing**, not ops-only: it feeds the reply-model picker in chat. It must work everywhere the picker works, including a future native build where an embedded pane would not render.
2. **The dex UI already half-exists in Flutter.** `ManageModelsScreen` already lists every discovered model with enable toggles, search, and a free-only filter. The dashboard's own dex (`static/models.html:106` `mode = 'manage' | 'cards'`, `renderCards()` at `:154-176` with Sovereign / Free remote / Paid cloud tiers) is a second view over the **same rows**.
3. **The data plumbing is complete end to end, today.** skgateway `/admin/models` (loopback) carries the rich `card` per model, and `/v1/models` carries the additive public-safe badges (`ctx_tokens`, `tools`, `vision`: `skgateway/src/advertise.mjs:255-261`, guaranteed additive-only). The daemon's `/api/v1/models/manage` returns the gateway's admin rows **unmodified** (`skchat/src/skchat/agent_model.py:340-350`), and the app already calls it (`agent_model_service.dart:232-242`, reached on web via the funnel's `/daemon` prefix, `agent_model_service.dart:307-313`). The only gap is client-side: `ManagedModel.fromJson` (`agent_model_service.dart:135-142`) drops the `card` field on the floor.

**Work:** parse `card` (tier, `context_length`, `tools`, `vision`, tags) into `ManagedModel`; add a `Manage | Cards` segmented view to `ManageModelsScreen` (mirroring `models.html`'s toggle); link a card detail from the reply-model picker. Roughly 1-2 days, no server change required. The picker's non-admin catalog additionally gets the `/v1/models` badges for free as the gateway ships them.

The dashboard's `models.html` dex stays as the ops twin (same allowlist, cannot diverge on data) and can be retired later or kept indefinitely at zero cost.

---

## 4. Phasing and the concrete fix

### Phase 1: fix the busted embed (about half a day + verification)

1. **Tokenize asset URLs in the proxy** (`skchat/src/skchat/webui.py`): extend `_rewrite_html_asset_prefix` (`:360-396`) to also append `?embed_token=...` to every rewritten root-absolute `href`/`src` when a token is in hand (the same idempotence guards the fetch shim uses at `:436-437`), so `<link>`/`<script>` loads authorize exactly like the initial navigation, no cookie dependence. Add a unit test beside the existing rewrite tests. (Alternative considered: exempt `GET /skdashboard/static/*` from the gate since assets are code not data; simpler, but it reopens a sliver of the leak and the token approach matches the existing skcode model.)
2. **Give `/skos` the same treatment**: pass `html_prefix="/skos"` and the embed token into its `_reverse_proxy` call (`webui.py:848-860`).
3. **Flip the client build flags in the canonical deploy path**: add `--dart-define=USE_SHELL_DYNAMIC_MODULES=true --dart-define=USE_SHELL_REQUIRE_SIGNED=true` to `skchat/scripts/deploy-app-web.sh:83-85`. The server enforcement flag is already on, and `external_modules.dart:41-47` says to flip the client flag in the same rebuild, which this is (server has been enforcing since before this deploy).
4. **Verify**: Board and OS tabs appear in the deployed app; the skdashboard pane renders styled; devtools shows asset requests 200 with `embed_token`; an in-pane Models Save (rw token) succeeds; confirm or refute the cookie assumption from section 1.3 while there.

### Phase 2: model dex native (1-2 days)
As section 3. Ship in the app; leave `models.html` untouched.

### Phase 3: converge by promotion, not migration
Keep ITIL Cockpit / CMDB / Kanban / Assistant / Trust embedded. Promote a view to native only on demonstrated daily/mobile use (Kanban is the likeliest candidate; it would reuse the existing `/api/board` + card-action endpoints, `skdashboard/static/js/api.js:19`). Document the policy: skdashboard binds loopback only, `SKDASHBOARD_URL` for the proxy, no new standalone links.

## 5. Risks and open questions

1. **The cookie/opaque-origin diagnosis needs one empirical confirmation** (devtools, 5 min). If some browser does attach the cookie, the primary root cause is still the missing build flag, and the asset-token fix is still the right cross-browser hardening.
2. **Tokens in asset URLs** land in server logs and browser caches. Acceptable: short-lived, module-scoped, mostly read-only, same model skcode already uses; consider `Cache-Control: private` on tokenized proxied responses.
3. **Grade B panes are web-only.** The moment a native (mobile/desktop) build ships, every embedded view goes dark under the no-webview rule. Decision to hold now: anything that must exist on native must be Grade A native, which is exactly why the dex goes native first.
4. **The urllib-based reverse proxy is HTTP-only** (`webui.py:498-541`): no WebSocket/SSE for skdashboard (only skcode has a WS proxy, `webui.py:713`). If the Assistant tab ever grows streaming, it needs the skcode-style WS proxy or promotion to native.
5. **Discovery flag flips for everyone at once.** `USE_SHELL_DYNAMIC_MODULES` is compile-time; a bad aggregate response degrades to the static registry by design (`external_modules.dart:20-24`), but the new tabs appearing fleet-wide is a UX change Chef should sign off on (module placement can be tuned per-user via the existing Modules settings).
