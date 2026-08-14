import "package:flutter/material.dart";
import "package:skworld_module_api/skworld_module_api.dart";

import "skcode_api_client.dart";
import "skcode_artifact_pane.dart";
import "skcode_chat_chip.dart";
import "skcode_event.dart";
import "skcode_pane_tier.dart";
import "skcode_project_chat.dart";
import "skcode_session_column.dart";
import "skcode_sessions_rail.dart";
import "skcode_ws_transport.dart";

/// [SkcodeSurface]'s body (card C-12, spec sections 7/7.1/7.2): the
/// four-column tier and the full collapse ladder underneath it, all driven
/// by a [LayoutBuilder] on THIS WIDGET'S OWN width (see
/// `skcode_pane_tier.dart`'s doc comment for why that must never be
/// `MediaQuery`/screen width).
///
/// Owns exactly one piece of state across every tier: which session is
/// "focused" ([_selected]) and its latest merged event window ([_events]).
/// Resizing the pane across a breakpoint (a window drag, not a navigation)
/// keeps that focus intact -- there is nothing tier-specific about WHICH
/// session an operator is watching, only about how many columns are honest
/// to show around it.
class SkcodeResponsiveBody extends StatefulWidget {
  const SkcodeResponsiveBody({
    super.key,
    required this.apiClient,
    required this.origin,
    required this.mintToken,
    required this.onAuthRejected,
    this.connectTransport = SkcodeWsTransport.connect,
    this.auth,
    this.projectChatBuilder,
    this.defaultRepo,
    this.onOpenLink,
  });

  final SkcodeApiClient apiClient;
  final String origin;
  final Future<String?> Function() mintToken;
  final VoidCallback onAuthRejected;
  final SkcodeWsTransport Function(Uri uri) connectTransport;
  final AuthContext? auth;

  /// Card C-12's own injection seam (spec section 10). See
  /// `skcode_project_chat.dart`'s doc comment for the full contract.
  final SkcodeProjectChatBuilder? projectChatBuilder;

  /// The repo the PHONE landing screen's chat chip binds to (spec section 7:
  /// "project chat is a header chip on the landing AND session screens" --
  /// the session screen always knows its own repo, but the landing screen
  /// has no session focused yet, so it needs a caller-supplied default).
  /// Null renders no landing-screen chip at all (the session-screen chip is
  /// unaffected -- it always uses that session's own concrete repo).
  final String? defaultRepo;

  /// The Digest tab's deep-link seam (card C-9), forwarded to the artifact
  /// pane. The digest's own transport needs no extra field here (card C-14a):
  /// it rides [apiClient] / [mintToken] / [onAuthRejected], the very same
  /// three this body already threads into the rail and the transcript.
  final void Function(String uri)? onOpenLink;

  @override
  State<SkcodeResponsiveBody> createState() => _SkcodeResponsiveBodyState();
}

class _SkcodeResponsiveBodyState extends State<SkcodeResponsiveBody> {
  SkcodeSessionSummary? _selected;
  List<SkcodeEvent> _events = const [];

  /// Two-column tier only (spec section 7: "the artifact pane ... becomes a
  /// toggled overlay docked right").
  bool _artifactOverlayOpen = false;

  void _onSelected(SkcodeSessionSummary session) {
    if (_selected?.sid == session.sid) return;
    setState(() {
      _selected = session;
      _events = const [];
    });
  }

  void _onEvents(List<SkcodeEvent> events) {
    if (!mounted) return;
    setState(() => _events = events);
  }

