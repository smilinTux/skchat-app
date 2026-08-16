import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../../core/router/app_router.dart";
import "../../core/theme/theme.dart";
import "../../services/spaces_identity_service.dart";
import "../../services/spaces_service.dart";
import "space_models.dart";

/// The identity value a Space's `host_fqid` is compared against: this
/// device's stable, unique-per-device Spaces id ([SpacesIdentity.id]).
///
/// This is DELIBERATELY not the shared node/capauth identity
/// (`localIdentityProvider` in profile_screen.dart): that identity is fetched
/// from the local SKComms daemon, which is one sovereign node shared by every
/// browser hitting the same /app/ deployment, so two different people used to
/// resolve to the SAME LiveKit identity and LiveKit would evict the
/// duplicate, kicking the host the moment someone else joined.
/// [spacesIdentityProvider] instead generates + persists a per-device id, so
/// two different devices always differ and the SAME device is always stable
/// across reloads. Mirrors exactly how `_CreateSpaceSheetState._submit`
/// derives `hostFqid` when creating a Space, so a returning host resolves to
/// the same value that was stored at creation time.
String localHostIdentityValue(SpacesIdentity identity) => identity.id;

/// Whether the local user is the host of [space], per [identity]. True only
/// when the Space has a non-empty `hostFqid` that matches this device's host
/// identity value; an empty `hostFqid` (unknown host) is never a match.
bool isHostOfSpace(SpaceSummary space, SpacesIdentity identity) =>
    space.hostFqid.isNotEmpty &&
    space.hostFqid == localHostIdentityValue(identity);

/// Joins [space] as its host when the local user IS that Space's host
/// (per [isHostOfSpace]), otherwise as a listener.
///
/// The host branch still asks the server for a host-role token via
/// `joinHost`, which independently re-verifies the requester against
/// `host_fqid` server-side (this client-side check is only what decides
/// which endpoint to call, it does not weaken that server check). If the
/// server ever rejects the host join anyway (stale directory data, etc.)
/// this falls back to a normal listener join so the user still gets into
/// the Space instead of seeing an error.
///
/// The listener join uses [identity]'s device id directly as the LiveKit
/// participant identity, with no per-device suffix: the id is already
/// globally unique per device (see [SpacesIdentity]), so a suffix would
/// only add the risk of the host's own participant identity no longer
/// matching the `host_fqid` it minted at create time.
///
/// Top-level (it used to be private to [SpacesDirectoryScreen]) because a
/// shared-link deep link has to mint the very same role-scoped join, from a
/// route with no directory screen anywhere in its tree. See
/// `space_deep_link_screen.dart`.
Future<SpaceJoin> joinSpaceAsAppropriateRole(
  SpacesService svc, {
  required SpaceSummary space,
  required SpacesIdentity identity,
}) async {
  if (isHostOfSpace(space, identity)) {
    try {
      return await svc.joinHost(
        space.spaceId,
        requester: localHostIdentityValue(identity),
      );
    } on Object catch (e) {
      debugPrint(
        "joinHost rejected for ${space.spaceId} ($e); falling back to listener join",
      );
    }
  }
  return svc.joinListener(
    space.spaceId,
    identity: identity.id,
    name: identity.displayName,
  );
}

