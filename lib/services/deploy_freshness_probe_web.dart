/// Web half of the deploy-freshness seam (see `deploy_freshness_probe.dart`).
///
/// What "the server is serving right now" is fetched from, and why:
///
/// The compiled-in `BUILD_ID` (git short-sha + build timestamp, see
/// `core/build_info.dart`) is NOT reproduced anywhere in the server's
/// response. `version.json` (auto-emitted by `flutter build web`) only
/// carries `app_name`/`version`/`build_number`/`package_name` derived from
/// `pubspec.yaml`; the deploy script (`skchat`'s `scripts/deploy-app-web.sh`)
/// passes `BUILD_ID` as a `--dart-define`, which only Dart code compiled
/// into `main.dart.js` can read, never `--build-name`/`--build-number`, so
/// it never reaches `version.json`'s own content. Adding it there would mean
/// changing that script, which is out of bounds here (it lives in the
/// skchat repo).
///
/// So instead of comparing content, this reads `version.json`'s `ETag`
/// response header (falling back to `Last-Modified`). `version.json` is one
/// of the `volatile` files skchat's `/app/{rest}` route always serves
/// `Cache-Control: no-cache, must-revalidate` (`conf/routes.py`), so this
/// fetch always reaches the server, never a cached response. Starlette's
/// `FileResponse` derives BOTH headers from the file's stat every request,
/// and the deploy rsyncs a completely fresh `build/web/` on every deploy
/// (`rsync -a --delete`, which preserves the SOURCE mtimes), so the ETag
/// changes on every real deploy even when `version.json`'s BODY is
/// byte-identical to the last one (i.e. no `pubspec.yaml` version bump
/// happened between deploys, the common case). It does NOT need to match
/// [kBuildId] byte-for-byte; `DeployFreshnessTracker` only ever compares two
/// values fetched this same way against each other (see its doc comment for
/// why that is the only sound comparison anyway).
library;

import "dart:html" as html;

Future<String?> fetchServedBuildMarker() async {
  try {
    final req = await html.HttpRequest.request(
      "version.json",
      method: "GET",
      requestHeaders: const {"Cache-Control": "no-cache"},
    );
    final headers = req.responseHeaders;
    final etag = headers["etag"];
    if (etag != null && etag.isNotEmpty) return etag;
    final lastModified = headers["last-modified"];
    if (lastModified != null && lastModified.isNotEmpty) return lastModified;
    return null;
  } catch (_) {
    // Network hiccup, a proxy that strips validators, anything: fail
    // silent. A failed version check must never surface an error or block
    // the app, which keeps running on whatever build it already has.
    return null;
  }
}

void reloadPage() => html.window.location.reload();
