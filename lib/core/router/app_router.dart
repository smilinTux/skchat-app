import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/shell/app_shell.dart';
import '../../features/shell/module_host_screen.dart';
import '../../features/chats/chats_tab.dart';
import '../../features/activity/activity_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/conversation/conversation_screen.dart';
import '../../features/identity/identity_card_screen.dart';
import '../../features/identity/recovery_phrase_screen.dart';
import '../../features/identity/restore_from_phrase_screen.dart';
import '../../features/groups/group_info_screen.dart';
import '../../features/groups/create_group_screen.dart';
import '../../features/chats/peer_picker_screen.dart';
import '../../features/profile/qr_login_screen.dart';
import '../../features/profile/modules_settings_screen.dart';
import '../../features/profile/manage_models_screen.dart';
import '../../features/profile/linked_devices_screen.dart';
import '../../features/calls/livekit_call_screen.dart';
import '../../features/spaces/spaces_directory_screen.dart';
import '../../features/spaces/space_room_screen.dart';
import '../../features/recordings/recordings_screen.dart';
import '../../features/requests/requests_screen.dart';
import '../../features/spaces/space_models.dart';
import '../../features/conf/conf_screen.dart';
import '../../features/facetime/facetime_screen.dart';
import '../../features/coord/coord_board_screen.dart';
import '../../features/cluster/cluster_screen.dart';
import '../../features/hub/hub_screen.dart';
import '../../features/skcode/skcode_pane.dart';
import '../../features/shell/external_module_pane.dart';
import '../../features/skmap/skmap_screen.dart';
import '../../features/skos/skos_files_screen.dart';
import '../../features/skos/skos_control_screen.dart';
import '../../features/join/join_screen.dart';
import '../../features/guest/guest_landing_screen.dart';
import '../../features/join/mode_c_review_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/onboarding/onboarding_provider.dart';
import '../../services/join_service.dart';
import '../../services/backend_config.dart';

/// Named route paths.
class AppRoutes {
  AppRoutes._();

  static const chats = '/chats';
  static const groups = '/groups';
  static const activity = '/activity';
  static const profile = '/profile';

  /// SK Spaces directory (live audio rooms): /spaces
  static const spaces = '/spaces';

  /// Code (skcode remote agent sessions), the skcode subapp pane: /code
  static const code = '/code';

  /// A single skcode session, full screen (spec section 7, card C-4 part 4):
  /// /code/s/:sid. Not yet mounted to a screen (card C-10, the Grade A
  /// registry flip, is deliberately last); the constant exists now so
  /// `mapSkcodeDeeplink` (`lib/features/shell/app_shell_context.dart`) has a
  /// real target to resolve `skworld://skcode/session/<sid>` onto (card C-9).
  static const codeSession = '/code/s/:sid';

  /// Build the concrete path for [codeSession].
  static String codeSessionPath(String sid) => '/code/s/$sid';

  /// The Digest tab's deep-link target (card C-9, spec section 9):
  /// `skworld://skcode/digest` resolves here. Same not-yet-mounted status as
  /// [codeSession].
  static const codeDigest = '/code/digest';

  /// Operator hub ("Ops" tab), links the operator control surfaces: /hub
  static const hub = '/hub';

  /// Recordings browser (call/space recordings): /recordings
  static const recordings = '/recordings';

  /// Host route for a DISCOVERED external subapp module (card e378d895). A
  /// single parametric route so the router never has to rebuild when runtime
  /// discovery resolves: the `:moduleId` segment is looked up against the
  /// discovered set and rendered via the embed host. `/x/<id>`
  static const externalModule = '/x/:moduleId';

  /// Build the host route for a discovered external module [id].
  static String externalModulePath(String id) => '/x/$id';

  /// Contact Requests, first-contact consent review (gate 5): /requests
  static const requests = '/requests';

  /// Coordination board: /coord
  static const coord = '/coord';

  /// Cluster control (skbloom): /cluster
  static const cluster = '/cluster';

  /// SkMap tactical map (live unit/CoT positions): /skmap
  static const skmap = '/skmap';

  /// skos Files browser + corpus search (P7 access plane): /skos/files
  static const skosFiles = '/skos/files';

  /// skos control panel (per-node health/node_info): /skos/control
  static const skosControl = '/skos/control';