/// Polls the sovereign /spaces API for live Spaces every 5s.
///
/// Emits the current list of [SpaceSummary]; surfaces errors as an
/// [AsyncError] so the screen can show a daemon-offline state.
final spacesDirectoryProvider =
    StreamProvider.autoDispose<List<SpaceSummary>>((ref) async* {
  final svc = ref.watch(spacesServiceProvider);
  // Emit immediately, then poll on a 5s cadence until disposed.
  while (true) {
    yield await svc.listLive();
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// Live-now directory of SK Spaces, sovereign audio rooms.
///
/// Renders each live Space (title, host, LIVE/REC badges, speaker count) with a
/// Join button that connects as a listener, plus a + FAB to create + host a new
/// Space.
class SpacesDirectoryScreen extends ConsumerWidget {
  const SpacesDirectoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final spacesAsync = ref.watch(spacesDirectoryProvider);

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: Text("Spaces", style: tt.displayLarge?.copyWith(fontSize: 24)),
        actions: [
          // PRIMARY create affordance. The extended FAB below can be obscured by
          // the app-shell bottom nav bar on some viewports (that is why "start a
          // space" was hard to find), so the always-visible entry lives here in
          // the AppBar where the bottom nav can never cover it.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: () => _showCreateSheet(context, ref),
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text("New Space"),
              style: TextButton.styleFrom(
                foregroundColor: SovereignColors.soulLumina,
              ),
            ),
          ),
        ],
      ),
      body: spacesAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(
            color: SovereignColors.soulLumina,
            strokeWidth: 2,
          ),
        ),
        error: (e, _) => _buildError(context, tt, e),
        data: (spaces) => spaces.isEmpty
            ? _buildEmpty(context, tt, () => _showCreateSheet(context, ref))
            : _buildList(context, ref, spaces),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateSheet(context, ref),
        backgroundColor: SovereignColors.soulLumina,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_rounded),
        label: const Text("New Space"),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<SpaceSummary> spaces,
  ) {
    return RefreshIndicator(
      color: SovereignColors.soulLumina,
      backgroundColor: SovereignColors.surfaceRaised,
      onRefresh: () => ref.refresh(spacesDirectoryProvider.future),
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 100),
        itemCount: spaces.length,
        itemBuilder: (context, i) => _SpaceCard(
          space: spaces[i],
          onJoin: () => _join(context, ref, spaces[i]),
        ),
      ),
    );
  }

  Future<void> _join(
    BuildContext context,
    WidgetRef ref,
    SpaceSummary space,
  ) async {
    final svc = ref.read(spacesServiceProvider);
    // Await (not read) the Spaces identity: on first launch it is still
    // generating + persisting the device id/alias, and we need the FINAL
    // persisted value, not a transient loading placeholder, before deciding
    // whether this device is the Space's host and what identity to join as.
    final identity = await ref.read(spacesIdentityProvider.future);
    try {
      final join = await joinSpaceAsAppropriateRole(
        svc,
        space: space,
        identity: identity,
      );
      if (!context.mounted) return;
      context.push(AppRoutes.spaceRoomPath(space.spaceId), extra: join);
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't join: $e"),
          backgroundColor: SovereignColors.surfaceRaised,
        ),
      );
    }
  }

  Future<void> _showCreateSheet(BuildContext context, WidgetRef ref) async {
    final join = await showModalBottomSheet<SpaceJoin>(
      context: context,
      isScrollControlled: true,
      // Present on the ROOT navigator so the sheet overlays the ENTIRE app,
      // including the app-shell GlassNavBar. Without this the persistent bottom
      // nav paints on top of the sheet and hides the "Go live" button below the
      // Slug field (the exact bug Chef hit).
      useRootNavigator: true,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _CreateSpaceSheet(),
    );
    if (join == null || !context.mounted) return;
    context.push(AppRoutes.spaceRoomPath(join.spaceId), extra: join);
  }

  Widget _buildEmpty(BuildContext context, TextTheme tt, VoidCallback onCreate) {
    return ListView(
      // ListView so pull-to-refresh works even when empty.
      children: [
        const SizedBox(height: 120),
        Icon(
          Icons.podcasts_rounded,
          size: 48,
          color: SovereignColors.textTertiary,
        ),
        const SizedBox(height: 20),
        Center(child: Text("No live Spaces", style: tt.titleLarge)),
        const SizedBox(height: 8),
        Center(
          child: Text(
            "Nobody's live yet. Start one:",
            style: tt.bodyMedium?.copyWith(
              color: SovereignColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          // Explicit tappable button so starting a Space never depends on the
          // FAB (which the bottom nav can hide).
          child: FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add_rounded),
            label: const Text("Start a Space"),
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.soulLumina,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context, TextTheme tt, Object e) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: SovereignColors.textTertiary,
              size: 44,
            ),
            const SizedBox(height: 16),
            Text("Spaces unavailable", style: tt.titleMedium),
            const SizedBox(height: 8),
            Text(
              "$e",
              textAlign: TextAlign.center,
              style: tt.bodySmall?.copyWith(
                color: SovereignColors.textSecondary,
                fontFamily: "JetBrainsMono",
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single live-Space card: title, host, LIVE/REC badges, speaker count, Join.
class _SpaceCard extends StatelessWidget {
  const _SpaceCard({required this.space, required this.onJoin});

  final SpaceSummary space;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final soul = SovereignColors.fromFingerprint(space.hostFqid);

    return GlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      borderRadius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _LiveBadge(),
              if (space.recording) ...[
                const SizedBox(width: 8),
                const _RecBadge(),
              ],
              const Spacer(),
              Icon(
                Icons.graphic_eq_rounded,
                size: 14,
                color: SovereignColors.textTertiary,
              ),
              const SizedBox(width: 4),
              Text(
                "${space.speakers.length} "
                "speaker${space.speakers.length == 1 ? "" : "s"}",
                style: tt.labelSmall?.copyWith(
                  color: SovereignColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            space.title.isNotEmpty ? space.title : "Untitled Space",
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: soul),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  space.hostFqid.isNotEmpty ? space.hostFqid : "unknown host",
                  style: tt.bodySmall?.copyWith(
                    color: SovereignColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onJoin,
              icon: const Icon(Icons.headphones_rounded, size: 18),
              label: const Text("Join"),
              style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.soulLumina,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: SovereignColors.accentEncrypt.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: SovereignColors.accentEncrypt,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            "LIVE",
            style: TextStyle(
              color: SovereignColors.accentEncrypt,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              fontFamily: "JetBrainsMono",
            ),
          ),
        ],
      ),
    );
  }
}

class _RecBadge extends StatelessWidget {
  const _RecBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: SovereignColors.accentDanger.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: SovereignColors.accentDanger,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            "REC",
            style: TextStyle(
              color: SovereignColors.accentDanger,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              fontFamily: "JetBrainsMono",
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet: create a Space (title + slug) then open the room as host.
class _CreateSpaceSheet extends ConsumerStatefulWidget {
  const _CreateSpaceSheet();

  @override
  ConsumerState<_CreateSpaceSheet> createState() => _CreateSpaceSheetState();
}

class _CreateSpaceSheetState extends ConsumerState<_CreateSpaceSheet> {
  final _titleCtl = TextEditingController();
  final _slugCtl = TextEditingController();
  bool _submitting = false;
  bool _slugEdited = false;

  @override
  void dispose() {
    _titleCtl.dispose();
    _slugCtl.dispose();
    super.dispose();
  }

  String _slugify(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9]+"), "-")
      .replaceAll(RegExp(r"^-+|-+$"), "");

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final mq = MediaQuery.of(context);
    // viewInsets.bottom = keyboard height; viewPadding.bottom = home-indicator
    // safe area. Pad by both so the "Go live" button is always reachable, above
    // the keyboard when typing and above the home indicator when it is dismissed.
    final bottomInset = mq.viewInsets.bottom;
    final safeBottom = mq.viewPadding.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 24 + bottomInset + safeBottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: SovereignColors.textTertiary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            "New Space",
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            "Start a live audio room. You'll join as host.",
            style: tt.bodySmall?.copyWith(
              color: SovereignColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _titleCtl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            style: tt.titleSmall,
            decoration: const InputDecoration(
              labelText: "Title",
              hintText: "SKWorld Town Hall",
            ),
            onChanged: (v) {
              if (!_slugEdited) {
                _slugCtl.text = _slugify(v);
              }
              setState(() {});
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _slugCtl,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r"[a-z0-9-]")),
            ],
            style: tt.titleSmall?.copyWith(fontFamily: "JetBrainsMono"),
            decoration: const InputDecoration(
              labelText: "Slug",
              hintText: "town-hall",
              prefixText: "/",
            ),
            onChanged: (_) => _slugEdited = true,
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _submitting || _titleCtl.text.trim().isEmpty
                  ? null
                  : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.podcasts_rounded, size: 18),
              label: Text(_submitting ? "Creating..." : "Go live"),
              style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.soulLumina,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final title = _titleCtl.text.trim();
    if (title.isEmpty) return;
    final slug = _slugCtl.text.trim().isNotEmpty
        ? _slugCtl.text.trim()
        : _slugify(title);

    setState(() => _submitting = true);
    final svc = ref.read(spacesServiceProvider);
    // Await the FINAL persisted Spaces identity (not a transient loading
    // placeholder): this device's id becomes `host_fqid`, so the host's own
    // future LiveKit participant identity (which is also this same id, see
    // [localHostIdentityValue]) is guaranteed to match it exactly.
    final identity = await ref.read(spacesIdentityProvider.future);
    final hostFqid = localHostIdentityValue(identity);

    try {
      final join = await svc.create(
        hostFqid: hostFqid,
        title: title,
        slug: slug,
      );
      if (!mounted) return;
      Navigator.of(context).pop(join);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Create failed: $e"),
          backgroundColor: SovereignColors.surfaceRaised,
        ),
      );
    }
  }
}
