import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// Web PDF surface, the web side of the conditional import seam in
/// `skos_files_screen.dart`.
///
/// Browsers render PDFs natively, so the same-origin streaming URL
/// (`/media/file?...`) is embedded in an `<iframe>` via an [HtmlElementView].
/// No native PDF dependency is required. A top-bar "Open in new tab" affordance
/// is provided as a fallback for browsers configured to download rather than
/// render PDFs inline.
class SkosPdfView extends StatefulWidget {
  const SkosPdfView({super.key, required this.url, this.label});

  /// The same-origin streaming URL (`/media/file?...`).
  final String url;

  /// Optional display name (unused on web, the iframe shows the document).
  final String? label;

  @override
  State<SkosPdfView> createState() => _SkosPdfViewState();
}

class _SkosPdfViewState extends State<SkosPdfView> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'skos-pdf-${identityHashCode(widget)}-${widget.url.hashCode}';

    final iframe = html.IFrameElement()
      ..src = widget.url
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..setAttribute('title', widget.label ?? 'PDF');

    ui_web.platformViewRegistry
        .registerViewFactory(_viewType, (int _) => iframe);
  }

  void _openInNewTab() {
    html.window.open(widget.url, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: HtmlElementView(viewType: _viewType)),
        Positioned(
          top: 8,
          right: 8,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: IconButton(
              icon: const Icon(Icons.open_in_new_rounded, color: Colors.white),
              tooltip: 'Open in new tab',
              onPressed: _openInNewTab,
            ),
          ),
        ),
      ],
    );
  }
}
