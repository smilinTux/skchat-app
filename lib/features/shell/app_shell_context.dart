import 'dart:async';

import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import '../../core/router/app_router.dart';

/// Maps a `skworld://skchat/...` deep link onto the app's GoRouter path, or
/// null when the link has no mapped target (the caller then degrades safely
/// rather than crashing).
///
/// This is a PURE function of the deep link string so the mapping is unit
/// testable on its own, independent of any router or widget tree. It is the
/// one place that translates the module's own deep-link authority (its
/// `nav.deeplinkPrefix`, spec 3.1) into concrete app routes:
///
///   * `skworld://skchat/thread/<id>`  -> `/chats/<id>`   (conversation route)
///   * `skworld://skchat/compose`      -> `/chats/new`    (peer picker route)
///   * `skworld://skchat/` (bare)      -> `/chats`        (the chats list)
///
/// Anything else under the `skchat` authority (an unknown segment, a `thread`
/// with no id) returns null: the shell logs and no-ops / shows a SnackBar
/// instead of navigating to a route that does not exist.
String? mapSkchatDeeplink(String deeplink) {
  final uri = Uri.tryParse(deeplink);
  if (uri == null) return null;
  // Only this module's own authority is handled here.
  if (uri.scheme != 'skworld' || uri.host != 'skchat') return null;

  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (segments.isEmpty) return AppRoutes.chats;

  switch (segments.first) {
    case 'thread':
      // Needs a peer id: skworld://skchat/thread/<id> -> /chats/<id>.
      if (segments.length >= 2) return AppRoutes.conversationPath(segments[1]);
      return null;
    case 'compose':
      return AppRoutes.peerPicker;
    default:
      return null;
  }
}

/// Maps a `skworld://skcode/...` deep link onto the app's GoRouter path, or
/// null when the link has no mapped target, mirroring [mapSkchatDeeplink]
/// exactly (card C-9, spec section 9: "every digest line carries a
/// `skworld://` uri that today resolves nowhere ... the shell router is
/// where those links were always meant to land").
///
///   * `skworld://skcode/session/<sid>` -> `/code/s/<sid>` (a session pushed
///     full screen, spec section 7)
///   * `skworld://skcode/digest`        -> `/code/digest`  (the Digest tab,
///     spec section 9)
///   * `skworld://skcode/` (bare)       -> `/code`         (the landing rail)
///
/// Neither [AppRoutes.codeSession] nor [AppRoutes.codeDigest] is mounted to a
/// live screen yet (card C-10, the Grade A registry flip, is deliberately
/// last per the implementation plan): this function is the pure, independently
/// testable RESOLUTION LOGIC card C-9 owns, ready for C-10 to wire onto real
/// routes without this mapping changing shape.
String? mapSkcodeDeeplink(String deeplink) {
  final uri = Uri.tryParse(deeplink);
  if (uri == null) return null;
  if (uri.scheme != 'skworld' || uri.host != 'skcode') return null;

  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (segments.isEmpty) return AppRoutes.code;

  switch (segments.first) {
    case 'session':
      // Needs a session id: skworld://skcode/session/<sid> -> /code/s/<sid>.
      if (segments.length >= 2) return AppRoutes.codeSessionPath(segments[1]);
      return null;
    case 'digest':
      return AppRoutes.codeDigest;
    default:
      return null;
  }
}

/// Concrete [ShellBus] the app supplies to a mounted [SkworldModule].
///
/// It is deliberately transport-agnostic: [navigate] parses a `skworld://`
/// deep link by trying each module's own mapper in turn ([mapSkchatDeeplink],
/// [mapSkcodeDeeplink]) and, on a hit, calls [onNavigate] with the resolved
/// app route (the host wires that to `context.go`); on a miss it calls the
/// optional [onUnhandled] so the shell can log + no-op or show a SnackBar
/// rather than crash. This is "the shell router" the module contract and the
/// skwatchdog/skcode specs both point at as the one place `skworld://` links
/// resolve, regardless of which module's authority they carry (card C-9).
/// Events flow over a broadcast stream so the same contract survives a future
/// out-of-process (postmessage) bridge.
class AppShellBus implements ShellBus {
  AppShellBus({required this.onNavigate, this.onUnhandled});

