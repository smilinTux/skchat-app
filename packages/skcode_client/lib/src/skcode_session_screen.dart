import "dart:async";

import "package:flutter/material.dart";
import "package:skworld_module_api/skworld_module_api.dart";

import "skcode_api_client.dart";
import "skcode_artifact_pane.dart";
import "skcode_config.dart";
import "skcode_event.dart";
import "skcode_event_merge.dart";
import "skcode_inject_composer.dart";
import "skcode_needs_input_banner.dart";
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
/// The inject composer (card C-5) is wired in here: a [SkcodeInjectComposer]
/// renders at the bottom, gated by [_canInject] (AC4: `skcode.inject` scope
/// AND [interactive]), with a [SkcodeNeedsInputBanner] pinned directly above
/// it whenever the event stream carries an unresolved `needs_input` (AC2).
///
/// An "Artifacts" app bar action (card C-7) presents
/// [SkcodeArtifactPane.showBottomSheet]: the phone swipe-up entry point to the
/// Diff/Logs/Raw tabs, spec section 7's "artifact tabs via a swipe-up bottom
/// sheet".
///
/// Note that the composer here is the INJECT composer, which talks to a running
/// agent process. It is deliberately unlike a chat composer, which talks to
/// people. See [SkcodeInjectComposer] for why that distinction is enforced in
/// chrome rather than left to position.
class SkcodeSessionScreen extends StatefulWidget {
  const SkcodeSessionScreen({
    super.key,
    required this.sid,
    required this.apiClient,
    required this.origin,
    required this.mintToken,
    required this.onAuthRejected,
    this.connectTransport = SkcodeWsTransport.connect,
    this.auth,
    this.interactive = false,
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

  /// The mounted module's audience-scoped identity/token surface
  /// (`skworld_module_api`), forwarded from `SkcodeSurface`/
  /// `SkcodeSessionsRail`. Null in standalone mode before a real login seam
  /// exists (`SkcodeSurface`'s own doc comment), which correctly means
  /// [_SkcodeSessionScreenState._canInject] reads false: no [AuthContext],
  /// no provable `skcode.inject` scope, no inject composer (fail closed).
  final AuthContext? auth;

  /// Whether the session this screen is showing is itself interactive
  /// (`SkcodeSessionSummary.mode == "interactive"`), the other half of AC4's
  /// gate. Defaults false (fail closed): a caller must explicitly thread the
  /// session's own mode through, matching `SkcodeSessionsRail`'s
  /// `_openSession`.
  final bool interactive;

  @override
  State<SkcodeSessionScreen> createState() => _SkcodeSessionScreenState();
}

class _SkcodeSessionScreenState extends State<SkcodeSessionScreen> {
  late final SkcodeSessionStore _store;
  late SkcodeSessionState _state;
  StreamSubscription<SkcodeSessionState>? _sub;
  SkcodeRailMode _mode = SkcodeRailMode.transcript;

  /// The row id (see [skcodeEventRowId]) of the last `needs_input` event an
  /// operator resolved (Approve or Deny). Once an event's row id is in here
  /// its banner stays gone; a NEW `needs_input` event (a different row id -
  /// e.g. the retried ratify failing again) pins a fresh banner regardless.
  String? _resolvedNeedsInputRowId;

  /// True while an Approve/Deny/Inject action is in flight, so a slow
  /// network response can never be raced by a second tap onto the same
  /// write route.
  bool _actionBusy = false;

  /// AC4's gate, read straight off [AuthContext.hasScope] (`skworld_module_api`)
  /// exactly as the card specifies: "Use AuthContext.hasScope(); it already
  /// exists for exactly this." A null [SkcodeSessionScreen.auth] (standalone,
  /// no login seam yet) fails closed to false, never true.
  bool get _hasInjectScope => widget.auth?.hasScope(kSkcodeInjectScope) ?? false;

  /// The composer's own visibility gate (AC4): scope AND an interactive
  /// session. The needs_input banner is gated on scope alone (see
  /// `SkcodeNeedsInputBanner`'s doc comment: Approve/Deny are ratify/inject
  /// write actions, not specifically tied to whether this session accepts
  /// live keystroke inject).
  bool get _canInject => _hasInjectScope && widget.interactive;

  /// The most recent `needs_input` event not yet resolved this screen
  /// session, or null. [SkcodeSessionState.events] is already ascending
  /// `(ts, seq)` sorted (the store's own merge contract), so the latest one
  /// is found scanning from the end.
  SkcodeEvent? get _pendingNeedsInput {
    for (var i = _state.events.length - 1; i >= 0; i--) {
      final event = _state.events[i];
      if (event.type != "needs_input") continue;
      if (skcodeEventRowId(event) == _resolvedNeedsInputRowId) return null;
      return event;
    }
    return null;
  }

  Future<void> _runAction(Future<void> Function(String token) action) async {
    if (_actionBusy) return;
    final token = await widget.mintToken();
    if (token == null) return;
    setState(() => _actionBusy = true);
    try {
      await action(token);
    } catch (_) {
      // Best-effort: a failed ratify/inject/deny call leaves the banner (or
      // composer) exactly as it was so the operator can simply try again;
      // this screen has no toast/snackbar surface of its own to invent one
      // for (out of scope for this card).
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  void _resolveNeedsInput() {
    final pending = _pendingNeedsInput;
    if (pending != null) _resolvedNeedsInputRowId = skcodeEventRowId(pending);
  }

  Future<void> _handleApprove() => _runAction((token) async {
        await widget.apiClient.ratifySession(widget.sid, token: token);
        _resolveNeedsInput();
      });

  /// hostd has no dedicated deny/reject route (see `SkcodeNeedsInputBanner`'s
  /// doc comment); Deny answers through the same general inject surface with
  /// a literal negative keystroke.
  Future<void> _handleDeny() => _runAction((token) async {
        await widget.apiClient.injectText(widget.sid, "n", token: token);
        _resolveNeedsInput();
      });

  Future<void> _handleInject(String text) => _runAction(
        (token) => widget.apiClient.injectText(widget.sid, text, token: token),
      );

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
            tooltip: "Artifacts",
            icon: const Icon(Icons.dashboard_outlined),
            onPressed: () => SkcodeArtifactPane.showBottomSheet(
              context,
              events: _state.events,
            ),
          ),
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
          // Pinned directly above the composer (AC2), never buried in the
          // scroll above: rendered whenever the scope gate allows acting on
          // it at all, regardless of [SkcodeSessionScreen.interactive] (see
          // `_canInject`'s doc comment).
          if (_hasInjectScope && _pendingNeedsInput != null)
            SkcodeNeedsInputBanner(
              text: _pendingNeedsInput!.text.isEmpty
                  ? "This session needs an operator decision."
                  : _pendingNeedsInput!.text,
              busy: _actionBusy,
              onApprove: _handleApprove,
              onDeny: _handleDeny,
            ),
          // AC4: hidden entirely (not disabled, not present) unless the
          // token carries skcode.inject AND the session is interactive.
          if (_canInject) SkcodeInjectComposer(sid: widget.sid, onInject: _handleInject),
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
