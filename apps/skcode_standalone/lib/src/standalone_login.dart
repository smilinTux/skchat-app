import 'package:flutter/material.dart';

/// The standalone runner's own login seam (card C-2, spec section 4.1: "a
/// standalone runner with its own capauth login").
///
/// Standalone mode has no shell to authenticate against, so it owns its login
/// step rather than receiving an [AuthContext] from a [ShellContext]. This is
/// the SEAM: it renders a plain sign-in gate and, on success, reveals the
/// hosted module. The real capauth challenge/response wiring (device
/// enrollment through `capauth.pairing`, audience-token mint) lands as a
/// follow-up on this same widget, mirroring
/// `apps/skchat_standalone/lib/src/standalone_login.dart`'s own seam; the seam
/// and the standalone chrome are real now so the boot gate exercises the
/// whole standalone path.
///
/// It stays pure with respect to the app shell: it imports only Flutter,
/// never `package:skchat`.
class StandaloneLoginGate extends StatefulWidget {
  const StandaloneLoginGate({super.key, required this.child});

  /// The authenticated surface revealed once the local login completes.
  final Widget child;

  @override
  State<StandaloneLoginGate> createState() => _StandaloneLoginGateState();
}

class _StandaloneLoginGateState extends State<StandaloneLoginGate> {
  bool _authenticated = false;

  void _enter() => setState(() => _authenticated = true);

  @override
  Widget build(BuildContext context) {
    if (_authenticated) return widget.child;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.terminal, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'SKCode',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Standalone sign-in',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _enter,
                    child: const Text('Enter'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
