import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/theme.dart";
import "../../services/consent_service.dart";

/// Contact Requests — the operator review surface for first-contact knocks
/// (skfed-consent-design gate 5). Lists the node's quarantined first-contact
/// requests and lets the operator **Accept** (promote to known + mint a
/// per-contact delivery token), **Decline** (clear the knock, sender returns to
/// UNKNOWN), or **Block** (drop the knock + block the sender outright).
///
/// Signal Message-Request semantics: quiet by default — nothing is delivered
/// until the operator accepts. The list is empty until consent mode is enabled
/// on the daemon (`SKCOMMS_CONSENT_MODE`), so this screen ships dark/safe.
class RequestsScreen extends ConsumerWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final requestsAsync = ref.watch(consentRequestsProvider);

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: Text(
          "Contact Requests",
          style: tt.displayLarge?.copyWith(fontSize: 24),
        ),
      ),
      body: requestsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(
            color: SovereignColors.soulLumina,
            strokeWidth: 2,
          ),
        ),
        error: (e, _) => _buildError(context, ref, tt, e),
        data: (reqs) => reqs.isEmpty
            ? _buildEmpty(context, ref, tt)
            : _buildList(context, ref, reqs),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<ContactRequest> requests,
  ) {
    return RefreshIndicator(
      color: SovereignColors.soulLumina,
      backgroundColor: SovereignColors.surfaceRaised,
      onRefresh: () => ref.refresh(consentRequestsProvider.future),
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 100),
        itemCount: requests.length,
        itemBuilder: (context, i) => _RequestCard(
          request: requests[i],
          onAccept: () => _accept(context, ref, requests[i]),
          onDecline: () => _decline(context, ref, requests[i]),
          onBlock: () => _block(context, ref, requests[i]),
        ),
      ),
    );
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _accept(
    BuildContext context,
    WidgetRef ref,
    ContactRequest req,
  ) async {
    await _run(
      context,
      ref,
      () async {
        await ref.read(consentServiceProvider).accept(req.sender);
      },
      "Accepted ${req.sender}",
    );
  }

  Future<void> _decline(
    BuildContext context,
    WidgetRef ref,
    ContactRequest req,
  ) async {
    await _run(
      context,
      ref,
      () => ref.read(consentServiceProvider).decline(req.sender),
      "Declined ${req.sender}",
    );
  }

  Future<void> _block(
    BuildContext context,
    WidgetRef ref,
    ContactRequest req,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text("Block sender?"),
        content: Text(
          "${req.sender} will be blocked; their future traffic is dropped. "
          "You can unblock later.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentDanger,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Block"),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref.read(consentServiceProvider).block(req.sender),
      "Blocked ${req.sender}",
    );
  }

  /// Run a consent mutation, refresh the queue, and surface success / failure
  /// as a SnackBar. Keeps the three actions DRY.
  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
    String okMessage,
  ) async {
    try {
      await action();
      ref.invalidate(consentRequestsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(okMessage)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed: $e")),
        );
      }
    }
  }

  // ── States ──────────────────────────────────────────────────────────────────

  Widget _buildEmpty(BuildContext context, WidgetRef ref, TextTheme tt) {
    return RefreshIndicator(
      color: SovereignColors.soulLumina,
      backgroundColor: SovereignColors.surfaceRaised,
      onRefresh: () => ref.refresh(consentRequestsProvider.future),
      child: ListView(
        children: [
          const SizedBox(height: 120),
          const Icon(
            Icons.mark_email_read_outlined,
            color: SovereignColors.textTertiary,
            size: 56,
          ),
          const SizedBox(height: 16),
          Text(
            "No pending requests",
            textAlign: TextAlign.center,
            style: tt.titleMedium?.copyWith(
              color: SovereignColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "First-contact knocks from unknown senders appear here.",
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
              "Couldn't load requests",
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
              onPressed: () => ref.invalidate(consentRequestsProvider),
              child: const Text("Retry"),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.onAccept,
    required this.onDecline,
    required this.onBlock,
  });

  final ContactRequest request;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: SovereignColors.surfaceCard,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.person_add_alt_1_outlined,
                  color: SovereignColors.soulLumina,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        request.sender,
                        style: tt.titleSmall?.copyWith(
                          color: SovereignColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (request.receivedAt.isNotEmpty)
                        Text(
                          request.receivedAt,
                          style: tt.bodySmall?.copyWith(
                            color: SovereignColors.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onBlock,
                  icon: const Icon(Icons.block, size: 18),
                  label: const Text("Block"),
                  style: TextButton.styleFrom(
                    foregroundColor: SovereignColors.accentDanger,
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: onDecline,
                  style: TextButton.styleFrom(
                    foregroundColor: SovereignColors.textSecondary,
                  ),
                  child: const Text("Decline"),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text("Accept"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
