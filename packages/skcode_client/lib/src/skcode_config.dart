/// The audience [SkcodeSessionStore] / [SkcodeSessionsListStore] mint tokens
/// for. Matches the manifest `auth.audience` for the skcode module (spec
/// 4.2/13).
///
/// This constant is pure config, not a service: the package never mints or
/// caches a token itself (that stays a host concern, reached only through
/// the injected `mintToken` / `onAuthRejected` callbacks, module contract
/// standard section 3.1). Callers pass this audience name into whatever
/// token minter they hold (a host `AudienceTokenService`, or the standalone
/// runner's own capauth client).
const kSkcodeAudience = "skcode";

/// The capability scope that gates `POST .../inject` and `POST .../ratify`
/// on skcode-hostd (spec 3.1: "scope skcode.inject (write, PDP-decided):
/// POST .../ratify, POST .../inject"). Card C-5's inject composer and
/// needs_input Approve/Deny banner both render only when the mounted
/// module's [AuthContext] (`skworld_module_api`) carries this scope; see
/// `SkcodeSessionScreen`.
const kSkcodeInjectScope = "skcode.inject";

/// The capability scope that gates `GET .../dispatch/targets`,
/// `POST .../dispatch`, and `POST .../sessions/{sid}/cancel` on
/// skcode-hostd (spec 3.1: "scope skcode.dispatch (PDP-decided): GET
/// /api/v1/dispatch/targets, POST /api/v1/dispatch"; spec section 8: cancel
/// "rides the dispatch scope through the same PDP decision path"). Card
/// C-6's New Session entry point (`SkcodeSessionsRail`) and the cancel
/// affordance (`SkcodeSessionScreen`) both render only when the mounted
/// module's [AuthContext] (`skworld_module_api`) carries this scope, the
/// same fail-closed pattern [kSkcodeInjectScope] already established for
/// card C-5.
const kSkcodeDispatchScope = "skcode.dispatch";

/// `wss://<origin>/skcode/api/v1/sessions/<sid>/stream?token=<wire>`
/// (matches `skchat/src/skchat/webui.py::_skcode_ws_url`'s browser-facing
/// contract exactly). The token stays in the query string HERE and ONLY
/// here, see `skcode_api_client.dart`'s doc comment for why HTTP never
/// carries it this way.
///
/// [baseUrl] is normally already ws(s):// (production passes the host's
/// WS-mapped daemon URL, which has already done the http(s) -> ws(s)
/// mapping), but an http(s):// base is converted here too so this function
/// is correct on its own regardless of which base a caller (or a test)
/// happens to hand it.
Uri skcodeWsUri(String baseUrl, String sid, String token) {
  var base = baseUrl.trim();
  while (base.endsWith("/")) {
    base = base.substring(0, base.length - 1);
  }
  if (base.startsWith("https://")) {
    base = "wss://${base.substring("https://".length)}";
  } else if (base.startsWith("http://")) {
    base = "ws://${base.substring("http://".length)}";
  }
  return Uri.parse(
    "$base/skcode/api/v1/sessions/$sid/stream?token=${Uri.encodeQueryComponent(token)}",
  );
}
