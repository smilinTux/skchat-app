/// Entry point for a SHARED SK Space link.
///
/// In-app navigation into a Space (`SpacesDirectoryScreen._join`) hands the
/// `/spaces/:id` route a fully built [SpaceJoin] via `extra`: a role-scoped
/// LiveKit token minted a moment earlier. A shared link cannot do that.
/// `spaceJoinUrl` (space_share.dart) produces `{base}/app/#/spaces/{id}`, and
/// a URL carries only the id, never in-process router state. So the route
/// used to hard-cast a null `extra` and throw, and the guest got a blank grey
/// screen. This screen closes that gap by minting the join itself, which is
/// async and therefore needs real loading and failure states.
///
/// The same applies to the HOST: a browser reload of `/app/#/spaces/{id}`
/// drops `extra` exactly the way a guest's first visit does, so the role has
/// to be re-derived from the live directory rather than assumed.
library;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../../core/router/app_router.dart";
import "../../core/theme/theme.dart";
import "../../services/spaces_identity_service.dart";
import "../../services/spaces_service.dart";
import "space_models.dart";
import "space_room_screen.dart";
import "spaces_directory_screen.dart";

/// Mints the role-scoped [SpaceJoin] for a deep link that knows only
/// [spaceId].
///
/// Looks the Space up in the live directory first, purely to learn its
/// `host_fqid` so [joinSpaceAsAppropriateRole] can pick the host endpoint for
/// a returning host. The directory is an optimisation, not a gate: if the
/// listing fails or does not contain the Space (stale 5s poll, filtered
/// listing), this still attempts a listener join, because the server is the
/// authority on whether the Space exists and who may join it. A Space that
/// really has ended fails at `/spaces/{id}/join` with a readable error, which
/// is the honest outcome, rather than being pre-judged by a directory read.
Future<SpaceJoin> mintDeepLinkJoin(
  SpacesService svc, {
  required String spaceId,
  required SpacesIdentity identity,
}) async {
  final summary = await _lookUpSpace(svc, spaceId);
  if (summary != null) {
    return joinSpaceAsAppropriateRole(
      svc,
      space: summary,
      identity: identity,
    );
  }
  return svc.joinListener(
    spaceId,
    identity: identity.id,
    name: identity.displayName,
  );
}

Future<SpaceSummary?> _lookUpSpace(SpacesService svc, String spaceId) async {
  try {
    for (final s in await svc.listLive()) {
      if (s.spaceId == spaceId) return s;
    }
  } on Object catch (e) {
    debugPrint("Spaces directory lookup failed for $spaceId ($e); "
        "joining as a listener");
  }
  return null;
}

/// Resolves a shared Space link into a live room: mint, then render
/// [SpaceRoomScreen]. Shows a spinner while the join is in flight and a
/// readable, retryable error if it fails. It never renders nothing.
class SpaceDeepLinkScreen extends ConsumerStatefulWidget {
  const SpaceDeepLinkScreen({super.key, required this.spaceId});

  final String spaceId;

  @override
  ConsumerState<SpaceDeepLinkScreen> createState() =>
      _SpaceDeepLinkScreenState();
}

class _SpaceDeepLinkScreenState extends ConsumerState<SpaceDeepLinkScreen> {
  late Future<SpaceJoin> _join;

  @override
  void initState() {
    super.initState();
    _join = _mint();
  }

  Future<SpaceJoin> _mint() async {
    // Await (not read) the Spaces identity: on a cold load from a shared link
    // it is still generating + persisting this device's id/alias, and the
    // join needs the FINAL persisted value, not a transient placeholder.
    final identity = await ref.read(spacesIdentityProvider.future);
    return mintDeepLinkJoin(
      ref.read(spacesServiceProvider),
      spaceId: widget.spaceId,
      identity: identity,
    );
  }

  void _retry() => setState(() => _join = _mint());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SpaceJoin>(
      future: _join,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _JoiningSpaceScreen();
        }
        final join = snap.data;
        if (join == null) {
          return _SpaceJoinFailedScreen(
            error: snap.error ?? "unknown error",
            onRetry: _retry,
          );
        }
        return SpaceRoomScreen(join: join);
      },
    );
  }
}

class _JoiningSpaceScreen extends StatelessWidget {
  const _JoiningSpaceScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              "Joining Space...",
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _SpaceJoinFailedScreen extends StatelessWidget {
  const _SpaceJoinFailedScreen({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(title: const Text("Join Space")),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.podcasts_rounded, size: 48),
              const SizedBox(height: 12),
              Text(
                "Couldn't join this Space.",
                textAlign: TextAlign.center,
                style: tt.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                "It may have ended, or the host's server is unreachable.",
                textAlign: TextAlign.center,
                style: tt.bodyMedium
                    ?.copyWith(color: SovereignColors.textSecondary),
              ),
              const SizedBox(height: 8),
              // The raw failure, small and de-emphasised: a guest ignores it,
              // and the host debugging their own link does not have to open a
              // browser console to see whether it was a 404 or the network.
              Text(
                "$error",
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall
                    ?.copyWith(color: SovereignColors.textTertiary),
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text("Try again")),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.go(AppRoutes.spaces),
                child: const Text("Browse live Spaces"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
