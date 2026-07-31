// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// Web embed: registers a platform view backed by an iframe pointing at the
/// same-origin `/skcode` client (proxied to skcode-hostd over the 443 funnel),
/// and renders it through [HtmlElementView]. One factory registration per URL
/// (the registry is process-global and rejects duplicate view types).
final Set<String> _registered = <String>{};

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
        ..allow = 'clipboard-read; clipboard-write';
    });
  }
  return HtmlElementView(viewType: viewType);
}
