// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// Web embed: registers a platform view backed by an iframe pointing at the
/// same-origin `/skcode` client (proxied to skcode-hostd over the 443 funnel),
/// and renders it through [HtmlElementView]. One factory registration per URL
/// (the registry is process-global and rejects duplicate view types).
///
/// CONTAINMENT (Fable review A3, 2026-07-31). The iframe is sandboxed and does
/// NOT carry `allow-same-origin`, so the embedded pane runs in an OPAQUE origin:
/// it cannot reach `window.parent`, read the shell's `localStorage` / Hive /
/// cached audience tokens, or act as the operator, even though it is served from
/// the same funnel origin as the shell. `allow-scripts` and `allow-forms` are
/// granted because the Grade B panes (skcode/skdashboard/skos) are interactive
/// web apps that need JS and form submission to function; everything else
/// (top-navigation, popups, pointer-lock, downloads) is denied by omission.
///
/// The clipboard-read/write grant is DROPPED: a sandboxed opaque-origin pane has
/// no business reading the operator's clipboard, and the previous `allow`
/// attribute was the only capability the pane could use to exfiltrate across the
/// boundary.
final Set<String> _registered = <String>{};

/// The iframe `sandbox` token set for an embedded Grade B pane.
///
/// Deliberately WITHOUT `allow-same-origin` (A3): the pane is confined to an
/// opaque origin and cannot touch the shell that frames it. `allow-scripts` +
/// `allow-forms` are the minimum for an interactive web surface to run.
const String kEmbedSandbox = 'allow-scripts allow-forms';

Widget skcodeEmbed(String url) {
  final viewType = 'skcode-iframe::$url';
  if (!_registered.contains(viewType)) {
    _registered.add(viewType);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      return html.IFrameElement()
        ..src = url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        // A3 containment: opaque-origin sandbox, no same-origin, no clipboard.
        ..setAttribute('sandbox', kEmbedSandbox);
    });
  }
  return HtmlElementView(viewType: viewType);
}
