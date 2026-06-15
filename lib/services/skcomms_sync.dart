import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/sovereign_colors.dart';
import '../features/calls/call_provider.dart';
import '../models/call_state.dart';
import '../models/conversation.dart';
import '../features/chats/chats_provider.dart';
import 'daemon_service.dart';
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
  Future<void> _checkDaemon() async {
    final client = ref.read(skcommsClientProvider);
    try {
      final alive = await client.isAlive();
      if (alive) {
        final statusInfo = await client.getStatus();
        state = state.copyWith(
          status: DaemonStatus.online,
          errorMessage: null,
          lastPollAt: DateTime.now(),
          transportInfo: statusInfo,
        );
      } else {
        state = state.copyWith(status: DaemonStatus.offline);
      }
    } catch (e) {
      state = state.copyWith(
        status: DaemonStatus.offline,
        errorMessage: e.toString(),
      );
    }
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
      state = state.copyWith(
        status: DaemonStatus.online,
        lastPollAt: DateTime.now(),
      );
    } catch (e) {
      // Don't flip status to offline on a single poll failure.
    }
  }

  /// Send a message via the skchat CLI (primary), falling back to HTTP.
  ///
  /// The CLI path stores the message locally AND delivers via SKComms transport.
  /// Returns the envelope ID (from HTTP) or a CLI-generated token on success,
  /// null on complete failure.
  Future<String?> sendMessage({
    required String peerId,
    required String content,
    String? threadId,
    String? inReplyTo,
  }) async {
    // Primary: skchat CLI — local store + transport delivery.
    final daemon = ref.read(daemonServiceProvider);
    final cliResult = await daemon.sendMessage(
      recipient: peerId,
      content: content,
    );
    if (cliResult.success) {
      // Return a synthetic ID so callers can track the message.
      return 'cli_${DateTime.now().millisecondsSinceEpoch}';
    }

    // Fallback: SKComms HTTP (transport only, no local store).
    final client = ref.read(skcommsClientProvider);
    try {
      final result = await client.sendMessage(
        recipient: peerId,
        message: content,
        threadId: threadId,
        inReplyTo: inReplyTo,
      );
      return result.delivered ? result.envelopeId : null;
    } catch (_) {
      return null;
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
