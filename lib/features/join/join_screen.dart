import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../../core/router/app_router.dart";
import "../../core/theme/theme.dart";
import "../../services/join_service.dart";
import "../../services/livekit_call_service.dart";
import "../../services/pgp_capauth_signer.dart";
import "../calls/livekit_call_screen.dart";

/// Conference JOIN screen reached from a shared join link
/// (`/join?room=...&invite=...` guest, `/join?room=...&sovereign=1` sovereign).
///
/// Mirrors the web `join.html` chooser: presents a **Sovereign** vs **Guest**
/// choice (only the paths the link actually offers), runs the corresponding
/// web-UI endpoint, then connects the returned LiveKit token via
/// [LiveKitCallService.connectWithToken] (by routing into [LiveKitCallScreen]
/// with a pre-minted token).
class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key, required this.link});

  final JoinLink link;

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<JoinScreen> {
  final _nameCtl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.link.displayName != null) {
      _nameCtl.text = widget.link.displayName!;
    }
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  // ── Guest path ────────────────────────────────────────────────────────────

  Future<void> _joinAsGuest() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = "Enter a display name to join as a guest.");
      return;
    }
    await _run(() async {
      final join = await ref.read(joinServiceProvider).joinGuest(
            room: widget.link.room,
            inviteToken: widget.link.inviteToken!,
            displayName: name,
          );
      _enterRoom(join, displayName: name);
    });
  }

  // ── Sovereign path ────────────────────────────────────────────────────────

  Future<void> _joinAsSovereign() async {
    await _run(() async {
      final signer = await ref.read(sovereignSignerProvider.future);
      if (signer == null) {
        throw const _JoinException(
          "No sovereign identity on this device. Complete CapAuth login first.",
        );
      }
      final join = await ref.read(joinServiceProvider).joinSovereign(
            room: widget.link.room,
            identity: signer.identity,
            signer: signer,
          );
      _enterRoom(join, displayName: join.identity);
    });
  }

  // ── Shared ────────────────────────────────────────────────────────────────

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } on _JoinException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = "Join failed: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Hand the pre-minted token to the LiveKit call screen, which calls
  /// [LiveKitCallService.connectWithToken] under the hood.
  void _enterRoom(ConfJoin join, {required String displayName}) {
    if (!mounted) return;
    context.pushReplacement(
      AppRoutes.livekitCall,
      extra: LiveKitCallArgs(
        roomName: join.room,
        identity: join.identity,
        displayName: displayName,
        preMintedToken: join.token,
        livekitUrl: join.lkUrl,
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final link = widget.link;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: Text("Join call", style: tt.displayLarge?.copyWith(fontSize: 24)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("Room", style: tt.labelMedium),
            const SizedBox(height: 4),
            Text(link.room, style: tt.titleLarge),
            const SizedBox(height: 24),

            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!, style: tt.bodyMedium),
              ),
              const SizedBox(height: 16),
            ],

            // Guest path — only when the link carries an invite token.
            if (link.hasGuest) ...[
              Text("Join as guest", style: tt.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _nameCtl,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: "Display name",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _joinAsGuest,
                icon: const Icon(Icons.person_outline),
                label: const Text("Join as guest"),
              ),
            ],

            if (link.hasGuest && link.sovereign) ...[
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
            ],

            // Sovereign path — capauth-signed identity.
            if (link.sovereign) ...[
              Text("Join as yourself (sovereign)", style: tt.titleMedium),
              const SizedBox(height: 4),
              Text(
                "Signs a CapAuth assertion with your local identity key.",
                style: tt.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _joinAsSovereign,
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text("Join as sovereign"),
              ),
            ],

            const Spacer(),
            if (_busy)
              const Center(
                child: CircularProgressIndicator(
                  color: SovereignColors.soulLumina,
                  strokeWidth: 2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _JoinException implements Exception {
  const _JoinException(this.message);
  final String message;
}
