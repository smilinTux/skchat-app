import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

/// The skcode module body (card C-2 skeleton, spec section 4.1).
///
/// This is deliberately an EMPTY shell: it proves the mount pattern and the
/// standalone boot, nothing more. It renders no transcript, session, or WS
/// data (that is card C-3 and C-4). What it DOES prove:
///
///   * MOUNTED (`shell != null`): it reads the shell's [ThemeData] through
///     the ambient `Theme.of(context)` (never a hardcoded theme), it emits a
///     [ShellEvent] onto the shell's [ShellBus] on mount so the bus wiring is
///     exercised end to end, and it calls the shell's [AuthContext.token] so
///     the audience-token dance is exercised (result rendered, never thrown).
///   * STANDALONE (`shell == null`): it renders a plain "standalone" state
///     with no bus and no token call, matching the standalone-nullability
///     rule (module contract standard section 3.1).
class SkcodeSurface extends StatefulWidget {
  const SkcodeSurface({super.key, this.shell});

  /// Null means standalone; non-null means mounted (module contract standard
  /// section 3.1, the standalone-nullability rule).
  final ShellContext? shell;

  @override
  State<SkcodeSurface> createState() => _SkcodeSurfaceState();
}

class _SkcodeSurfaceState extends State<SkcodeSurface> {
  Future<String?>? _tokenFuture;

  @override
  void initState() {
    super.initState();
    final shell = widget.shell;
    if (shell != null) {
      // Exercise the bus: a mounted skcode surface tells the shell it mounted.
      // No cross-module deep link exists yet in this skeleton, so this is the
      // whole bus contact point for now.
      shell.bus.emit(const ShellEvent('skcodeMounted'));
      // Exercise the AuthContext: mint (or fail to mint, never throw) an
      // audience-scoped token. The result is rendered, not acted on, because
      // there is no session/WS code in this skeleton (C-3/C-4).
      _tokenFuture = shell.auth.token();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shell = widget.shell;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('Code', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              shell == null
                  ? 'Standalone'
                  : 'Mounted (audience: ${shell.auth.audience})',
              style: theme.textTheme.bodyMedium,
            ),
            if (shell != null) ...[
              const SizedBox(height: 8),
              FutureBuilder<String?>(
                future: _tokenFuture,
                builder: (context, snapshot) {
                  final text = switch (snapshot.connectionState) {
                    ConnectionState.waiting => 'minting token...',
                    _ => snapshot.data == null
                        ? 'no token (running degraded)'
                        : 'token minted',
                  };
                  return Text(text, style: theme.textTheme.bodySmall);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