  /// skos full-screen media viewer (image/video/audio gallery), opened ABOVE
  /// the shell so the bottom nav never shows through. Pushed via `context.push`
  /// so browser-history back / the in-app ✕ pop consistently back to the live
  /// skos Files screen (preserving its browsed dir) instead of resetting to
  /// root, see SkosFileViewer + the close→root bugfix.
  static const skosView = '/skos/view';

  /// A single Space room (takes a SpaceJoin via extra): /spaces/:id
  static const spaceRoom = '/spaces/:id';

  /// Peer picker: /chats/new
  static const peerPicker = '/chats/new';

  /// Conversation detail: /chats/:peerId
  static const conversation = '/chats/:peerId';

  /// Agent/peer identity card: /identity/:peerId
  static const identity = '/identity/:peerId';

  /// Group info & member management: /groups/:groupId/info
  static const groupInfo = '/groups/:groupId/info';

  /// Create new group: /groups/new
  static const createGroup = '/groups/new';

  /// QR pairing screen (show/scan peer QR to connect): /login/qr
  static const qrLogin = '/login/qr';

  /// Modules settings (enable/disable + placement): /modules
  static const modules = '/modules';

  /// Manage models (enable/disable which discovered models are advertised to
  /// the picker + brain; drives the gateway advertise allowlist): /models/manage
  static const manageModels = '/models/manage';

  /// Reveal this device's 24-word recovery phrase (biometric-gated): /identity/recovery
  static const recoveryPhrase = '/identity/recovery';

  /// Restore this device's identity from a recovery phrase: /identity/restore
  static const restoreFromPhrase = '/identity/restore';

  /// Linked Devices: every device enrolled to this operator identity, with
  /// per-device Unlink + "Unlink all other devices": /devices/linked
  static const linkedDevices = '/devices/linked';

  static String conversationPath(String peerId) => '/chats/$peerId';
  static String identityPath(String peerId) => '/identity/$peerId';
  static String groupInfoPath(String groupId) => '/groups/$groupId/info';
  static String spaceRoomPath(String spaceId) => '/spaces/$spaceId';

  /// LiveKit SFU call screen: /call/livekit
  static const livekitCall = '/call/livekit';

  /// Conference room (sovereign /conf REST surface): /conf
  /// Takes a [ConfArgs] via `extra` (create or join + role).
  static const conf = '/conf';

  /// FaceTime (avatar call): /facetime  (optional `?agent=lumina` preselect).
  static const facetime = '/facetime';

  /// Build a FaceTime route preselecting [agent].
  static String facetimePath(String agent) =>
      '/facetime?agent=${Uri.encodeQueryComponent(agent)}';

  /// Conference deep-link join (Sovereign vs Guest chooser):
  ///   `/join?room=ROOM&invite=TOKEN`   (guest)
  ///   `/join?room=ROOM&sovereign=1`    (sovereign)
  static const join = '/join';

  /// Guest GROUP access landing (outside the authed shell):
  ///   `/g/:token`, opens the group invite, prompts a name (first visit),
  ///   generates+persists a browser keypair, and enters the guest room.
  static const guestGroup = '/g/:token';

  /// Build a guest-group landing path for an invite [token].
  static String guestGroupPath(String token) => '/g/$token';

  /// First-run onboarding wizard (welcome -> server -> identity -> done),
  /// shown outside the shell until the user completes it: /onboarding
  static const onboarding = '/onboarding';

  /// Operator Mode C review: pending peer accept assertions + counter-sign.
  static const modeCReview = '/mode-c';

  /// Dev/preview host that MOUNTS the live `skchat_ui` SkworldModule via a
  /// concrete ShellContext (U3). Top-level (outside the shell) and reached via
  /// `context.push`, so it never disturbs the primary Chats tab: /module/skchat
  static const moduleSkchat = '/module/skchat';

  /// Build a guest join link/route for [room] with an [invite] token.
  static String guestJoinPath(String room, String invite) =>
      '/join?room=${Uri.encodeQueryComponent(room)}'
      '&invite=${Uri.encodeQueryComponent(invite)}';

  /// Build a sovereign join link/route for [room].
  static String sovereignJoinPath(String room) =>
      '/join?room=${Uri.encodeQueryComponent(room)}&sovereign=1';

