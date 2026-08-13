import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'skcode_api_client.dart';
import 'skcode_artifact_pane.dart';
import 'skcode_digest.dart';
import 'skcode_project_chat.dart';
import 'skcode_responsive_body.dart';

/// skcode-hostd's own fallback (matches [SkcodeApiClient]'s default
/// `baseUrl`), used when neither the mounted host nor the standalone runner
/// supplies [SkcodeModule.origin] (module contract standard section 3.1:
/// [SkcodeModule.origin] is nullable and this is its degrade-gracefully
/// default, not a real production value).
const _kDefaultSkcodeOrigin = 'http://localhost:9384';

/// The skcode module body (card C-2 skeleton; card C-4 wires the render
/// layer on top of the C-3b transport).
///
/// The rail is the whole body: this IS the `/code` landing screen (spec
/// section 7, "the rail is the /code landing screen"). Both modes render it:
///
///   * MOUNTED (`shell != null`): it emits a [ShellEvent] onto the shell's
///     [ShellBus] on mount (unchanged from the C-2 skeleton), reads the
///     shell's [ThemeData] through the ambient `Theme.of(context)`, and hands
///     [SkcodeSessionsRail] `shell.auth.token` as its `mintToken` so the real
///     audience-token dance drives the live session poll.
///   * STANDALONE (`shell == null`): there is no [AuthContext] to mint
///     against yet (`StandaloneLoginGate`'s login is still a placeholder
///     seam, `apps/skcode_standalone/lib/src/standalone_login.dart`), so
///     `mintToken` resolves to `null`. [SkcodeSessionsListStore] treats a
///     null token as "no usable token" (card C-19), which degrades to the
///     rail's honest "No access yet" state rather than a crash -- the same
///     state a rejected (401) token would render, since both mean the
///     operator cannot see sessions yet for the same reason: no valid
///     credential reached skcode-hostd. Wiring a real standalone token mint
///     is a follow-up on that same seam, not this card's job.
///
/// An app bar "Digest" action (card C-9) presents the artifact pane's swipe-up
/// bottom sheet focused on data that is not session-scoped, so it is reached
/// from here rather than from a session screen: [SkcodeArtifactPane.digestUrl]
/// / [SkcodeArtifactPane.onOpenLink] are forwarded straight from
/// [SkcodeModule.digestUrl] / the resolved [_onOpenLink] default.
class SkcodeSurface extends StatefulWidget {
  const SkcodeSurface({
    super.key,
    this.shell,
    this.origin,
    this.onAuthRejected,
    this.apiClient,
    this.digestUrl,
    this.onOpenLink,
    this.digestClient,
    this.projectChatBuilder,
    this.defaultRepo,
  });

  /// Null means standalone; non-null means mounted (module contract standard
  /// section 3.1, the standalone-nullability rule).
  final ShellContext? shell;

  /// Where skcode-hostd lives (card C-3b / [SkcodeModule.origin]).
  final String? origin;

  /// Forwarded from [SkcodeModule.onAuthRejected]; called by the session
  /// stores this surface owns on an HTTP 401 / WS 1008.
  final VoidCallback? onAuthRejected;

  /// Test seam: inject a fake [SkcodeApiClient] so a widget test never opens
  /// a real socket to [origin]. Production always omits this and gets a real
  /// Dio-backed client built from [origin].
  final SkcodeApiClient? apiClient;

  /// Forwarded from [SkcodeModule.digestUrl] (card C-9): the Digest action
  /// below reaches it straight through to [SkcodeArtifactPane.digestUrl].
  final String? digestUrl;

  /// Forwarded from [SkcodeModule.onOpenLink] (card C-9). See [_onOpenLink]
  /// for the default this surface supplies when a host omits it.
  final void Function(String uri)? onOpenLink;

  /// Test seam: inject a fake [SkcodeDigestClient] so a widget test never
  /// opens a real socket for the Digest action either.
  final SkcodeDigestClient? digestClient;

  /// Forwarded from [SkcodeModule.projectChatBuilder] (card C-12, spec
  /// section 10). See `skcode_project_chat.dart`'s doc comment for the full
  /// injection contract.
  final SkcodeProjectChatBuilder? projectChatBuilder;

  /// Forwarded from [SkcodeModule.defaultRepo] (card C-12): the phone
  /// landing screen's chat-chip target. See [SkcodeResponsiveBody.defaultRepo].
  final String? defaultRepo;

  @override
  State<SkcodeSurface> createState() => _SkcodeSurfaceState();
}

class _SkcodeSurfaceState extends State<SkcodeSurface> {
  late final SkcodeApiClient _apiClient;
  late final String _resolvedOrigin;

  @override
  void initState() {
    super.initState();
    _resolvedOrigin = widget.origin ?? _kDefaultSkcodeOrigin;
    _apiClient = widget.apiClient ?? SkcodeApiClient(baseUrl: widget.origin);
    final shell = widget.shell;
    if (shell != null) {
      // Exercise the bus: a mounted skcode surface tells the shell it
      // mounted. No cross-module deep link exists yet, so this is the whole
      // bus contact point for now.
      shell.bus.emit(const ShellEvent('skcodeMounted'));
    }
  }

  Future<String?> _mintToken() {
    final shell = widget.shell;
    if (shell == null) return Future.value(null);
    return shell.auth.token();
  }

  /// The Digest tab's deep-link resolver (card C-9). A host-supplied
  /// [SkcodeSurface.onOpenLink] always wins (test seam / custom handling);
  /// otherwise, when mounted, this defaults to `shell.bus.navigate` -
  /// already "the shell router" a `skworld://` link is meant to land on
  /// (`ShellBus.navigate`'s own docstring: "cross-module links are routed by
  /// the shell to the owning module"), so a host does not have to wire this
  /// explicitly for the common case. Standalone (no shell) has no router to
  /// resolve against, so links stay inert (null) there.
  void Function(String uri)? get _onOpenLink =>
      widget.onOpenLink ?? widget.shell?.bus.navigate;

  void _openDigest(BuildContext context) {
    SkcodeArtifactPane.showBottomSheet(
      context,
      events: const [],
      digestUrl: widget.digestUrl,
      onOpenLink: _onOpenLink,
      digestClient: widget.digestClient,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Code'),
        actions: [
          IconButton(
            tooltip: 'Digest',
            icon: const Icon(Icons.summarize_outlined),
            onPressed: () => _openDigest(context),
          ),
        ],
      ),
      body: SkcodeResponsiveBody(
        apiClient: _apiClient,
        origin: _resolvedOrigin,
        mintToken: _mintToken,
        onAuthRejected: widget.onAuthRejected ?? _noopAuthRejected,
        // Card C-5: the mounted shell's AuthContext, forwarded so the pushed
        // SkcodeSessionScreen can read `hasScope(kSkcodeInjectScope)`. Null
        // in standalone mode (no shell, no login seam yet), which correctly
        // fails the inject-composer gate closed.
        auth: widget.shell?.auth,
        projectChatBuilder: widget.projectChatBuilder,
        defaultRepo: widget.defaultRepo,
        digestUrl: widget.digestUrl,
        onOpenLink: _onOpenLink,
        digestClient: widget.digestClient,
      ),
    );
  }
}

/// The fallback when [SkcodeSurface.onAuthRejected] is omitted (matches the
/// no-op pattern `apps/skcode_standalone/lib/src/standalone_app.dart` already
/// uses for the standalone runner's own default): nothing to invalidate when
/// no host token cache exists to begin with.
void _noopAuthRejected() {}
