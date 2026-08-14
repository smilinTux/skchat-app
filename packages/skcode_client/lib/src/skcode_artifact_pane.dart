import "package:flutter/material.dart";

import "skcode_api_client.dart";
import "skcode_digest_tab.dart";
import "skcode_event.dart";
import "skcode_raw_rail.dart";

/// The fallback token minter for a pane built with no [SkcodeArtifactPane.mintToken]
/// (a bare pane in a test, or a host that has not wired the transport layer).
/// Resolving null is the honest answer -- there is no token source -- and the
/// Digest tab renders its "not authorized" state from it rather than pretending
/// a digest is merely missing.
Future<String?> _noSkcodeToken() => Future<String?>.value(null);

/// The artifact pane (card C-7, spec section 7 rev 2): "the pane formerly
/// called the preview pane is now the artifact pane and holds only
/// artifacts (Diff, Digest, Logs, Raw)." Project chat and the transcript
/// are their own surfaces (C-12's four-column layout); this pane never
/// renders either.
///
/// Tabs built here, left to right: **Diff, Digest, Logs, Raw**, with an
/// optional **Chat** tab prepended (see [showChatTab]), matching the spec's
/// "Chat | Diff | Digest | Logs | Raw" order. The Digest tab (card C-9) fetches
/// and renders the skwatchdog published `latest/` artifact
/// ([SkcodeDigestTab]); it owns no data of its own, taking [digestUrl] and
/// [onOpenLink] straight through to that widget.
///
/// ## The Chat tab slot contract (for C-12)
///
/// At four-column widths project chat is its own column and [showChatTab]
/// should be `false`. At sub-four-column widths (three-column, two-column
/// overlay, and narrower) chat collapses into the FIRST tab of this pane
/// (spec section 7): pass `showChatTab: true`. This card only builds the
/// slot: with no [chatSlot] supplied, the Chat tab renders
/// [_ChatSlotPlaceholder], an inert "Chat" empty state. C-12 fills the slot
/// by passing its real chat column widget as [chatSlot]; [chatUnreadCount]
/// drives the tab's unread badge (spec section 7: "with an unread badge"),
/// left at 0 (no badge) until C-12 wires real counts.
///
/// ## The panel-left shadow
///
/// The pane's left edge (its only exposed edge when right-docked) carries
/// [skcodeArtifactPaneShadow], reused with attribution from Buzz's
/// `panel-left` token (github.com/block/buzz, Apache-2.0); see that
/// function's doc comment.
///
/// ## Phone
///
/// [SkcodeArtifactPane.showBottomSheet] presents this pane as a swipe-up
/// bottom sheet, reusing the same shape the app's own drawer sheet uses
/// (`lib/features/shell/app_drawer_sheet.dart`'s `AppDrawerSheet`): a
/// `showModalBottomSheet` with a transparent barrier hosting a
/// `DraggableScrollableSheet`, rounded top corners, and a drag handle. That
/// widget lives one level up in the app package and is unreachable from
/// here (the import gate, `tool/import_gate.sh`, allows only
/// `skworld_module_api`/`flutter`/`dio`/`web_socket_channel`/dart core), so
/// the shape is reproduced with Flutter primitives rather than imported.
class SkcodeArtifactPane extends StatefulWidget {
  const SkcodeArtifactPane({
    super.key,
    required this.events,
    this.showChatTab = false,
    this.chatSlot,
    this.chatUnreadCount = 0,
    this.apiClient,
    this.mintToken,
    this.onAuthRejected,
    this.onOpenLink,
  });

  /// The session's merged, ordered event window (exactly
  /// `SkcodeSessionState.events`): the Diff tab groups its `diff` events per
  /// file, the Raw tab hands the whole list to [SkcodeRawRail] unchanged.
  final List<SkcodeEvent> events;

  /// Whether the collapsed Chat tab is present (see the class doc's slot
  /// contract). `false` at four-column widths, where chat is its own
  /// column.
  final bool showChatTab;

