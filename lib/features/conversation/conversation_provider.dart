import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/message_repository.dart';
import '../../services/pq_conversation_service.dart';
import '../../services/pq_dm_codec.dart';
import '../../models/chat_message.dart';
import '../../models/control_signal.dart';
import '../../models/conversation.dart';
import '../../services/daemon_service.dart';
import '../../services/skcomms_client.dart';
import '../../services/skcomms_sync.dart';
import '../../core/chat_text.dart';
import '../chats/chats_provider.dart';
import 'message_dedup.dart';

/// Holds the message list for a single conversation (identified by peerId).
/// Loads persisted messages from Hive first, then tries to fetch from the
/// SKComms daemon for any new messages not yet persisted.
class ConversationNotifier extends FamilyNotifier<List<ChatMessage>, String> {
  Timer? _pollTimer;

  /// Ids of reaction/edit/receipt sentinels already folded into state, so
  /// re-polling the same history (these persist) doesn't double-apply them.
  final Set<String> _appliedControlIds = {};

  /// Clears the transient "is composing" flag after an inbound typing-start
  /// that isn't followed by a stop (sender crashed, message dropped, etc.).
  Timer? _typingClearTimer;

  /// The local operator's short identity (reaction/receipt attribution).
  String get _me {
    final id = ref.read(daemonServiceProvider).localIdentity;
    return id != null ? normalizePeerKey(id) : 'me';
  }

