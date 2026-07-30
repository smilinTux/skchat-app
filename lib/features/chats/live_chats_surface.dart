import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skchat_ui/skchat_ui.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import '../../services/peer_trust_store.dart';
import 'chats_provider.dart';
import 'group_trust.dart';

/// App-side adapter that bridges the REAL Riverpod [chatsProvider] into the pure
/// [ChatsSurface] living in the `skchat_ui` package (spec 3.2).
///
/// The import gate forbids `skchat_ui` from importing the app's service /
/// Riverpod graph, so the live feed is injected from the app side instead of
/// pulled in from the package. This `ConsumerWidget` is that seam: it
/// `ref.watch`es `chatsProvider` (Hive-backed, hydrated live from the
/// skcomms_client daemon) and hands the resulting `List<Conversation>` to
/// [ChatsSurface].
///
/// Because it is a ConsumerWidget, this is a genuinely LIVE feed: every change
/// to the conversation list (a new message, an unread bump, a delivery-status
/// or typing transition, a fresh daemon load) rebuilds this widget and
/// re-injects the current list into [ChatsSurface]. The package only ever sees
/// a plain immutable list; the reactivity lives here in the watcher.
class LiveChatsSurface extends ConsumerWidget {
  const LiveChatsSurface({super.key, this.shell});

  /// The shell surfaces when this module is mounted, or null in standalone mode.
  /// Passed straight through to [ChatsSurface] for the theme bridge + nav bus.
  final ShellContext? shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(chatsProvider);

    // Resolve the REAL trust standing here, on the app side of the import gate,
    // and inject it into the pure package via `trustResolver`. For a 1:1 row we
    // read the peer's TOFU tier; for a group we fold every member's tier into
    // one aggregate (weakest keyed link wins), mirroring the app's own
    // ConversationTile. `unverifiable` / null (no real key) yields no entry, so
    // the tile shows no badge. Watching the tier families here means any trust
    // change (a fresh sight, a verification) rebuilds this widget and re-injects
    // an updated map, exactly like the live conversation feed.
    final trustByPeer = <String, PeerTrust>{};
    for (final c in conversations) {
      final PeerTrustTier? tier;
      if (c.isGroup != true) {
        tier = ref
            .watch(peerTrustTierProvider(
                (peerId: c.peerId, fingerprint: c.soulFingerprint)))
            .valueOrNull;
      } else {
        // Materialize every member's tier before folding so the fold's
        // short-circuit can never skip a `ref.watch` (Riverpod: never watch
        // conditionally).
        final memberTiers = <PeerTrustTier?>[
          for (final m in c.members)
            ref
                .watch(peerTrustTierProvider(
                    (peerId: m.identityUri, fingerprint: m.soulFingerprint)))
                .valueOrNull,
        ];
        tier = foldGroupTier(memberTiers);
      }
      final level = _levelFor(tier);
      if (level != null) trustByPeer[c.peerId] = PeerTrust(level: level);
    }

    // A populated list renders the real rows; an empty list renders the empty
    // state. We always pass a non-null list (never null), so the sample is only
    // ever seen in standalone/unwired mode, never here.
    return ChatsSurface(
      shell: shell,
      conversations: conversations,
      trustResolver: (c) => trustByPeer[c.peerId],
    );
  }

  /// Map the app's `PeerTrustTier` onto the package-pure [PeerTrustLevel].
  /// Only a real key (red / amber) yields a badge; `unverifiable` and null
  /// (no anchoring key) render nothing.
  static PeerTrustLevel? _levelFor(PeerTrustTier? tier) => switch (tier) {
        PeerTrustTier.red => PeerTrustLevel.red,
        PeerTrustTier.amber => PeerTrustLevel.amber,
        _ => null,
      };
}

/// Builds the mountable skchat module wired to the LIVE conversation feed.
///
/// This is the app-side factory the shell mounts (spec 3.2): it constructs
/// [SkchatModule] with a [bodyBuilder] that returns a [LiveChatsSurface], so the
/// module renders real conversations from `chatsProvider` while the package
/// itself stays pure. Standalone / test callers that use `const SkchatModule()`
/// directly still get the sample-backed surface.
SkchatModule buildLiveSkchatModule() => SkchatModule(
      bodyBuilder: (context, shell) => LiveChatsSurface(shell: shell),
    );