  /// Called with the resolved app route when a deep link maps to one.
  final void Function(String location) onNavigate;

  /// Called with the original deep link when it maps to no route. Null means
  /// "silently no-op" (the parse already logged nothing sensitive).
  final void Function(String deeplink)? onUnhandled;

  final StreamController<ShellEvent> _events =
      StreamController<ShellEvent>.broadcast();

  @override
  void navigate(String deeplink) {
    final route = mapSkchatDeeplink(deeplink) ?? mapSkcodeDeeplink(deeplink);
    if (route != null) {
      onNavigate(route);
      return;
    }
    // No mapped target: degrade safely instead of crashing.
    onUnhandled?.call(deeplink);
  }

  @override
  void emit(ShellEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Stream<ShellEvent> get events => _events.stream;

  /// Release the event stream. The host route owns the bus lifecycle and
  /// calls this from its `dispose`.
  void dispose() {
    _events.close();
  }
}

/// Minimal concrete [AuthContext] for the mounted skchat module.
///
/// The module never holds a root credential (spec 2.3): it is scoped to the
/// `skchat` audience with the chat capability scopes. [subjectFqid] carries
/// whatever local identity the host resolves (the device PGP fingerprint
/// today), or null when no identity is established yet.
///
/// [token] completes the audience-token chain: it delegates to [tokenMinter],
/// which mints (and caches) a short-lived, audience-scoped bearer from the
/// backend `POST /api/v1/audience-token` endpoint using the app's existing
/// authenticated client. The mint endpoint is guarded behind the server's
/// `SKCHAT_AUDIENCE_MINT` flag (OFF by default, so it 404s); on that inert
/// case, or any network / auth / parse failure, [token] returns null (the prior
/// stubbed behavior) and NEVER throws, so a mounted module simply runs with no
/// token until the server enables minting. When no [tokenMinter] is supplied
/// (standalone / test), [token] returns null unconditionally.
class AppAuthContext implements AuthContext {
  const AppAuthContext({
    this.subjectFqid,
    Future<String?> Function(String audience)? tokenMinter,
  }) : _tokenMinter = tokenMinter;

  /// Mints an audience-scoped bearer for the given audience, or null when none
  /// is available. The concrete implementation caches by audience and swallows
  /// failures; see `AudienceTokenService`. Null (the default) means "no minter
  /// wired", so [token] returns null.
  final Future<String?> Function(String audience)? _tokenMinter;

  @override
  String get audience => 'skchat';

  @override
  final String? subjectFqid;

  @override
  Set<String> get scopes => const {'chat.read', 'chat.send'};

  @override
  bool hasScope(String scope) => scopes.contains(scope);

  @override
  Future<String?> token() async {
    final minter = _tokenMinter;
    if (minter == null) return null;
    try {
      return await minter(audience);
    } catch (_) {
      // Contract: token() must never throw. Any failure that slipped past the
      // minter's own guards degrades to "no token".
      return null;
    }
  }
}

/// Concrete [ShellContext] the app hands a mounted [SkworldModule].
///
/// It bundles the three shell surfaces the module contract requires: the app's
/// resolved [ThemeData] (so the module renders in the live Sovereign Glass
/// look, not its own fallback), the audience-scoped [AppAuthContext], and the
/// [AppShellBus] that routes the module's deep links onto the app GoRouter.
class AppShellContext implements ShellContext {
  const AppShellContext({
    required this.theme,
    required this.bus,
    required this.auth,
  });

  @override
  final ThemeData theme;

  @override
  final ShellBus bus;

  @override
  final AuthContext auth;
}
