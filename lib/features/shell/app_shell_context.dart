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

/// Concrete [ShellBus] the app supplies to a mounted [SkworldModule].
///
/// It is deliberately transport-agnostic: [navigate] parses a `skworld://`
/// deep link through [mapSkchatDeeplink] and, on a hit, calls [onNavigate]
/// with the resolved app route (the host wires that to `context.go`); on a
/// miss it calls the optional [onUnhandled] so the shell can log + no-op or
/// show a SnackBar rather than crash. Events flow over a broadcast stream so
/// the same contract survives a future out-of-process (postmessage) bridge.
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
    final route = mapSkchatDeeplink(deeplink);
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
/// `skchat` audience with the chat capability scopes. A real, short-lived,
/// audience-scoped token mint (via `capauth`) lands with M2, so [token]
/// currently returns null with a TODO. [subjectFqid] carries whatever local
/// identity the host resolves (the device PGP fingerprint today), or null when
/// no identity is established yet.
class AppAuthContext implements AuthContext {
  const AppAuthContext({this.subjectFqid});

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
    // TODO(U-auth): mint a short-lived, audience-scoped bearer via capauth once
    // M2 audience minting lands. Until then the module runs with no token; the
    // live chats feed reaches the daemon through the app's own session, not a
    // module-scoped credential.
    return null;
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
