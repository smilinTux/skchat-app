import "dart:async";

import "package:flutter/material.dart";
import "package:skworld_module_api/skworld_module_api.dart";

import "skcode_api_client.dart";
import "skcode_session_screen.dart";
import "skcode_sessions_list_store.dart";
import "skcode_ws_transport.dart";

/// The sessions rail (card C-4 part 4, spec section 7): on phone this IS the
/// `/code` landing screen. Polls `GET /sessions` via [SkcodeSessionsListStore]
/// while mounted and pushes [SkcodeSessionScreen] full screen
/// (`/code/s/:sid`) when a row is tapped.
///
/// Jobs (spec section 8, card C-8) are explicitly out of scope: this rail
/// lists sessions only.
class SkcodeSessionsRail extends StatefulWidget {
  const SkcodeSessionsRail({
    super.key,
    required this.apiClient,
    required this.origin,
    required this.mintToken,
    required this.onAuthRejected,
    this.connectTransport = SkcodeWsTransport.connect,
    this.auth,
  });

  final SkcodeApiClient apiClient;
  final String origin;
  final Future<String?> Function() mintToken;
  final VoidCallback onAuthRejected;

  /// Forwarded to the pushed [SkcodeSessionScreen] (test seam: a widget test
  /// injects a fake transport so tapping a row never opens a real socket).
  final SkcodeWsTransport Function(Uri uri) connectTransport;

  /// Forwarded straight through to the pushed [SkcodeSessionScreen] (card
  /// C-5): the audience-scoped [AuthContext] its inject-composer scope gate
  /// reads via `hasScope(kSkcodeInjectScope)`.
  final AuthContext? auth;

  @override
  State<SkcodeSessionsRail> createState() => _SkcodeSessionsRailState();
}

class _SkcodeSessionsRailState extends State<SkcodeSessionsRail> {
  late final SkcodeSessionsListStore _store;
  List<SkcodeSessionSummary> _sessions = const [];
  StreamSubscription<List<SkcodeSessionSummary>>? _sub;

  @override
  void initState() {
    super.initState();
    _store = SkcodeSessionsListStore(
      apiClient: widget.apiClient,
      mintToken: widget.mintToken,
    );
    _sub = _store.sessions.listen((list) {
      if (mounted) setState(() => _sessions = list);
    });
    _store.startPolling();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _store.stopPolling();
    unawaited(_store.dispose());
    super.dispose();
  }

  void _openSession(BuildContext context, SkcodeSessionSummary session) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SkcodeSessionScreen(
          sid: session.sid,
          apiClient: widget.apiClient,
          origin: widget.origin,
          mintToken: widget.mintToken,
          onAuthRejected: widget.onAuthRejected,
          connectTransport: widget.connectTransport,
          auth: widget.auth,
          // AC4's other half: the focused session must itself be
          // interactive (`SkcodeSessionSummary.mode == "interactive"`) for
          // the inject composer to render at all.
          interactive: session.mode == "interactive",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_sessions.isEmpty) {
      return const Center(child: Text("No sessions yet"));
    }
    return ListView.builder(
      itemCount: _sessions.length,
      itemBuilder: (context, index) {
        final session = _sessions[index];
        return _SessionTile(
          session: session,
          onTap: () => _openSession(context, session),
        );
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.onTap});

  final SkcodeSessionSummary session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRunning = session.state == "running";
    final subtitleParts = [
      if (session.lastMessage.isNotEmpty) session.lastMessage,
      if (session.repo.isNotEmpty) session.repo,
      session.harness,
    ].where((s) => s.isNotEmpty).toList();

    return ListTile(
      key: ValueKey(session.sid),
      leading: Icon(
        Icons.circle,
        size: 10,
        color: isRunning ? Colors.green : Theme.of(context).disabledColor,
      ),
      title: Text(session.sid),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(" · ")),
      onTap: onTap,
    );
  }
}
