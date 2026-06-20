import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:url_launcher/url_launcher.dart";

import "../../core/theme/theme.dart";
import "../../services/recordings_service.dart";

/// Loads the list of recordings from GET /recordings via [RecordingsService].
///
/// Surfaces errors as an [AsyncError] so the screen can show an offline state;
/// pull-to-refresh re-invokes the provider.
final recordingsListProvider =
    FutureProvider.autoDispose<List<Recording>>((ref) async {
  final svc = ref.watch(recordingsServiceProvider);
  return svc.list();
});

/// Recordings browser — lists call/space recordings served by the SKChat
/// web-UI and offers a playback/download link (GET /recordings/{name}) for each.
class RecordingsScreen extends ConsumerWidget {
  const RecordingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final recordingsAsync = ref.watch(recordingsListProvider);

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title:
            Text("Recordings", style: tt.displayLarge?.copyWith(fontSize: 24)),
      ),
      body: recordingsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(
            color: SovereignColors.soulLumina,
            strokeWidth: 2,
          ),
        ),
        error: (e, _) => _buildError(context, ref, tt, e),
        data: (recs) => recs.isEmpty
            ? _buildEmpty(context, ref, tt)
            : _buildList(context, ref, recs),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<Recording> recordings,
  ) {
    return RefreshIndicator(
      color: SovereignColors.soulLumina,
      backgroundColor: SovereignColors.surfaceRaised,
      onRefresh: () => ref.refresh(recordingsListProvider.future),
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 100),
        itemCount: recordings.length,
        itemBuilder: (context, i) => _RecordingCard(
          recording: recordings[i],
          onOpen: () => _open(context, ref, recordings[i]),
        ),
      ),
    );
  }

  /// Open the recording in the platform browser / media player via its
  /// GET /recordings/{name} URL. Falls back to copying the URL on failure.
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Recording rec,
  ) async {
    final url = ref.read(recordingsServiceProvider).fetchUrl(rec.name);
    final uri = Uri.parse(url);
    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!launched) {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Link copied to clipboard")),
        );
      }
    }
  }

  Widget _buildEmpty(BuildContext context, WidgetRef ref, TextTheme tt) {
    return RefreshIndicator(
      color: SovereignColors.soulLumina,
      backgroundColor: SovereignColors.surfaceRaised,
      onRefresh: () => ref.refresh(recordingsListProvider.future),
      child: ListView(
        children: [
          const SizedBox(height: 120),
          Icon(
            Icons.fiber_smart_record_outlined,
            color: SovereignColors.textTertiary,
            size: 56,
          ),
          const SizedBox(height: 16),
          Text(
            "No recordings yet",
            textAlign: TextAlign.center,
            style: tt.titleMedium?.copyWith(
              color: SovereignColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Start recording from inside a call.",
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(
              color: SovereignColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(
    BuildContext context,
    WidgetRef ref,
    TextTheme tt,
    Object error,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: SovereignColors.accentDanger,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              "Couldn't load recordings",
              style: tt.titleMedium
                  ?.copyWith(color: SovereignColors.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              "$error",
              textAlign: TextAlign.center,
              style: tt.bodySmall?.copyWith(
                color: SovereignColors.textSecondary,
                fontFamily: "JetBrainsMono",
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => ref.refresh(recordingsListProvider),
              child: const Text("Retry"),
            ),
          ],
        ),
      ),
    );
  }
}

/// Human-readable byte size (e.g. "12.4 MB").
String _formatSize(int? bytes) {
  if (bytes == null || bytes <= 0) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  var size = bytes.toDouble();
  var u = 0;
  while (size >= 1024 && u < units.length - 1) {
    size /= 1024;
    u++;
  }
  final s = u == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return "$s ${units[u]}";
}

class _RecordingCard extends StatelessWidget {
  const _RecordingCard({required this.recording, required this.onOpen});

  final Recording recording;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final meta = <String>[
      if (recording.room != null && recording.room!.isNotEmpty) recording.room!,
      if (recording.sizeBytes != null) _formatSize(recording.sizeBytes),
      if (recording.modified != null && recording.modified!.isNotEmpty)
        recording.modified!,
    ].where((s) => s.isNotEmpty).join(" · ");

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: SovereignColors.surfaceCard,
      child: ListTile(
        leading: const Icon(
          Icons.movie_creation_outlined,
          color: SovereignColors.soulLumina,
        ),
        title: Text(
          recording.name,
          style: tt.titleSmall?.copyWith(color: SovereignColors.textPrimary),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: meta.isEmpty
            ? null
            : Text(
                meta,
                style: tt.bodySmall
                    ?.copyWith(color: SovereignColors.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
        trailing: IconButton(
          icon: const Icon(
            Icons.play_circle_outline_rounded,
            color: SovereignColors.soulLumina,
          ),
          tooltip: "Play / download",
          onPressed: onOpen,
        ),
        onTap: onOpen,
      ),
    );
  }
}
