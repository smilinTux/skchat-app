import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/shell/app_shell.dart';
import '../../features/chats/chats_screen.dart';
import '../../features/groups/groups_screen.dart';
import '../../features/activity/activity_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/conversation/conversation_screen.dart';
import '../../features/identity/identity_card_screen.dart';
import '../../features/groups/group_info_screen.dart';
import '../../features/groups/create_group_screen.dart';
import '../../features/chats/peer_picker_screen.dart';
import '../../features/profile/qr_login_screen.dart';
import '../../features/profile/modules_settings_screen.dart';
import '../../features/calls/outgoing_call_screen.dart';
import '../../features/calls/incoming_call_screen.dart';
import '../../features/calls/in_call_screen.dart';
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
import '../../features/skmap/skmap_screen.dart';
import '../../features/skos/skos_files_screen.dart';
import '../../features/skos/skos_control_screen.dart';
import '../../features/join/join_screen.dart';
import '../../features/guest/guest_landing_screen.dart';
import '../../services/join_service.dart';

/// Named route paths.
class AppRoutes {
  AppRoutes._();

  static const chats = '/chats';
  static const groups = '/groups';
  static const activity = '/activity';
  static const profile = '/profile';

  /// SK Spaces directory (live audio rooms): /spaces
  static const spaces = '/spaces';

  /// Operator hub ("Ops" tab) — links the operator control surfaces: /hub
  static const hub = '/hub';

  /// Recordings browser (call/space recordings): /recordings
  static const recordings = '/recordings';

  /// Contact Requests — first-contact consent review (gate 5): /requests
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
  /// root — see SkosFileViewer + the close→root bugfix.
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

  /// CapAuth QR login screen: /login/qr
  static const qrLogin = '/login/qr';

  /// Modules settings (enable/disable + placement): /modules
  static const modules = '/modules';

  /// Outgoing call screen: /call/outgoing/:peerId
  static const outgoingCall = '/call/outgoing/:peerId';

  /// Incoming call screen: /call/incoming/:peerId
  static const incomingCall = '/call/incoming/:peerId';

  /// Active in-call screen: /call/active/:peerId
  static const inCall = '/call/active/:peerId';

  static String conversationPath(String peerId) => '/chats/$peerId';
  static String identityPath(String peerId) => '/identity/$peerId';
  static String groupInfoPath(String groupId) => '/groups/$groupId/info';
  static String outgoingCallPath(String peerId) => '/call/outgoing/$peerId';
  static String incomingCallPath(String peerId) => '/call/incoming/$peerId';
  static String inCallPath(String peerId) => '/call/active/$peerId';
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
  ///   `/g/:token` — opens the group invite, prompts a name (first visit),
  ///   generates+persists a browser keypair, and enters the guest room.
  static const guestGroup = '/g/:token';

  /// Build a guest-group landing path for an invite [token].
  static String guestGroupPath(String token) => '/g/$token';

  /// Build a guest join link/route for [room] with an [invite] token.
  static String guestJoinPath(String room, String invite) =>
      '/join?room=${Uri.encodeQueryComponent(room)}'
      '&invite=${Uri.encodeQueryComponent(invite)}';

  /// Build a sovereign join link/route for [room].
  static String sovereignJoinPath(String room) =>
      '/join?room=${Uri.encodeQueryComponent(room)}&sovereign=1';
}

/// GoRouter provider — uses shell routes for the bottom nav structure.
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.chats,
    debugLogDiagnostics: false,
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.chats,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const ChatsScreen(),
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
            path: AppRoutes.groups,
            pageBuilder: (context, state) => _noTransitionPage(
              state,
              const GroupsScreen(),
            ),
            routes: [
              GoRoute(
                path: 'new',
                builder: (context, state) => const CreateGroupScreen(),
              ),
              GoRoute(
                path: ':groupId/info',
                builder: (context, state) {
                  final groupId = state.pathParameters['groupId']!;
                  return GroupInfoScreen(groupId: groupId);
                },
              ),
            ],
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

      // ── skos full-screen media viewer (above the shell) ─────────────────
      // A top-level (non-shell) route so it covers the bottom nav, with an
      // opaque black backdrop + quick fade. Being a real GoRouter route keeps
      // push/pop in sync with browser history: closing (✕ or back) pops back
      // to the live /skos/files screen, which still holds its browsed dir
      // (currentPathProvider) — fixing the close→root regression that the old
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

      // ── Call screens ────────────────────────────────────────────────────
      GoRoute(
        path: AppRoutes.outgoingCall,
        pageBuilder: (context, state) {
          final peerId = state.pathParameters['peerId']!;
          return MaterialPage(
            fullscreenDialog: true,
            child: OutgoingCallScreen(peerId: peerId),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.incomingCall,
        pageBuilder: (context, state) {
          final peerId = state.pathParameters['peerId']!;
          return MaterialPage(
            fullscreenDialog: true,
            child: IncomingCallScreen(peerId: peerId),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.inCall,
        pageBuilder: (context, state) {
          final peerId = state.pathParameters['peerId']!;
          return MaterialPage(
            fullscreenDialog: true,
            child: InCallScreen(peerId: peerId),
          );
        },
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

      // -- Conference room (sovereign /conf REST surface; ConfArgs via extra)
      GoRoute(
        path: AppRoutes.conf,
        pageBuilder: (context, state) {
          final args = state.extra as ConfArgs;
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

/// Instant tab switch — no transition animation on tab change.
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
