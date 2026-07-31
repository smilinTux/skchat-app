import 'package:flutter/material.dart';

/// Non-web fallback: native builds cannot host an inline browser frame, so the
/// Code pane shows the host URL instead of embedding it. The web build swaps
/// this for the real iframe embed via a conditional import.
Widget skcodeEmbed(String url) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal_rounded, size: 40),
            const SizedBox(height: 12),
            const Text('Open the Code host in a browser:',
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            SelectableText(url, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