  /// The Chat tab's content once C-12 fills the slot. Ignored when
  /// [showChatTab] is `false`. Null renders [_ChatSlotPlaceholder].
  final Widget? chatSlot;

  /// Unread badge count for the Chat tab (spec section 7: three-column
  /// tier, "with an unread badge"). 0 renders no badge.
  final int chatUnreadCount;

  /// The Digest tab's data source (card C-14a): the shared skcode-hostd
  /// client, forwarded to [SkcodeDigestTab.apiClient]. The digest is a read on
  /// the same authenticated plane as sessions and jobs
  /// (`GET /api/v1/watchdog/digest`, scope `skcode.stream`), so it reuses the
  /// same client rather than opening a second HTTP path of its own. Null (a
  /// bare pane with no transport wired) degrades to the Digest tab's honest
  /// "not authorized" state via [_noSkcodeToken], never a crash.
  final SkcodeApiClient? apiClient;

  /// Mints the `skcode.stream` wire token for the Digest tab (card C-14a),
  /// the same minter the sessions rail uses. Null falls back to
  /// [_noSkcodeToken].
  final Future<String?> Function()? mintToken;

  /// Forwarded to [SkcodeDigestTab.onAuthRejected] (card C-3b's seam): lets a
  /// 401 on the digest re-mint the audience token exactly once and retry.
  final VoidCallback? onAuthRejected;

  /// The Digest tab's deep-link seam (card C-9): forwarded straight to
  /// [SkcodeDigestTab.onOpenLink]. This is how a `skworld://` uri tapped
  /// inside a rendered digest line reaches the shell router, since this
  /// package cannot import host routing (see [SkcodeDigestTab]'s doc
  /// comment for the full contract).
  final void Function(String uri)? onOpenLink;

  /// Presents this pane as a swipe-up bottom sheet (spec section 7,
  /// "PHONE ... artifact tabs via a swipe-up bottom sheet (the app's
  /// existing drawer-sheet gesture)"), mirroring `AppDrawerSheet.show`'s
  /// shape: [showModalBottomSheet] with a transparent barrier, scroll
  /// controlled, hosting a [DraggableScrollableSheet].
  static Future<void> showBottomSheet(
    BuildContext context, {
    required List<SkcodeEvent> events,
    bool showChatTab = false,
    Widget? chatSlot,
    int chatUnreadCount = 0,
    SkcodeApiClient? apiClient,
    Future<String?> Function()? mintToken,
    VoidCallback? onAuthRejected,
    void Function(String uri)? onOpenLink,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SkcodeArtifactBottomSheet(
        events: events,
        showChatTab: showChatTab,
        chatSlot: chatSlot,
        chatUnreadCount: chatUnreadCount,
        apiClient: apiClient,
        mintToken: mintToken,
        onAuthRejected: onAuthRejected,
        onOpenLink: onOpenLink,
      ),
    );
  }

  @override
  State<SkcodeArtifactPane> createState() => _SkcodeArtifactPaneState();
}

/// One artifact tab: a stable identity ([kind]), its label, its icon, and
/// the content builder.
enum _ArtifactTabKind { chat, diff, digest, logs, raw }

class _ArtifactTabSpec {
  const _ArtifactTabSpec({
    required this.kind,
    required this.label,
    required this.icon,
    required this.builder,
  });

  final _ArtifactTabKind kind;
  final String label;
  final IconData icon;
  final WidgetBuilder builder;
}