  /// Build a native conf hand-off route carrying a pre-minted LiveKit token.
  /// Mirrors the backend `/app/#/conf?...` deep link produced after a
  /// guest/sovereign/conf token mint. Empty optional fields are omitted.
  static String confJoinPath(
    String room, {
    String? token,
    String? url,
    String? identity,
    String? display,
  }) {
    final q = <String, String>{'room': room};
    if ((token ?? '').isNotEmpty) q['token'] = token!;
    if ((url ?? '').isNotEmpty) q['url'] = url!;
    if ((identity ?? '').isNotEmpty) q['identity'] = identity!;
    if ((display ?? '').isNotEmpty) q['display'] = display!;
    final query = q.entries
        .map((e) =>
            '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$conf?$query';
  }
}

/// When the backend is unconfigured (neutral build, empty web-ui URL),
/// send the user to the server picker (Profile) so they choose an instance
/// before any client hits an empty base URL. Returns null to proceed.
/// The profile route itself is always allowed through (no redirect loop).
String? backendSetupRedirect({
  required String webuiUrl,
  required String currentLocation,
}) {
  if (webuiUrl.trim().isNotEmpty) return null;
  if (currentLocation == AppRoutes.profile) return null;
  return AppRoutes.profile;
}

/// Path prefixes that must NEVER be bounced by [startupRedirect]. Guest
/// deep-links drop an unauthenticated user straight into one room / invite,
/// so the first-run onboarding gate has to let them through untouched, even
/// on a neutral (unconfigured) build. Verified against the actual guest-facing
/// routes below: `/g/:token` (guest group landing), `/join` (conference
/// deep-link chooser), and `/conf` (native conf hand-off with a minted token).
const kGuestDeepLinkPrefixes = <String>['/g/', '/join', '/conf'];

/// True when [location] is (or is under) a guest deep-link that the onboarding
/// gate must never redirect away from.
bool isGuestDeepLink(String location) {
  for (final prefix in kGuestDeepLinkPrefixes) {
    if (location == prefix || location.startsWith(prefix)) return true;
  }
  return false;
}

/// First-run gate for the app router. Returns the path to redirect to, or null
/// to proceed to [currentLocation] unchanged.
///
/// Rules, in order:
///  (a) A guest deep-link ([isGuestDeepLink]) is ALWAYS allowed through, so a
///      shared invite/room link opens even before onboarding, on any build.
///  (b) Already at `/onboarding` -> null, so the wizard never redirects onto
///      itself (no loop), whether or not it has been completed.
///  (c) A first-run user (onboarding not yet completed) is sent to
///      `/onboarding`; a returning/configured user proceeds to the normal
///      shell (null).
///
/// This is a pure function of its inputs (no Hive, no providers) so it can be
/// unit-tested as a truth table. The router reads the live
/// [onboardingCompleteProvider] value and passes it in.
String? startupRedirect({
  required String currentLocation,
  required bool onboardingComplete,
}) {
  // (a) Never bounce a guest deep-link.
  if (isGuestDeepLink(currentLocation)) return null;
  // (b) Already at the target: no redirect loop.
  if (currentLocation == AppRoutes.onboarding) return null;
  // (c) First run -> wizard; otherwise proceed.
  if (!onboardingComplete) return AppRoutes.onboarding;
  return null;
}

/// A [ChangeNotifier] GoRouter listens to via `refreshListenable`. It is
/// "bumped" whenever a provider the [startupRedirect] depends on changes AFTER
/// the async Hive load. Without it, the redirect is evaluated exactly once on
/// cold start, before `onboardingCompleteProvider` / `backendConfigProvider`
/// have hydrated from Hive, and never re-runs, so a returning user could be
/// misrouted into the wizard (or a guest bounced) until the next manual
/// navigation. Bridging those providers to a Listenable makes GoRouter
/// re-evaluate `redirect` the moment the persisted state settles.
class RouterRefreshListenable extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// GoRouter provider, uses shell routes for the bottom nav structure.
final appRouterProvider = Provider<GoRouter>((ref) {
  // Bridge the async-loaded state into GoRouter's refresh mechanism. These are
  // `listen`ed (not `watch`ed) so a state change re-runs the redirect via the
  // Listenable instead of rebuilding the whole GoRouter (which would reset
  // navigation state on every config change).
  final refresh = RouterRefreshListenable();
  ref.onDispose(refresh.dispose);
  ref.listen(onboardingCompleteProvider, (_, _) => refresh.bump());
  ref.listen(backendConfigProvider, (_, _) => refresh.bump());

  return GoRouter(
    initialLocation: AppRoutes.chats,
    debugLogDiagnostics: false,
    refreshListenable: refresh,
    redirect: (context, state) => startupRedirect(
      currentLocation: state.matchedLocation,
      onboardingComplete: ref.read(onboardingCompleteProvider),
    ),
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.chats,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              // The Chats tab body is chosen by a flag (default OFF -> native
              // ChatsScreen). ON renders the mounted skchat_ui module via the
              // shared SkchatModuleHostScreen mount path. See ChatsTab.
              const ChatsTab(),
            ),
            routes: [
              GoRoute(
                path: 'new',
                builder: (context, state) => const PeerPickerScreen(),
              ),
              GoRoute(
                path: ':peerId',
                builder: (context, state) {
                  final peerId = state.pathParameters['peerId']!;
                  return ConversationScreen(peerId: peerId);
                },
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.createGroup,
            builder: (context, state) => const CreateGroupScreen(),
          ),
          GoRoute(
            path: AppRoutes.groupInfo,
            builder: (context, state) {
              final groupId = state.pathParameters['groupId']!;
              return GroupInfoScreen(groupId: groupId);
            },
          ),
          GoRoute(
            path: AppRoutes.activity,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const ActivityScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.profile,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const ProfileScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.spaces,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const SpacesDirectoryScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.code,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const SkcodePane(),
            ),
          ),
          GoRoute(
            path: AppRoutes.hub,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const HubScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.coord,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const CoordBoardScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.cluster,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const ClusterScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.skmap,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const SkMapScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.skosFiles,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const SkosFilesScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.skosControl,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const SkosControlScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.recordings,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const RecordingsScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.requests,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const RequestsScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.modules,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const ModulesSettingsScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.manageModels,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const ManageModelsScreen(),
            ),
          ),
          // Host for DISCOVERED external subapp modules (card e378d895). One
          // static parametric route inside the shell so a discovered subapp is
          // reachable without rebuilding the router; the pane resolves the
          // manifest by id and embeds its Grade B web surface over the funnel.
          GoRoute(
            path: AppRoutes.externalModule,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              ExternalModulePane(
                moduleId: state.pathParameters['moduleId'] ?? '',
              ),
            ),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.identity,
        builder: (context, state) {
          final args = state.extra as IdentityCardArgs;
          return IdentityCardScreen(
            conversation: args.conversation,
            onSendMessage: args.onSendMessage,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.qrLogin,
        builder: (context, state) => const QrLoginScreen(),
      ),

      // ── Device recovery phrase (BIP39 backup / restore) ─────────────────
      // Top-level (outside the shell) so they push over the bottom nav.
      GoRoute(
        path: AppRoutes.recoveryPhrase,
        builder: (context, state) => const RecoveryPhraseScreen(),
      ),
      GoRoute(
        path: AppRoutes.restoreFromPhrase,
        builder: (context, state) => const RestoreFromPhraseScreen(),
      ),

      // ── Linked Devices (operator device management) ─────────────────────
      GoRoute(
        path: AppRoutes.linkedDevices,
        builder: (context, state) => const LinkedDevicesScreen(),
      ),

      // ── skos full-screen media viewer (above the shell) ─────────────────
      // A top-level (non-shell) route so it covers the bottom nav, with an
      // opaque black backdrop + quick fade. Being a real GoRouter route keeps
      // push/pop in sync with browser history: closing (✕ or back) pops back
      // to the live /skos/files screen, which still holds its browsed dir
      // (currentPathProvider), fixing the close→root regression that the old
      // imperative root-Navigator push caused on web.
      GoRoute(
        path: AppRoutes.skosView,
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          opaque: true,
          barrierColor: Colors.black,
          fullscreenDialog: true,
          transitionDuration: const Duration(milliseconds: 180),
          child: const SkosFileViewer(),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      ),

      // ── Conference deep-link join (Sovereign vs Guest chooser) ──────────
      GoRoute(
        path: AppRoutes.join,
        builder: (context, state) {
          // Parse the link's query params into a JoinLink. GoRouter exposes
          // them via state.uri.queryParameters (works for in-app pushes and
          // OS deep links routed to this path).
          final link = JoinLink.fromParams(state.uri.queryParameters);
          if (link == null) {
            return const _InvalidJoinScreen();
          }
          return JoinScreen(link: link);
        },
      ),

      // ── Guest GROUP access (shareable-link, outside the shell) ───────────
      // `/g/:token` lands an untrusted guest into ONE group with full in-room
      // functionality (chat/files/call) but no nav/admin/invite. The landing
      // generates+persists a WebCrypto keypair and joins; a returning guest
      // (cached key) auto-joins.
      GoRoute(
        path: AppRoutes.guestGroup,
        builder: (context, state) {
          final token = state.pathParameters['token'] ?? '';
          if (token.isEmpty) return const _InvalidJoinScreen();
          return GuestLandingScreen(token: token);
        },
      ),

      // ── First-run onboarding wizard (outside the shell) ─────────────────
      // Reached via [startupRedirect] when onboarding has not been completed.
      // On finish it persists the completion flag (which bumps the router's
      // refreshListenable) and navigates to the normal shell.
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => OnboardingScreen(
          onComplete: () => context.go(AppRoutes.chats),
        ),
      ),

      // Operator Mode C review: pending peer accept assertions + counter-sign.
      GoRoute(
        path: AppRoutes.modeCReview,
        builder: (context, state) => const ModeCReviewScreen(),
      ),

      // -- Module host (U3): mounts the LIVE skchat_ui SkworldModule with a
      //    concrete ShellContext. Top-level so it never touches the shell's
      //    tab-highlight logic; the module's deep links map back onto this
      //    router via AppShellBus. A dev/preview entry, not the primary tab.
      GoRoute(
        path: AppRoutes.moduleSkchat,
        builder: (context, state) => const SkchatModuleHostScreen(),
      ),

      // -- LiveKit SFU call screen
      GoRoute(
        path: AppRoutes.livekitCall,
        pageBuilder: (context, state) {
          final args = state.extra as LiveKitCallArgs;
          return MaterialPage(
            fullscreenDialog: true,
            child: LiveKitCallScreen(args: args),
          );
        },
      ),

      // -- SK Space audio room (role-scoped LiveKit token via extra)
      GoRoute(
        path: AppRoutes.spaceRoom,
        pageBuilder: (context, state) {
          final join = state.extra as SpaceJoin;
          return MaterialPage(
            fullscreenDialog: true,
            child: SpaceRoomScreen(join: join),
          );
        },
      ),

      // -- Conference room (sovereign /conf REST surface).
      //    In-app navigation passes a ConfArgs via `extra`; a shared/native
      //    hand-off link (e.g. /app/#/conf?room=R&token=T&url=U&identity=I from
      //    a guest/sovereign token mint) carries query params instead. Both land
      //    in ConfScreen, which connects via LiveKitCallService.connectWithToken.
      GoRoute(
        path: AppRoutes.conf,
        pageBuilder: (context, state) {
          final extra = state.extra;
          final args = extra is ConfArgs
              ? extra
              : ConfArgs.fromParams(state.uri.queryParameters);
          if (args == null) {
            return const MaterialPage(child: _InvalidJoinScreen());
          }
          return MaterialPage(
            fullscreenDialog: true,
            child: ConfScreen(args: args),
          );
        },
      ),

      // -- FaceTime (avatar call); optional ?agent= preselect
      GoRoute(
        path: AppRoutes.facetime,
        pageBuilder: (context, state) {
          final agent = state.uri.queryParameters['agent'];
          return MaterialPage(
            fullscreenDialog: true,
            child: FaceTimeScreen(initialAgent: agent),
          );
        },
      ),
    ],
  );
});

/// Instant tab switch, no transition animation on tab change.
/// Push navigation (conversations) uses the default spring transition.
NoTransitionPage<void> _noTransitionPage(GoRouterState state, Widget child) {
  return NoTransitionPage<void>(key: state.pageKey, child: child);
}

/// Shown when a `/join` link is missing a room or offers no join path.
class _InvalidJoinScreen extends StatelessWidget {
  const _InvalidJoinScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join call')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off, size: 48),
              const SizedBox(height: 12),
              Text(
                'This join link is invalid or incomplete.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go(AppRoutes.chats),
                child: const Text('Back to chats'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