  /// The phone-tier rail: byte-for-byte the pre-C-12 behavior (push full
  /// screen on tap), plus the landing chat chip when both
  /// [SkcodeResponsiveBody.projectChatBuilder] and
  /// [SkcodeResponsiveBody.defaultRepo] are supplied, plus forwarding
  /// [SkcodeResponsiveBody.projectChatBuilder] so the PUSHED session
  /// screen's own chip works too (spec: "and session screens").
  Widget _buildPhoneRail(BuildContext context) {
    final builder = widget.projectChatBuilder;
    final repo = widget.defaultRepo;
    return SkcodeSessionsRail(
      apiClient: widget.apiClient,
      origin: widget.origin,
      mintToken: widget.mintToken,
      onAuthRejected: widget.onAuthRejected,
      connectTransport: widget.connectTransport,
      auth: widget.auth,
      projectChatBuilder: builder,
      headerChip: (builder != null && repo != null)
          ? SkcodeChatChip(repo: repo, onTap: () => _pushChat(context, builder, repo))
          : null,
    );
  }

  /// Tiers two/three/wide: the rail selects INLINE (spec section 7, "ask on
  /// the left, watch it land on the right" needs every column visible at
  /// once, never a navigation away from the rail).
  Widget _buildInlineRail() {
    return SkcodeSessionsRail(
      apiClient: widget.apiClient,
      origin: widget.origin,
      mintToken: widget.mintToken,
      onAuthRejected: widget.onAuthRejected,
      connectTransport: widget.connectTransport,
      auth: widget.auth,
      onSessionSelected: _onSelected,
      selectedSid: _selected?.sid,
    );
  }

  Widget _buildTranscriptColumn() {
    final selected = _selected;
    if (selected == null) {
      return const _SkcodeColumnEmptyState(
        key: Key("skcodeTranscriptEmptyState"),
        icon: Icons.terminal,
        message: "Select a session",
      );
    }
    return SkcodeSessionColumn(
      key: ValueKey("skcode-column-${selected.sid}"),
      sid: selected.sid,
      apiClient: widget.apiClient,
      origin: widget.origin,
      mintToken: widget.mintToken,
      onAuthRejected: widget.onAuthRejected,
      connectTransport: widget.connectTransport,
      auth: widget.auth,
      interactive: selected.mode == "interactive",
      onEvents: _onEvents,
    );
  }

  /// The chat column's own content builder (spec section 10): degrades
  /// honestly through three distinct, clearly-labeled empty states rather
  /// than ever crashing or rendering a dead column (this card's own
  /// "Constraints" section) -- no session focused yet, no
  /// [SkcodeResponsiveBody.projectChatBuilder] supplied at all (standalone /
  /// a host that never wired one), or a focused session with no `repo`
  /// hostd ever tagged it with.
  Widget _buildChatColumn(BuildContext context) {
    final builder = widget.projectChatBuilder;
    if (builder == null) {
      return const _SkcodeColumnEmptyState(
        key: Key("skcodeChatEmptyStateNoBuilder"),
        icon: Icons.forum_outlined,
        message: "Chat",
      );
    }
    final repo = _selected?.repo ?? "";
    if (repo.isEmpty) {
      return const _SkcodeColumnEmptyState(
        key: Key("skcodeChatEmptyStateNoSession"),
        icon: Icons.forum_outlined,
        message: "Select a session to open its project chat",
      );
    }
    return builder(context, repo);
  }

  Widget _buildArtifactPane({required bool showChatTab}) {
    return SkcodeArtifactPane(
      events: _events,
      showChatTab: showChatTab,
      chatSlot: showChatTab ? Builder(builder: _buildChatColumn) : null,
      apiClient: widget.apiClient,
      mintToken: widget.mintToken,
      onAuthRejected: widget.onAuthRejected,
      onOpenLink: widget.onOpenLink,
    );
  }

