import "dart:async";

import "package:flutter/material.dart";

import "skcode_api_client.dart";
import "skcode_config.dart";
import "skcode_raw_rail.dart";
import "skcode_session_store.dart";
import "skcode_transcript_list.dart";
import "skcode_ws_transport.dart";

/// Which of the two live views owns the body. Buzz's `RawRailLayout` has
/// three modes (hidden/side/exclusive); phone only ever needs the two ends
/// of that spectrum, since there is no room for a side-by-side rail (spec
/// section 7: "raw rail as an exclusive-mode toggle replacing the
/// transcript ... phone maps side to exclusive").
enum SkcodeRailMode { transcript, raw }

/// The full-screen session view (card C-4 part 4, spec section 7): pushed at
/// `/code/s/:sid` by `SkcodeSessionsRail` when a session row is tapped. Owns
/// one [SkcodeSessionStore] for the session's lifetime on screen (started on
/// mount, disposed on pop) and renders either [SkcodeTranscriptList] or
/// [SkcodeRawRail] for its body, toggled EXCLUSIVELY: never both at once.
///
/// The composer (chat send / session inject) is out of scope for this card
/// (C-5); this screen is transcript + raw rail only.
class SkcodeSessionScreen extends StatefulWidget {
  const SkcodeSessionScreen({
    super.key,
    required this.sid,
    required this.apiClient,
    required this.origin,
    required this.mintToken,
    required this.onAuthRejected,
    this.connectTransport = SkcodeWsTransport.connect,
  });

  final String sid;
  final SkcodeApiClient apiClient;

  /// Where skcode-hostd lives; combined with [sid] and a freshly minted
  /// token to build the WS tail URI ([skcodeWsUri]).
  final String origin;
  final Future<String?> Function() mintToken;
  final VoidCallback onAuthRejected;

  /// Overridable for tests; defaults to the real
  /// `WebSocketChannel.connect`-backed transport.
  final SkcodeWsTransport Function(Uri uri) connectTransport;

  @override
  State<SkcodeSessionScreen> createState() => _SkcodeSessionScreenState();
}

class _SkcodeSessionScreenState extends State<SkcodeSessionScreen> {
  late final SkcodeSessionStore _store;
  late SkcodeSessionState _state;
  StreamSubscription<SkcodeSessionState>? _sub;
  SkcodeRailMode _mode = SkcodeRailMode.transcript;

  @override
  void initState() {
    super.initState();
    _store = SkcodeSessionStore(
      sid: widget.sid,
      apiClient: widget.apiClient,
      mintToken: widget.mintToken,
      onAuthRejected: widget.onAuthRejected,
      connectTransport: widget.connectTransport,
      buildWsUri: (sid, token) => skcodeWsUri(widget.origin, sid, token),
    );
    _state = _store.state;
    _sub = _store.states.listen((next) {
      if (mounted) setState(() => _state = next);
    });
    unawaited(_store.start());
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(_store.dispose());
    super.dispose();
  }

  void _toggleMode() {
    setState(() {
      _mode = _mode == SkcodeRailMode.transcript
          ? SkcodeRailMode.raw
          : SkcodeRailMode.transcript;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isRaw = _mode == SkcodeRailMode.raw;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sid),
        actions: [
          IconButton(
            tooltip: isRaw ? "Show transcript" : "Show raw events",
            icon: Icon(isRaw ? Icons.forum_outlined : Icons.data_object),
            onPressed: _toggleMode,
          ),
        ],
      ),
      body: Column(
        children: [
          _ConnectionBanner(state: _state),
          Expanded(
            child: isRaw
                ? SkcodeRawRail(events: _state.events)
                : SkcodeTranscriptList(events: _state.events),
          ),
        ],
      ),
    );
  }
}

/// A thin status strip: silent while [SkcodeConnectionPhase.connected] with
/// no error, otherwise names the phase (and the error, once failed) so a
/// dropped WS tail is never a silently frozen transcript.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.state});

  final SkcodeSessionState state;

  @override
  Widget build(BuildContext context) {
    if (state.phase == SkcodeConnectionPhase.connected && state.error == null) {
      return const SizedBox.shrink();
    }
    final text = switch (state.phase) {
      SkcodeConnectionPhase.idle => "idle",
      SkcodeConnectionPhase.connecting => "connecting...",
      SkcodeConnectionPhase.connected => "connected",
      SkcodeConnectionPhase.reconnecting => "reconnecting...",
      SkcodeConnectionPhase.failed => state.error ?? "connection failed",
    };
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
