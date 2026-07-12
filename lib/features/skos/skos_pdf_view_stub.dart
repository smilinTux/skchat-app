import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Native (mobile / desktop) PDF surface, the non-web side of the conditional
/// import seam in `skos_files_screen.dart`
/// (`skos_pdf_view_stub.dart if (dart.library.html) skos_pdf_view_web.dart`).
///
/// We deliberately avoid a native PDF dependency. On non-web targets the
/// streaming URL is opened in the platform's default handler (browser / system
/// viewer) via `url_launcher`.
class SkosPdfView extends StatelessWidget {
  const SkosPdfView({super.key, required this.url, this.label});

  /// The same-origin streaming URL (`/media/file?...`).
  final String url;

  /// Optional display name shown on the card.
  final String? label;

  Future<void> _open() async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.picture_as_pdf_rounded, size: 48),
          const SizedBox(height: 12),
          if (label != null) ...[
            Text(label!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: _open,
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open PDF'),
          ),
        ],
      ),
    );
  }
}