  void _pushChat(BuildContext context, SkcodeProjectChatBuilder builder, String repo) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (chatContext) => Scaffold(
          appBar: AppBar(title: Text("Chat: $repo")),
          body: builder(chatContext, repo),
        ),
      ),
    );
  }

  void _toggleArtifactOverlay() => setState(() => _artifactOverlayOpen = !_artifactOverlayOpen);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // AC3: driven by THIS box's own width, never MediaQuery/screen.
        final tier = skcodePaneTierForWidth(constraints.maxWidth);
        switch (tier) {
          case SkcodePaneTier.phone:
            return _buildPhoneRail(context);

          case SkcodePaneTier.twoColumn:
            return _SkcodeTwoColumnBody(
              rail: _buildInlineRail(),
              transcript: _buildTranscriptColumn(),
              artifactPane: _buildArtifactPane(showChatTab: true),
              overlayOpen: _artifactOverlayOpen,
              onToggleOverlay: _toggleArtifactOverlay,
            );

          case SkcodePaneTier.threeColumn:
            return Row(
              key: const Key("skcodeThreeColumnBody"),
              children: [
                SizedBox(width: kSkcodeRailColumnWidth, child: _buildInlineRail()),
                Expanded(child: _buildTranscriptColumn()),
                SizedBox(
                  width: kSkcodeArtifactColumnWidth,
                  child: _buildArtifactPane(showChatTab: true),
                ),
              ],
            );

          case SkcodePaneTier.wide:
            return Row(
              key: const Key("skcodeWideBody"),
              children: [
                SizedBox(width: kSkcodeRailColumnWidth, child: _buildInlineRail()),
                SizedBox(
                  key: const Key("skcodeProjectChatColumn"),
                  width: kSkcodeChatColumnWidth,
                  child: Builder(builder: _buildChatColumn),
                ),
                Expanded(
                  key: const Key("skcodeTranscriptColumn"),
                  child: _buildTranscriptColumn(),
                ),
                SizedBox(
                  width: kSkcodeArtifactColumnWidth,
                  child: _buildArtifactPane(showChatTab: false),
                ),
              ],
            );
        }
      },
    );
  }
}

/// Two-column tier (spec section 7: "rail + transcript; the artifact pane
/// (still carrying the Chat tab) becomes a toggled overlay docked right,
/// same shadow"). The rail and transcript are laid out normally; the
/// artifact pane floats above them ONLY while toggled open, so it never
/// steals width from the transcript the rest of the time.
class _SkcodeTwoColumnBody extends StatelessWidget {
  const _SkcodeTwoColumnBody({
    required this.rail,
    required this.transcript,
    required this.artifactPane,
    required this.overlayOpen,
    required this.onToggleOverlay,
  });

  final Widget rail;
  final Widget transcript;
  final Widget artifactPane;
  final bool overlayOpen;
  final VoidCallback onToggleOverlay;

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: const Key("skcodeTwoColumnBody"),
      children: [
        Row(
          children: [
            SizedBox(width: kSkcodeRailColumnWidth, child: rail),
            const VerticalDivider(width: 1),
            Expanded(child: transcript),
          ],
        ),
        Positioned(
          top: 4,
          right: overlayOpen ? kSkcodeArtifactColumnWidth + 4 : 4,
          child: _ArtifactOverlayToggle(open: overlayOpen, onTap: onToggleOverlay),
        ),
        if (overlayOpen)
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: kSkcodeArtifactColumnWidth,
            child: artifactPane,
          ),
      ],
    );
  }
}

class _ArtifactOverlayToggle extends StatelessWidget {
  const _ArtifactOverlayToggle({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key("skcodeArtifactOverlayToggle"),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        tooltip: open ? "Hide artifacts" : "Show artifacts",
        icon: Icon(open ? Icons.chevron_right : Icons.dashboard_outlined),
        onPressed: onTap,
      ),
    );
  }
}

/// A tier-neutral, honest empty state for a column with nothing to show yet
/// (no session focused, no chat builder wired, no repo on the focused
/// session). Never a crash, never a blank area (this card's own
/// "Constraints" section: "Degrade honestly").
class _SkcodeColumnEmptyState extends StatelessWidget {
  const _SkcodeColumnEmptyState({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).disabledColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