class _SkcodeArtifactPaneState extends State<SkcodeArtifactPane>
    with SingleTickerProviderStateMixin {
  late TabController _controller;
  late List<_ArtifactTabSpec> _tabs;

  /// Stand-in for a pane built with no [SkcodeArtifactPane.apiClient]. It is
  /// never actually reached: the matching [_noSkcodeToken] fallback resolves
  /// null first, so the Digest tab settles on "not authorized" before any
  /// request is built. It exists only so the tab's [SkcodeDigestTab.apiClient]
  /// can stay non-nullable, which is what keeps a second, optional,
  /// unauthenticated fetch path from creeping back in.
  late final SkcodeApiClient _fallbackApiClient = SkcodeApiClient();

  @override
  void initState() {
    super.initState();
    _tabs = _buildTabs();
    _controller = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void didUpdateWidget(SkcodeArtifactPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showChatTab != widget.showChatTab) {
      // Chat only ever occupies index 0 and Diff/Logs/Raw never reorder
      // relative to each other, so re-locating the previously-focused KIND
      // (not index) in the rebuilt list keeps the same tab focused across
      // the collapse/expand transition. Falls back to 0 for the one case
      // that has no answer: the user was on the Chat tab and it just
      // vanished.
      final previousKind = _tabs[_controller.index].kind;
      final oldController = _controller;
      _tabs = _buildTabs();
      final nextIndex = _tabs.indexWhere((t) => t.kind == previousKind);
      _controller = TabController(
        length: _tabs.length,
        vsync: this,
        initialIndex: nextIndex >= 0 ? nextIndex : 0,
      );
      oldController.dispose();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_ArtifactTabSpec> _buildTabs() {
    return [
      if (widget.showChatTab)
        _ArtifactTabSpec(
          kind: _ArtifactTabKind.chat,
          label: "Chat",
          icon: Icons.forum_outlined,
          builder: (context) =>
              widget.chatSlot ?? const _ChatSlotPlaceholder(),
        ),
      _ArtifactTabSpec(
        kind: _ArtifactTabKind.diff,
        label: "Diff",
        icon: Icons.difference_outlined,
        builder: (context) => _DiffTabView(events: widget.events),
      ),
      _ArtifactTabSpec(
        kind: _ArtifactTabKind.digest,
        label: "Digest",
        icon: Icons.summarize_outlined,
        builder: (context) => SkcodeDigestTab(
          apiClient: widget.apiClient ?? _fallbackApiClient,
          mintToken: widget.mintToken ?? _noSkcodeToken,
          onAuthRejected: widget.onAuthRejected,
          onOpenLink: widget.onOpenLink,
        ),
      ),
      _ArtifactTabSpec(
        kind: _ArtifactTabKind.logs,
        label: "Logs",
        icon: Icons.article_outlined,
        // Jobs/cron-ledger logs are C-8's data (spec section 8: "the Code
        // section is a view, never a store"); this pane only reserves the
        // tab.
        builder: (context) => const _EmptyArtifactState(
          icon: Icons.article_outlined,
          message: "No logs yet",
        ),
      ),
      _ArtifactTabSpec(
        kind: _ArtifactTabKind.raw,
        label: "Raw",
        icon: Icons.data_object,
        builder: (context) => SkcodeRawRail(events: widget.events),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // The shadow lives on its own DecoratedBox with NO background color:
    // a DecoratedBox background painted above a Material occludes that
    // Material's ink splashes (the raw rail's ExpansionTile/ListTile rows
    // need one), so the pane's actual surface color is painted by the
    // inner Material instead, which also gives every descendant (the raw
    // rail included) a proper ink surface to splash against.
    return DecoratedBox(
      key: const Key("skcode-artifact-pane-shadow"),
      decoration: BoxDecoration(boxShadow: skcodeArtifactPaneShadow(context)),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            TabBar(
              controller: _controller,
              isScrollable: true,
              tabs: [
                for (final tab in _tabs)
                  Tab(
                    icon: Icon(tab.icon),
                    child: tab.kind == _ArtifactTabKind.chat &&
                            widget.chatUnreadCount > 0
                        ? Badge(
                            label: Text("${widget.chatUnreadCount}"),
                            child: Text(tab.label),
                          )
                        : Text(tab.label),
                  ),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _controller,
                children: [for (final tab in _tabs) tab.builder(context)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The two-layer negative-x shadow (card C-7, spec section 7: "the artifact
/// pane's left edge gets the two-layer negative-x shadow treatment
/// (hairline + soft lift) ported from Buzz's `panel-left` token").
///
/// Attribution: Buzz's `panel-left` CSS token
/// (github.com/block/buzz, Apache-2.0, Block Inc.). A right-docked surface
/// exposes only its left edge, and a stock (y-offset) elevation shadow
/// casts almost nothing onto that edge, so `panel-left` uses two
/// NEGATIVE-x layers instead of the usual positive-y one:
///
///   * a hairline that draws the boundary itself: CSS `-1px 0 0 0
///     border-color`. This is the layer that "carries dark mode": a
///     pure-black soft shadow (the second layer, below) reads as nothing
///     against a dark surface, so the boundary needs an actually-visible
///     color, not opacity alone. Ported here as the theme's own
///     [ColorScheme.outlineVariant], which is a real, contrasting color in
///     BOTH the light and dark [ThemeData] (never a literal), so the edge
///     reads as docked in both.
///   * a soft layer that carries the lift: CSS `-16px 0 32px -12px` black
///     at low alpha, translated 1:1 to a [BoxShadow] with the same
///     [Offset], `blurRadius`, and `spreadRadius` magnitudes.
///
/// A left-only [Border] cannot do this job (per the card): it tapers out at
/// the pane's rounded corners, where a shadow keeps casting past them.
List<BoxShadow> skcodeArtifactPaneShadow(BuildContext context) {
  final outline = Theme.of(context).colorScheme.outlineVariant;
  return [
    BoxShadow(color: outline, offset: const Offset(-1, 0)),
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.24),
      offset: const Offset(-16, 0),
      blurRadius: 32,
      spreadRadius: -12,
    ),
  ];
}

/// One [ActivityRenderClass.diff] event's latest known stat for one file:
/// added/removed line counts as of the newest `diff` event that named it.
class _DiffFileStat {
  const _DiffFileStat({
    required this.file,
    required this.added,
    required this.removed,
    required this.ts,
    required this.seq,
  });

  final String file;
  final int added;
  final int removed;
  final double ts;
  final int seq;

  bool _newerThan(_DiffFileStat other) {
    if (ts != other.ts) return ts > other.ts;
    return seq > other.seq;
  }
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String? _asFileName(Map<String, dynamic> data) {
  // hostd has not shipped a concrete `diff` payload shape yet (skharness
  // `EventType.DIFF` exists in the enum with no emitter wired as of this
  // card); several plausible key names are tried defensively, mirroring
  // `SkcodeRawRail`'s own `_description` fallback for `tool_call` names.
  final candidate =
      data["file"] ?? data["path"] ?? data["filename"] ?? data["name"];
  if (candidate is String && candidate.isNotEmpty) return candidate;
  return null;
}

/// Groups the LATEST `diff` event per file (card C-7 acceptance: "Diff tab
/// groups the latest diff events per file with add and remove counts").
/// "Latest" is `(ts, seq)` order, matching every other freshness comparison
/// in this package (`skcode_event_merge.dart`). Returned sorted by file
/// path for a stable, scannable list.
List<_DiffFileStat> _groupLatestDiffPerFile(List<SkcodeEvent> events) {
  final perFile = <String, _DiffFileStat>{};
  for (final event in events) {
    if (event.type != "diff") continue;
    final file = _asFileName(event.data);
    if (file == null) continue;
    final stat = _DiffFileStat(
      file: file,
      added: _asInt(
        event.data["added"] ?? event.data["insertions"] ?? event.data["additions"],
      ),
      removed: _asInt(event.data["removed"] ?? event.data["deletions"]),
      ts: event.ts,
      seq: event.seq,
    );
    final existing = perFile[file];
    if (existing == null || stat._newerThan(existing)) {
      perFile[file] = stat;
    }
  }
  final list = perFile.values.toList()
    ..sort((a, b) => a.file.compareTo(b.file));
  return list;
}

class _DiffTabView extends StatelessWidget {
  const _DiffTabView({required this.events});

  final List<SkcodeEvent> events;

  @override
  Widget build(BuildContext context) {
    final stats = _groupLatestDiffPerFile(events);
    if (stats.isEmpty) {
      return const _EmptyArtifactState(
        icon: Icons.difference_outlined,
        message: "No diffs yet",
      );
    }
    return ListView.builder(
      itemCount: stats.length,
      itemBuilder: (context, index) => _DiffFileRow(stat: stats[index]),
    );
  }
}

class _DiffFileRow extends StatelessWidget {
  const _DiffFileRow({required this.stat});

  final _DiffFileStat stat;

  @override
  Widget build(BuildContext context) {
    final monoStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFamily: "monospace");
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              stat.file,
              style: monoStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          // Added/removed counts read as a familiar git-diffstat pair: green
          // for added, red for removed. Domain-meaningful literal colors,
          // same precedent as the write-tone amber pinned in
          // `skcode_tone_style.dart` (spec section 7.1).
          Text(
            "+${stat.added}",
            style: monoStyle?.copyWith(color: Colors.green.shade600),
          ),
          const SizedBox(width: 6),
          Text(
            "-${stat.removed}",
            style: monoStyle?.copyWith(color: Colors.red.shade600),
          ),
        ],
      ),
    );
  }
}

class _EmptyArtifactState extends StatelessWidget {
  const _EmptyArtifactState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).disabledColor;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 8),
          Text(message, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// The Chat tab slot's inert default (see the class doc's slot contract):
/// rendered whenever [SkcodeArtifactPane.showChatTab] is true and
/// [SkcodeArtifactPane.chatSlot] is null. C-12 replaces this by supplying
/// its own widget; nothing here is wired to any chat transport.
class _ChatSlotPlaceholder extends StatelessWidget {
  const _ChatSlotPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const _EmptyArtifactState(
      icon: Icons.forum_outlined,
      message: "Chat",
    );
  }
}

/// The phone presentation (spec section 7, PHONE): reproduces the shape of
/// the app's `AppDrawerSheet` (`lib/features/shell/app_drawer_sheet.dart`,
/// unreachable here per the import gate) with Flutter primitives: a
/// [DraggableScrollableSheet] behind rounded top corners and a drag handle,
/// hosting the same [SkcodeArtifactPane] tabs used on wider panes. The
/// panel-left shadow does not apply here (spec section 7's shadow treatment
/// is for a right-docked vertical edge; this is a bottom sheet with a
/// top edge instead), so this wrapper omits it.
class _SkcodeArtifactBottomSheet extends StatelessWidget {
  const _SkcodeArtifactBottomSheet({
    required this.events,
    required this.showChatTab,
    required this.chatSlot,
    required this.chatUnreadCount,
    this.apiClient,
    this.mintToken,
    this.onAuthRejected,
    this.onOpenLink,
  });

  final List<SkcodeEvent> events;
  final bool showChatTab;
  final Widget? chatSlot;
  final int chatUnreadCount;
  final SkcodeApiClient? apiClient;
  final Future<String?> Function()? mintToken;
  final VoidCallback? onAuthRejected;
  final void Function(String uri)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const _SheetDragHandle(),
              Expanded(
                child: SkcodeArtifactPane(
                  events: events,
                  showChatTab: showChatTab,
                  chatSlot: chatSlot,
                  chatUnreadCount: chatUnreadCount,
                  apiClient: apiClient,
                  mintToken: mintToken,
                  onAuthRejected: onAuthRejected,
                  onOpenLink: onOpenLink,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SheetDragHandle extends StatelessWidget {
  const _SheetDragHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).disabledColor.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
