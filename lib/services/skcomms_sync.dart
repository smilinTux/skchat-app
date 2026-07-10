import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/sovereign_colors.dart';
import '../features/calls/call_provider.dart';
import '../models/call_state.dart';
import '../models/control_signal.dart';
import '../models/conversation.dart';
import '../features/chats/chats_provider.dart';
import 'daemon_service.dart';
import 'pq_conversation_service.dart';
import 'skcomms_client.dart';

/// Daemon connection status.
enum DaemonStatus { connecting, online, offline, error }

class DaemonState {
  const DaemonState({
    this.status = DaemonStatus.connecting,
    this.errorMessage,
    this.lastPollAt,
    this.transportInfo,
  });

  final DaemonStatus status;
  final String? errorMessage;
  final DateTime? lastPollAt;
  final Map<String, dynamic>? transportInfo;

  DaemonState copyWith({
    DaemonStatus? status,
    String? errorMessage,
    DateTime? lastPollAt,
    Map<String, dynamic>? transportInfo,
  }) {
    return DaemonState(
      status: status ?? this.status,
      errorMessage: errorMessage,
      lastPollAt: lastPollAt ?? this.lastPollAt,
      transportInfo: transportInfo ?? this.transportInfo,
    );
  }
}

/// Manages polling the SKComms daemon and syncing messages into Riverpod state.
/// Polls every [pollInterval] (default 5s for foreground, 30s for background).
class SKCommsSyncNotifier extends Notifier<DaemonState> {
  static const _pollInterval = Duration(seconds: 5);
  static const _daemonCheckInterval = Duration(seconds: 15);

  Timer? _pollTimer;
  Timer? _daemonTimer;
  final Set<String> _seenEnvelopeIds = {};

  /// Consecutive failed health checks. The daemon goes briefly unresponsive
  /// while generating an agent reply (~15-20s), so ONE failed /health poll must
  /// not flash the "offline / messages will queue" banner. Require two failures
  /// in a row before flipping offline; any success resets the streak.
  int _healthFailStreak = 0;
  static const _healthFailThreshold = 2;

  @override
  DaemonState build() {
    // Defer polling so Riverpod state is fully initialized before first read.
    Future.microtask(_startPolling);
    ref.onDispose(_stopPolling);
    return const DaemonState();
  }

