import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'skcode_api_client.dart';
import 'skcode_sessions_rail.dart';

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
///     `mintToken` resolves to `null`. [SkcodeSessionsListStore] already
///     treats a null token as "skip this poll, render whatever the caller
///     shows for an empty list" (spec 4.3), which degrades to an honest
///     "No sessions yet" rather than a crash. Wiring a real standalone token
///     mint is a follow-up on that same seam, not this card's job.
class SkcodeSurface extends StatefulWidget {
  const SkcodeSurface({
    super.key,
    this.shell,
    this.origin,
    this.onAuthRejected,
    this.apiClient,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Code')),
      body: SkcodeSessionsRail(
        apiClient: _apiClient,
        origin: _resolvedOrigin,
        mintToken: _mintToken,
        onAuthRejected: widget.onAuthRejected ?? _noopAuthRejected,
      ),
    );
  }
}

/// The fallback when [SkcodeSurface.onAuthRejected] is omitted (matches the
/// no-op pattern `apps/skcode_standalone/lib/src/standalone_app.dart` already
/// uses for the standalone runner's own default): nothing to invalidate when
/// no host token cache exists to begin with.
void _noopAuthRejected() {}
