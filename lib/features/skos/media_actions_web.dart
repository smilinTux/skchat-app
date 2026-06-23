import 'dart:html' as html;

/// Web side of the media-actions seam.
///
/// Triggers a real browser download of [url] by synthesising an off-DOM
/// `<a download>` anchor and clicking it. The `download` attribute hints the
/// suggested filename; for a same-origin URL (our `/media/file` stream is
/// served from the app origin) the browser honours it and saves rather than
/// navigates. We open in a new tab as a fallback target so a navigation (if the
/// browser ignores `download` for the streamed content-type) does not blow away
/// the gallery.
void triggerBrowserDownload(String url, String filename) {
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..target = '_blank'
    ..rel = 'noopener';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}