  void _startPolling() {
    _checkDaemon();
    // NOTE: chat-message ingestion is owned solely by conversation_provider
    // (which polls `skchat history`, both directions). We do NOT ingest chat
    // messages here — a second path created duplicates under different ids and
    // rendered the operator's own message as a green inbound copy. _pollInbox
    // now forwards ONLY the call-request sentinel.
    _pollInbox();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollInbox());
    _daemonTimer = Timer.periodic(_daemonCheckInterval, (_) => _checkDaemon());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _daemonTimer?.cancel();
  }

  /// Check daemon health and update connection status.
  ///
  /// TRUTH RULE: the daemon is ONLINE iff `/health` answers 2xx. The richer
  /// `/api/v1/status` payload is decorative — a slow/failed status fetch must
  /// NOT flip the UI to "offline" (that was the false-offline banner bug). So
  /// status info is fetched best-effort and only ever decorates an already
  /// established online state.
  Future<void> _checkDaemon() async {
    final client = ref.read(skcommsClientProvider);
    bool alive;
    try {
      alive = await client.isAlive();
    } catch (_) {
      alive = false;
    }

    if (!alive) {
      _healthFailStreak++;
      // Debounce: an ESTABLISHED online state only flips offline after
      // repeated failures, so the brief unresponsiveness during reply
      // generation doesn't flash the banner. Any other state (connecting on
      // cold start, already offline, error) reflects the truth immediately:
      // a dead daemon must not sit on "connecting" for a whole check
      // interval before the banner appears.
      if (state.status != DaemonStatus.online ||
          _healthFailStreak >= _healthFailThreshold) {
        state = state.copyWith(status: DaemonStatus.offline);
      }
      return;
    }
    _healthFailStreak = 0;

    // Health is good → online. Decorate with transport info best-effort.
    Map<String, dynamic>? statusInfo;
    try {
      statusInfo = await client.getStatus();
    } catch (_) {
      statusInfo = null; // non-fatal: still online.
    }
    state = state.copyWith(
      status: DaemonStatus.online,
      errorMessage: null,
      lastPollAt: DateTime.now(),
      transportInfo: statusInfo,
    );
  }

  /// Poll inbox for **call-request sentinels only**.
  ///
  /// Chat-message ingestion is owned solely by [ConversationNotifier] (which
  /// polls `skchat history`, both directions). If we also dispatched inbox
  /// messages here they would be re-injected as `isOutbound: false` — producing
  /// a green inbound duplicate of the operator's own message AND a second copy
  /// of every agent reply. So this path now forwards ONLY `__CALL_REQUEST__`
  /// envelopes and drops all normal chat traffic.
  Future<void> _pollInbox() async {
    if (state.status == DaemonStatus.offline) return;

    final client = ref.read(skcommsClientProvider);
    try {
      final messages = await client.getInbox();
      for (final msg in messages) {
        // Only call sentinels travel this path; chat messages are owned by
        // ConversationNotifier and must not be ingested twice.
        if (!msg.content.startsWith('__CALL_REQUEST__:')) continue;
        if (_seenEnvelopeIds.contains(msg.envelopeId)) continue;
        _seenEnvelopeIds.add(msg.envelopeId);
        _dispatchIncoming(msg);
      }
      // A successful poll only refreshes the heartbeat timestamp; it does NOT
      // assert "online". Online/offline is owned authoritatively by
      // _checkDaemon (health-gated), so the inbox poll cannot race it into a
      // false-online (or, by symmetry, a false-offline) state.
      if (state.status == DaemonStatus.online) {
        state = state.copyWith(lastPollAt: DateTime.now());
      }
    } catch (e) {
      // Don't flip status to offline on a single poll failure.
    }
  }

  /// Send a message via the skchat CLI (primary, native), falling back to HTTP.
  ///
  /// On the web there is no local CLI, so the HTTP contract path is the real
  /// send. The contract returns the persisted user turn AND the agent's reply;
  /// we surface them on the [SendResult] so the conversation can render the
  /// reply bubble immediately (see [SendResult.echoedMessage] / [reply]).
  ///
  /// Returns the [SendResult] on the HTTP path (carrying the reply), or a
  /// synthetic CLI result on the native path, or null on complete failure.
  Future<SendResult?> sendMessage({
    required String peerId,
    required String content,
    String? threadId,
    String? inReplyTo,
    String? contentType,
    Map<String, dynamic>? rich,
  }) async {
    // Primary: skchat CLI — local store + transport delivery (native only).
    final daemon = ref.read(daemonServiceProvider);
    final cliResult = await daemon.sendMessage(
      recipient: peerId,
      content: content,
      threadId: threadId,
      replyTo: inReplyTo,
    );
    if (cliResult.success) {
      // CLI stored + delivered locally; the conversation poll picks up both the
      // echo and the reply from `skchat history`. No contract reply to surface.
      return const SendResult(delivered: true, envelopeId: '');
    }

    // Fallback (and the sole path on web): SKComms HTTP contract send.
    //
    // PQC Q5: if the peer advertises a hybrid prekey AND this device has a
    // keypair, seal the body into a `pqdm1:` token (hybrid-pq). Otherwise the
    // body is returned unchanged (classical path, byte-for-byte). Control
    // sentinels are never sealed (sealOutgoing passes `__…` through).
    final pq = ref.read(pqConversationServiceProvider);
    final wireContent = await pq.sealOutgoing(peerId, content);

    final client = ref.read(skcommsClientProvider);
    try {
      final result = await client.sendMessage(
        recipient: peerId,
        message: wireContent,
        threadId: threadId,
        inReplyTo: inReplyTo,
        contentType: contentType,
        rich: rich,
      );
      return result.delivered ? result : null;
    } catch (_) {
      return null;
    }
  }

  /// Send an emoji reaction to a peer over the normal transport.
  ///
  /// Encoded as a `__REACT__:{json}` control sentinel (see [ReactionSignal]).
  /// The receiver folds it into the target message's reactions map. Persisted,
  /// because it rides the same `skchat send` path as ordinary messages.
  Future<void> sendReaction({
    required String peerId,
    required String targetMessageId,
    required String emoji,
    String action = 'add',
    String? me,
  }) async {
    // Contract endpoint first (same-origin webui). Best-effort: the daemon may
    // be an older build without /api/v1/react, in which case we still deliver
    // the reaction over the sentinel path so the peer sees it.
    final client = ref.read(skcommsClientProvider);
    var viaHttp = false;
    try {
      viaHttp = await client.react(
        conversationId: peerId,
        messageId: targetMessageId,
        emoji: emoji,
        op: action == 'remove' ? 'remove' : 'add',
      );
    } catch (_) {
      viaHttp = false;
    }
    if (viaHttp) return;
    final body = ReactionSignal(
      targetId: targetMessageId,
      emoji: emoji,
      action: action,
      sender: me,
    ).encode();
    await sendMessage(peerId: peerId, content: body);
  }

  /// Edit a previously-sent message. Tries POST /api/v1/edit first, then falls
  /// back to the `__EDIT__` sentinel so the peer's copy updates too.
  Future<void> sendEdit({
    required String peerId,
    required String targetMessageId,
    required String body,
  }) async {
    final client = ref.read(skcommsClientProvider);
    var viaHttp = false;
    try {
      viaHttp = await client.edit(messageId: targetMessageId, body: body);
    } catch (_) {
      viaHttp = false;
    }
    if (viaHttp) return;
    final sentinel =
        EditSignal(targetId: targetMessageId, body: body).encode();
    await sendMessage(peerId: peerId, content: sentinel);
  }

  /// Send a delivery/read receipt for a message. POST /api/v1/receipt first,
  /// then the `__RECEIPT__` sentinel fallback. Best-effort, never throws.
  Future<void> sendReceipt({
    required String peerId,
    required String targetMessageId,
    required String kind,
    String? me,
  }) async {
    final client = ref.read(skcommsClientProvider);
    var viaHttp = false;
    try {
      viaHttp = await client.receipt(
        conversationId: peerId,
        messageId: targetMessageId,
        kind: kind,
      );
    } catch (_) {
      viaHttp = false;
    }
    if (viaHttp) return;
    final sentinel =
        ReceiptSignal(targetId: targetMessageId, kind: kind, sender: me)
            .encode();
    try {
      await sendMessage(peerId: peerId, content: sentinel);
    } catch (_) {
      // Receipts are best-effort.
    }
  }

  /// Send an ephemeral typing signal to a peer (best-effort).
  ///
  /// Encoded as a `__TYPING__:{json}` control sentinel (see [TypingSignal]).
  /// Not persisted as a visible message; the receiver only flips a transient
  /// "is composing" flag. Failures are swallowed — typing is non-critical.
  Future<void> sendTyping({
    required String peerId,
    bool start = true,
  }) async {
    final body = TypingSignal(state: start ? 'start' : 'stop').encode();
    try {
      await sendMessage(peerId: peerId, content: body);
    } catch (_) {
      // Typing is best-effort; never surface an error.
    }
  }

  /// Broadcast presence online.
  Future<void> broadcastOnline() async {
    final client = ref.read(skcommsClientProvider);
    try {
      await client.updatePresence(status: 'online');
    } catch (_) {}
  }

  // ── Routing incoming messages into state ──────────────────────────────────

  void _dispatchIncoming(InboxMessage msg) {
    // This path now carries ONLY call-request sentinels (see _pollInbox).
    // Chat messages are owned solely by ConversationNotifier's history poll;
    // dispatching them here would create inbound duplicates.
    if (msg.content.startsWith('__CALL_REQUEST__:')) {
      _handleIncomingCallRequest(msg);
    }
  }

  void _handleIncomingCallRequest(InboxMessage msg) {
    // Derive call type from sentinel suffix: __CALL_REQUEST__:video or :voice
    final suffix = msg.content.split(':').elementAtOrNull(1) ?? 'voice';
    final callType = suffix == 'video' ? CallType.video : CallType.voice;

    // Look up conversation for display name and soul color.
    final chats = ref.read(chatsProvider);
    final conv = chats.cast<Conversation?>().firstWhere(
          (c) => c?.peerId == msg.sender,
          orElse: () => null,
        );

    ref.read(callProvider.notifier).incomingCall(
      peerId: msg.sender,
      peerName: conv?.displayName ?? msg.sender,
      peerSoulColor: conv?.resolvedSoulColor ??
          SovereignColors.fromFingerprint(msg.sender),
      type: callType,
    );
  }
}

final skcommsSyncProvider =
    NotifierProvider<SKCommsSyncNotifier, DaemonState>(SKCommsSyncNotifier.new);
