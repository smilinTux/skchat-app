import "dart:async";

import "package:flutter/material.dart";
import "package:skworld_module_api/skworld_module_api.dart";

import "skcode_api_client.dart";
import "skcode_config.dart";
import "skcode_event.dart";
import "skcode_event_merge.dart";
import "skcode_inject_composer.dart";
import "skcode_needs_input_banner.dart";
import "skcode_session_store.dart";
import "skcode_transcript_list.dart";
import "skcode_ws_transport.dart";

/// The embeddable session detail (card C-12, spec section 7: "Transcript:
/// rendered through the taxonomy, inject composer beneath it ... a
/// `needs_input` event pins a permission banner ... directly above the
/// composer").
///
/// This is SkcodeSessionScreen's live-store/transcript/composer/banner
/// wiring, deliberately duplicated rather than extracted-and-shared: card
/// C-12 needs that wiring to render INLINE (a column among siblings, no
/// `Scaffold`, no `AppBar`, no raw-rail toggle, no cancel action -- those
/// three stay phone-screen-only conveniences, spec section 7's phone-only
/// "raw rail as an exclusive-mode toggle replacing the transcript"), while
/// SkcodeSessionScreen must keep rendering byte-for-byte what cards C-4
/// through C-6 already locked down with their own widget suites. Reaching
/// into `_SkcodeSessionScreenState` to share that logic would risk exactly
/// the kind of refactor-adjacent breakage this epic's own process notes warn
/// about; a small, well-attributed duplication is the safer trade.
///
/// [onEvents] fires on every store state change (card C-12's own need: the
/// wide-tier layout that embeds this column also feeds the SAME merged
/// event window into the artifact pane's Diff/Raw tabs, spec section 7's
/// "ask on the left, watch it land on the right" -- the artifact pane must
/// see every event this column sees, with no separate poll of its own).
class SkcodeSessionColumn extends StatefulWidget {
  const SkcodeSessionColumn({
    super.key,
    required this.sid,
    required this.apiClient,
    required this.origin,
    required this.mintToken,
    required this.onAuthRejected,
    this.connectTransport = SkcodeWsTransport.connect,
    this.auth,
    this.interactive = false,
    this.onEvents,
  });

  final String sid;
  final SkcodeApiClient apiClient;
  final String origin;
  final Future<String?> Function() mintToken;
  final VoidCallback onAuthRejected;
  final SkcodeWsTransport Function(Uri uri) connectTransport;
  final AuthContext? auth;
  final bool interactive;

  /// Called with the store's merged event window on every change (see the
  /// class doc comment). Optional: a caller with nowhere to route the
  /// events (a bare embed with no sibling artifact pane) may omit it.
  final ValueChanged<List<SkcodeEvent>>? onEvents;

  @override
  State<SkcodeSessionColumn> createState() => _SkcodeSessionColumnState();
}

class _SkcodeSessionColumnState extends State<SkcodeSessionColumn> {
  late final SkcodeSessionStore _store;
  late SkcodeSessionState _state;
  StreamSubscription<SkcodeSessionState>? _sub;

  /// See SkcodeSessionScreen's identical field for the exact contract:
  /// the row id of the last needs_input event an operator resolved.
  String? _resolvedNeedsInputRowId;

  bool _actionBusy = false;

  bool get _hasInjectScope => widget.auth?.hasScope(kSkcodeInjectScope) ?? false;
  bool get _canInject => _hasInjectScope && widget.interactive;

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
      // Best-effort, matching SkcodeSessionScreen's own contract: a failed
      // ratify/inject leaves state exactly as it was so the operator can
      // simply try again.
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
      widget.onEvents?.call(next.events);
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SessionColumnConnectionBanner(state: _state),
        Expanded(child: SkcodeTranscriptList(events: _state.events)),
        if (_hasInjectScope && _pendingNeedsInput != null)
          SkcodeNeedsInputBanner(
            text: _pendingNeedsInput!.text.isEmpty
                ? "This session needs an operator decision."
                : _pendingNeedsInput!.text,
            busy: _actionBusy,
            onApprove: _handleApprove,
            onDeny: _handleDeny,
          ),
        if (_canInject) SkcodeInjectComposer(sid: widget.sid, onInject: _handleInject),
      ],
    );
  }
}

/// Identical shape to SkcodeSessionScreen's private `_ConnectionBanner`
/// (duplicated for the same reason as the rest of this file: no shared
/// private state across the two widgets).
class _SessionColumnConnectionBanner extends StatelessWidget {
  const _SessionColumnConnectionBanner({required this.state});

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