  @override
  List<ChatMessage> build(String peerId) {
    _loadPersistedThenDaemon(peerId);
    // PQC Q5: prefetch the peer's hybrid prekey + prime the own-outbound
    // plaintext cache the moment the conversation OPENS, so (a) sealing at send
    // time uses a cached bundle and doesn't race a busy webui (BUG 2), and (b)
    // the first history poll can resolve our own sent tokens to plaintext
    // synchronously (BUG 1). If the peer is hybrid the badge can show up front.
    _primePqForConversation(peerId);
    // This provider is the SINGLE source of conversation messages: it polls the
    // full thread (`skchat history`, both directions) on a timer. skcomms_sync
    // no longer dispatches chat messages here (that caused multi-path dups /
    // wrong-side rendering). New agent replies appear via this poll.
    _pollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _fetchFromDaemon(peerId),
    );
    ref.onDispose(() {
      _pollTimer?.cancel();
      _typingClearTimer?.cancel();
    });
    return [];
  }

  /// Prefetch the peer's prekey bundle on conversation open, then invalidate the
  /// PQ badge so the header re-reads the (possibly now hybrid) self-report. (Own
  /// outbound now renders from our own `pqdm2:` slot, so there is no plaintext
  /// cache to hydrate.)
  Future<void> _primePqForConversation(String peerId) async {
    // PQC is a best-effort DM feature: on a device where the PQC backend is
    // unavailable (e.g. liboqs is not installed, which throws
    // 'sk_pqc: could not load liboqs' the moment pqConversationServiceProvider
    // is read), priming must degrade silently. Without this guard the read
    // threw straight through ConversationNotifier.build, so ConversationScreen
    // rendered Flutter's ErrorWidget (a grey box in release) in place of the
    // app bar. Swallow any priming failure so the conversation still opens
    // (just without the PQ prefetch / hybrid badge).
    try {
      final pq = ref.read(pqConversationServiceProvider);
      final peerShort = normalizePeerKey(peerId);
      await pq.prefetchPeer(peerShort);
      ref.invalidate(conversationPqStateProvider(peerShort));
    } catch (_) {
      // No PQ priming on this device; the conversation renders normally.
    }
  }

  /// A client-temp id is an optimistic local echo's id: the composer assigns
  /// `'${DateTime.now().millisecondsSinceEpoch}'` (all digits) at send time, and
  /// synthetic bubbles use a conventional `temp`-prefixed id. A persisted server
  /// message always carries a UUID (hyphenated hex, never all-digits, never
  /// `temp`-prefixed). This is what distinguishes an un-persisted optimistic
  /// bubble from its server copy, and it is what keeps two distinct server sends
  /// of identical text from being collapsed into each other.
  static bool _isClientTempId(String id) =>
      int.tryParse(id) != null || id.startsWith('temp');

  /// The optimistic local echoes currently in state: outbound bubbles inserted
  /// at send time, still carrying their client-temp id. These are the ONLY rows
  /// a freshly-ingested server message may reconcile against by content (the
  /// author device's own echo vs its server copy). Seeding the content match
  /// from persisted server ids instead was the sibling-device drop bug: a
  /// second distinct send of the same text (`reply purple`) matched the first
  /// and vanished. Sibling devices carry no optimistic echo, so this list is
  /// empty there and every distinct-id server message renders.
  List<ChatMessage> _optimisticOutbound() => [
        for (final m in state)
          if (m.isOutbound && !m.pqLocked && _isClientTempId(m.id)) m,
      ];

  /// Does an incoming server message reconcile an optimistic bubble? True iff it
  /// is outbound and some still-unmatched optimistic echo in [pending] shares
  /// its content within [kReconcileWindow]. The matched echo is consumed so one
  /// optimistic bubble reconciles at most one server copy (a genuine second send
  /// of the same text still renders). Only same-instant optimistic+server pairs
  /// collapse; distinct server sends never do (they are not in [pending]).
  static bool _reconcilesOptimistic(
    List<ChatMessage> pending,
    String body,
    bool isOutbound,
    DateTime ts,
  ) {
    if (!isOutbound) return false;
    final idx = pending.indexWhere((o) =>
        o.content == body &&
        o.timestamp.difference(ts).abs() <= kReconcileWindow);
    if (idx < 0) return false;
    pending.removeAt(idx);
    return true;
  }

  /// Remove duplicate renderings: same id, OR an optimistic bubble collapsed
  /// against its own server copy (same content+direction within
  /// [kReconcileWindow], where at LEAST ONE side is a client-temp id).
  ///
  /// The client-temp guard is load-bearing: two distinct server ids are two
  /// distinct sends and BOTH must render even when the text is identical, since
  /// a sibling (non-authoring) device holds only the server copies and has no
  /// optimistic echo to fold them into. Collapsing them by content alone dropped
  /// the operator's own repeated message on every device but the author's.
  ///
  /// A [ChatMessage.pqLocked] placeholder is deduped by id ONLY: every locked
  /// copy shares the same placeholder content, so the content branch would
  /// wrongly collapse two genuinely distinct unopenable replies into one (CARD
  /// E, the sender would look silent on the web/PWA leg).
  static List<ChatMessage> _dedup(List<ChatMessage> msgs) {
    final ids = <String>{};
    final out = <ChatMessage>[];
    for (final m in msgs) {
      if (!ids.add(m.id)) continue;
      final near = !m.pqLocked &&
          out.any((o) =>
              !o.pqLocked &&
              o.content == m.content &&
              o.isOutbound == m.isOutbound &&
              (_isClientTempId(o.id) || _isClientTempId(m.id)) &&
              o.timestamp.difference(m.timestamp).abs() <= kReconcileWindow);
      if (near) continue;
      out.add(m);
    }
    return out;
  }

  Future<void> _loadPersistedThenDaemon(String peerId) async {
    final repo = ref.read(messageRepositoryProvider);

    // Instant load from Hive (deduped, the cache can hold dup saves).
    final persisted = await repo.getMessages(peerId);
    if (persisted.isNotEmpty) {
      state = _dedup(persisted);
    }

    // Then try the daemon for fresh data.
    await _fetchFromDaemon(peerId);
  }

  /// Resolve a hybrid-sealed (`pqdm1:` / `pqdm2:`) token to display text + the
  /// direction it should render.
  ///
  /// PQC Q5: with multi-device fanout an own-outbound `pqdm2:` DM carries THIS
  /// device's own slot, so [PqConversationService.openIncomingDetailed] opens it
  /// straight from our key and reports `mine == true` (render as OUTBOUND),
  /// independent of the unreliable directionality guess. A genuine inbound is
  /// opened with our private key. A token this device cannot open reports
  /// `opened == false` and renders as a locked placeholder.
  /// Returns `(text, isOutbound, locked, quotedText, quotedSender, quotedId)`.
  /// `text == null` means drop; `locked` marks a sealed reply this device could
  /// NOT open; it still renders (as a visible placeholder) but MUST be deduped
  /// by id only (see [ChatMessage.pqLocked]). The quoted_* fields carry a
  /// cross-device reply-quote unwrapped from the sealed `skq1:` envelope (card
  /// 5a19f848); they are null unless the opened body wrapped a quote.
  Future<
      ({
        String? text,
        bool isOutbound,
        bool locked,
        String? quotedText,
        String? quotedSender,
        String? quotedId,
      })> _resolvePqToken(
    String token,
    String peerShort, {
    required bool isOutboundGuess,
  }) async {
    final pq = ref.read(pqConversationServiceProvider);
    final r = await pq.openIncomingDetailed(peerShort, token);
    ref.invalidate(conversationPqStateProvider(peerShort));
    return (
      text: r.text,
      isOutbound: r.mine ? true : isOutboundGuess,
      locked: r.mine ? false : !r.opened,
      quotedText: r.quotedText,
      quotedSender: r.quotedSender,
      quotedId: r.quotedId,
    );
  }

  /// Fetch conversation history from the skchat local store via CLI.
  ///
  /// Calls `skchat history <peer> --json` and filters messages by [peerId].
  /// Folds reaction / typing / edit / receipt sentinels into UI state rather
  /// than rendering them. Merges into Hive-persisted state without duplicates.
  Future<void> _fetchFromDaemon(String peerId) async {
    final daemon = ref.read(daemonServiceProvider);
    final repo = ref.read(messageRepositoryProvider);

    // Primary: skchat CLI conversation history.
    try {
      final cliMessages = await daemon.getConversation(peerId, limit: 100);
      if (cliMessages.isNotEmpty) {
        final localId = daemon.localIdentity;
        final localShort =
            localId != null ? normalizePeerKey(localId) : null;
        final peerShort = normalizePeerKey(peerId);

        final existing = state.map((m) => m.id).toSet();
        // Distinct server ids are distinct sends and ALL must render (a sibling
        // device holds only these). The content match is reserved SOLELY for
        // folding an optimistic bubble into its own server copy, so seed it from
        // the un-persisted optimistic echoes only, never from server ids.
        final pendingOptimistic = _optimisticOutbound();
        final fresh = <ChatMessage>[];

        for (final m in cliMessages) {
          final senderShort = normalizePeerKey(m.sender);
          var isOutbound =
              localShort != null && senderShort == localShort;
          final msgPeerId =
              isOutbound ? normalizePeerKey(m.recipient) : senderShort;
          // Only include messages that belong to this conversation.
          if (msgPeerId != peerShort) continue;

          // PQC Q5: resolve a hybrid-sealed token (`pqdm1:` single-recipient or
          // `pqdm2:` multi-device fanout). Own-outbound opens from our OWN slot
          // (pqdm2) and renders as OUTBOUND; an inbound token is opened with our
          // key. Never shown as ciphertext. A token this device can't open
          // renders as a locked placeholder (CARD E), deduped by id.
          var cliBody = m.content;
          var pqLocked = false;
          // Cross-device reply-quote unwrapped from the sealed `skq1:` envelope
          // (card 5a19f848); null unless this sealed body carried a quote.
          String? cliQuotedText;
          String? cliQuotedSender;
          String? cliQuotedId;
          if (PqDmCodec.isHybridToken(cliBody) ||
              cliBody.startsWith(PqDmCodec.pqdm2Prefix)) {
            final r = await _resolvePqToken(
              cliBody,
              peerShort,
              isOutboundGuess: isOutbound,
            );
            if (r.text == null) continue;
            cliBody = r.text!;
            isOutbound = r.isOutbound;
            pqLocked = r.locked;
            cliQuotedText = r.quotedText;
            cliQuotedSender = r.quotedSender;
            cliQuotedId = r.quotedId;
          }

          // Reaction sentinel (__REACT__), fold into the target message's
          // reactions map instead of rendering. Skip our own outbound echoes
          // (we applied them optimistically) and already-applied ones.
          final react = ReactionSignal.parse(cliBody);
          if (react != null) {
            if (!isOutbound && _appliedControlIds.add(m.id)) {
              _applyReaction(react, fallbackSender: senderShort);
            }
            continue;
          }

          // Edit sentinel (__EDIT__), replace the target's body + mark edited.
          final edit = EditSignal.parse(cliBody);
          if (edit != null) {
            if (!isOutbound && _appliedControlIds.add(m.id)) {
              _applyEdit(edit, at: m.timestamp);
            }
            continue;
          }

          // Receipt sentinel (__RECEIPT__), fold into delivered/read lists.
          final receipt = ReceiptSignal.parse(cliBody);
          if (receipt != null) {
            if (!isOutbound && _appliedControlIds.add(m.id)) {
              _applyReceipt(receipt, fallbackSender: senderShort);
            }
            continue;
          }

          // Typing sentinel (__TYPING__), ephemeral; flip the peer's
          // "is composing" flag. Never persisted or shown. Ignore our own.
          final typing = TypingSignal.parse(cliBody);
          if (typing != null) {
            if (!isOutbound) _handleIncomingTyping(msgPeerId, typing);
            continue;
          }

          if (existing.contains(m.id)) continue;
          // Skip non-displayable traffic (control envelopes, prompt-echoes,
          // delivery-receipt UUIDs) so the thread stays clean.
          if (displayTextFor(cliBody) == null) continue;

          // Fold this server copy into an optimistic bubble ONLY (author's own
          // echo). Locked placeholders and distinct-id server sends are never
          // content-collapsed: they render and are deduped by id (guarded above).
          if (!pqLocked &&
              _reconcilesOptimistic(
                pendingOptimistic,
                cliBody,
                isOutbound,
                m.timestamp,
              )) {
            continue;
          }

          fresh.add(ChatMessage(
            id: m.id,
            peerId: msgPeerId,
            content: cliBody,
            timestamp: m.timestamp,
            isOutbound: isOutbound,
            conversationId: peerShort,
            sender: m.sender,
            threadId: m.threadId,
            deliveryStatus: isOutbound ? 'sent' : 'delivered',
            pqLocked: pqLocked,
            quotedText: cliQuotedText,
            quotedSender: cliQuotedSender,
            quotedId: cliQuotedId,
          ));
        }

        if (fresh.isNotEmpty) {
          final merged = _dedup([...state, ...fresh]);
          merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          state = merged;
          for (final msg in fresh) {
            // Don't persist locked placeholders: this device never opened them,
            // so a future session that HAS the key can re-fetch and open fresh.
            if (!msg.pqLocked) await repo.saveMessage(msg);
          }
          // Mark freshly-arrived inbound messages as read (best-effort).
          _sendReadReceiptsFor(peerId, fresh);
        }
        return;
      }
    } catch (_) {
      // CLI unavailable, fall through to HTTP fallback.
    }

    // Fallback: SKComms HTTP conversation history (the ONLY path on web, where
    // there is no local `skchat` CLI to spawn). Calls
    // GET /api/v1/conversations/{peer_id} with the FULL peer key the backend
    // stores under (the fqid, e.g. `lumina@chef.skworld`), NOT the normalized
    // short name, then folds the returned contract messages into state.
    final client = ref.read(skcommsClientProvider);
    try {
      // Gate on health first (cheap) so an unreachable daemon short-circuits
      // before the heavier history fetch.
      final alive = await client.isAlive();
      if (!alive) return;
      final raw = await client.getConversationFull(peerId);
      if (raw.isEmpty) return;
      await _ingestContractMessages(peerId, raw);
    } catch (_) {
      // Daemon offline / endpoint missing, keep Hive data.
    }
  }

  /// Fold a list of contract message maps (from GET /api/v1/conversations/{id}
  /// or the `/api/v1/send` reply) into conversation state.
  ///
  /// Directionality is derived by comparing the message `sender` against the
  /// local operator identity (the contract carries no `is_outbound`). Control
  /// sentinels (react/edit/receipt/typing) are folded, not rendered. Dedups by
  /// id and by content+direction so a re-poll never doubles a bubble.
  Future<void> _ingestContractMessages(
    String peerId,
    List<Map<String, dynamic>> raw,
  ) async {
    final daemon = ref.read(daemonServiceProvider);
    final repo = ref.read(messageRepositoryProvider);
    final localId = daemon.localIdentity;
    final localShort = localId != null ? normalizePeerKey(localId) : null;
    final peerShort = normalizePeerKey(peerId);

    final existing = state.map((m) => m.id).toSet();
    // Distinct server ids are distinct sends and ALL must render (a sibling
    // device holds only these). The content match is reserved SOLELY for folding
    // an optimistic bubble into its own server copy, so seed it from the
    // un-persisted optimistic echoes only, never from server ids.
    final pendingOptimistic = _optimisticOutbound();
    final fresh = <ChatMessage>[];

    for (final json in raw) {
      final parsed = ChatMessage.fromJson(json);
      final senderShort =
          parsed.sender != null ? normalizePeerKey(parsed.sender!) : '';
      // Outbound iff WE authored it; otherwise it's the peer's (inbound).
      var isOutbound = localShort != null && senderShort == localShort;
      var body = parsed.content;
      var pqLocked = false;

      // PQC Q5: an inbound `pqdm1:` / `pqdm2:` token is a hybrid-sealed DM, open
      // it with this device's hybrid private key (flips the convo `hybrid-pq`).
      // Our own OUTBOUND pqdm2 copy carries our own device slot, so it opens
      // straight from our key and renders as outbound, never as ciphertext,
      // deduped by content. A token this device cannot open renders as a locked
      // placeholder (CARD E, the web/PWA reduced-assurance leg), deduped by id so
      // it is never silent.
      if (PqDmCodec.isHybridToken(body) ||
          body.startsWith(PqDmCodec.pqdm2Prefix)) {
        final r = await _resolvePqToken(
          body,
          peerShort,
          isOutboundGuess: isOutbound,
        );
        if (r.text == null) continue;
        body = r.text!;
        isOutbound = r.isOutbound;
        pqLocked = r.locked;
      }

      // Control sentinels, fold into target state instead of rendering.
      final react = ReactionSignal.parse(body);
      if (react != null) {
        if (!isOutbound && _appliedControlIds.add(parsed.id)) {
          _applyReaction(react, fallbackSender: senderShort);
        }
        continue;
      }
      final edit = EditSignal.parse(body);
      if (edit != null) {
        if (!isOutbound && _appliedControlIds.add(parsed.id)) {
          _applyEdit(edit, at: parsed.timestamp);
        }
        continue;
      }
      final receipt = ReceiptSignal.parse(body);
      if (receipt != null) {
        if (!isOutbound && _appliedControlIds.add(parsed.id)) {
          _applyReceipt(receipt, fallbackSender: senderShort);
        }
        continue;
      }
      final typing = TypingSignal.parse(body);
      if (typing != null) {
        if (!isOutbound) _handleIncomingTyping(peerShort, typing);
        continue;
      }

      if (existing.contains(parsed.id)) continue;
      if (displayTextFor(body) == null) continue;
      // Fold this server copy into an optimistic bubble ONLY (author's own echo).
      // Locked placeholders and distinct-id server sends are never
      // content-collapsed: they render and are deduped by id (guarded above).
      if (!pqLocked &&
          _reconcilesOptimistic(
            pendingOptimistic,
            body,
            isOutbound,
            parsed.timestamp,
          )) {
        continue;
      }

      fresh.add(parsed.copyWith(
        peerId: peerShort,
        content: body,
        isOutbound: isOutbound,
        conversationId: peerShort,
        deliveryStatus: isOutbound ? 'sent' : 'delivered',
        pqLocked: pqLocked,
      ));
    }

    if (fresh.isEmpty) return;
    final merged = _dedup([...state, ...fresh]);
    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    state = merged;
    for (final msg in fresh) {
      // Don't persist locked placeholders: this device never opened them, so a
      // future session that HAS the key can re-fetch and open fresh.
      if (!msg.pqLocked) await repo.saveMessage(msg);
    }
    _sendReadReceiptsFor(peerId, fresh);
  }

  /// Append the contract `message` (echoed user turn) and `reply` (agent reply)
  /// returned by POST /api/v1/send. Called right after a send on web so the
  /// reply bubble appears immediately rather than 4s later on the next poll.
  /// The optimistic user bubble is deduped away by content+direction.
  Future<void> ingestSendResponse(
    String peerId, {
    Map<String, dynamic>? echoedMessage,
    Map<String, dynamic>? reply,
  }) async {
    final batch = <Map<String, dynamic>>[
      ?echoedMessage,
      ?reply,
    ];
    if (batch.isEmpty) return;
    await _ingestContractMessages(peerId, batch);
  }

  Future<void> addMessage(ChatMessage message) async {
    // Dedup: skip if we already have this message (same id), or a near-identical
    // one (same content + direction within a few seconds). Covers both the
    // Hive+daemon merge re-adding a message and the bridge delivering a reply
    // more than once.
    final isDup = state.any((m) =>
        m.id == message.id ||
        (m.content == message.content &&
            m.isOutbound == message.isOutbound &&
            (m.timestamp.difference(message.timestamp).inSeconds).abs() < 10));
    if (isDup) return;

    state = [...state, message];

    // Persist to Hive.
    final repo = ref.read(messageRepositoryProvider);
    await repo.saveMessage(message);

    // Update the conversation list with the new last message.
    ref.read(chatsProvider.notifier).updateConversation(
      ref
          .read(chatsProvider)
          .firstWhere(
            (c) => c.peerId == message.peerId,
            orElse: () => Conversation(
              peerId: message.peerId,
              displayName: message.peerId,
              lastMessage: message.content,
              lastMessageTime: message.timestamp,
            ),
          )
          .copyWith(
            lastMessage: message.content,
            lastMessageTime: message.timestamp,
            lastDeliveryStatus: 'sent',
          ),
    );
  }

  Future<void> updateDeliveryStatus(String messageId, String status) async {
    state = [
      for (final m in state)
        if (m.id == messageId) m.copyWith(deliveryStatus: status) else m,
    ];

    final repo = ref.read(messageRepositoryProvider);
    await repo.updateDeliveryStatus(arg, messageId, status);
  }

  /// Fold a reaction into the target message's `reactionSenders` map.
  ///
  /// Add appends [sender] to the emoji's sender-list (idempotent); remove drops
  /// it. The emoji entry is removed when its sender-list empties. Persists the
  /// updated message so the reaction survives an app restart.
  void _applyReaction(ReactionSignal react, {String? fallbackSender}) {
    final who = react.sender ?? fallbackSender ?? '?';
    var changed = false;
    final updated = <ChatMessage>[];
    for (final m in state) {
      if (m.id != react.targetId) {
        updated.add(m);
        continue;
      }
      final next = {
        for (final e in m.reactionSenders.entries)
          e.key: List<String>.from(e.value),
      };
      final list = next.putIfAbsent(react.emoji, () => <String>[]);
      if (react.isAdd) {
        if (!list.contains(who)) list.add(who);
      } else {
        list.remove(who);
        if (list.isEmpty) next.remove(react.emoji);
      }
      updated.add(m.copyWith(reactionSenders: next));
      changed = true;
    }
    if (!changed) return;
    state = updated;
    final repo = ref.read(messageRepositoryProvider);
    final target = state.firstWhere((m) => m.id == react.targetId);
    repo.saveMessage(target);
  }

  /// Replace a message's body and mark it edited (folds an incoming __EDIT__).
  void _applyEdit(EditSignal edit, {DateTime? at}) {
    var changed = false;
    final updated = <ChatMessage>[];
    for (final m in state) {
      if (m.id != edit.targetId) {
        updated.add(m);
        continue;
      }
      updated.add(m.copyWith(
        content: edit.body,
        editedAt: at ?? DateTime.now(),
        editHistory: [...m.editHistory, m.content],
      ));
      changed = true;
    }
    if (!changed) return;
    state = updated;
    final repo = ref.read(messageRepositoryProvider);
    repo.saveMessage(state.firstWhere((m) => m.id == edit.targetId));
  }

  /// Fold a delivery/read receipt into the target message's receipt lists.
  void _applyReceipt(ReceiptSignal receipt, {String? fallbackSender}) {
    final who = receipt.sender ?? fallbackSender ?? '?';
    var changed = false;
    final updated = <ChatMessage>[];
    for (final m in state) {
      if (m.id != receipt.targetId) {
        updated.add(m);
        continue;
      }
      final delivered = List<String>.from(m.receiptsDelivered);
      final read = List<String>.from(m.receiptsRead);
      if (receipt.kind == 'read') {
        if (!read.contains(who)) read.add(who);
        if (!delivered.contains(who)) delivered.add(who);
      } else {
        if (!delivered.contains(who)) delivered.add(who);
      }
      // Mirror onto the simple delivery-status string the bubble already reads.
      final status = read.isNotEmpty
          ? 'read'
          : (delivered.isNotEmpty ? 'delivered' : m.deliveryStatus);
      updated.add(m.copyWith(
        receiptsDelivered: delivered,
        receiptsRead: read,
        deliveryStatus: status,
      ));
      changed = true;
    }
    if (!changed) return;
    state = updated;
    final repo = ref.read(messageRepositoryProvider);
    repo.saveMessage(state.firstWhere((m) => m.id == receipt.targetId));
  }

  /// React to a message in this conversation: toggle the operator's reaction
  /// optimistically and send it to the peer (HTTP `/react` then sentinel).
  Future<void> react(String targetMessageId, String emoji) async {
    final me = _me;
    final matches = state.where((m) => m.id == targetMessageId).toList();
    final ChatMessage? target = matches.isEmpty ? null : matches.first;
    final already = target?.reactedBy(emoji, me) ?? false;
    final op = already ? 'remove' : 'add';
    _applyReaction(
      ReactionSignal(
        targetId: targetMessageId,
        emoji: emoji,
        action: op,
        sender: me,
      ),
    );
    await ref.read(skcommsSyncProvider.notifier).sendReaction(
          peerId: arg,
          targetMessageId: targetMessageId,
          emoji: emoji,
          action: op,
          me: me,
        );
  }

  /// Edit an own message: apply locally (optimistic) and send the edit.
  /// The 24h window is enforced by the server; the UI also hides the affordance
  /// for older messages, so this is the belt to that suspenders.
  Future<void> editMessage(String targetMessageId, String newBody) async {
    final trimmed = newBody.trim();
    if (trimmed.isEmpty) return;
    _applyEdit(EditSignal(targetId: targetMessageId, body: trimmed));
    await ref.read(skcommsSyncProvider.notifier).sendEdit(
          peerId: arg,
          targetMessageId: targetMessageId,
          body: trimmed,
        );
  }

  /// Send read receipts for a batch of freshly-arrived inbound messages.
  void _sendReadReceiptsFor(String peerId, List<ChatMessage> fresh) {
    final sync = ref.read(skcommsSyncProvider.notifier);
    final me = _me;
    for (final m in fresh) {
      if (m.isOutbound) continue;
      sync.sendReceipt(
        peerId: peerId,
        targetMessageId: m.id,
        kind: 'read',
        me: me,
      );
    }
  }

  /// Handle an incoming typing sentinel: flip the peer's "is composing" flag.
  /// On 'start', also arm a safety timer to auto-clear if no 'stop' arrives.
  void _handleIncomingTyping(String peerId, TypingSignal typing) {
    final chats = ref.read(chatsProvider.notifier);
    chats.setTyping(peerId, typing: typing.isStart);
    _typingClearTimer?.cancel();
    if (typing.isStart) {
      _typingClearTimer = Timer(const Duration(seconds: 8), () {
        ref.read(chatsProvider.notifier).setTyping(peerId, typing: false);
      });
    }
  }
}

final conversationProvider =
    NotifierProviderFamily<ConversationNotifier, List<ChatMessage>, String>(
      ConversationNotifier.new,
    );
