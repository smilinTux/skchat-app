import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sovereign_colors.dart';
import '../../services/guest_group_service.dart';
import 'guest_room_screen.dart';

/// Guest landing for a shareable group link `/g/:token`.
///
/// Lives OUTSIDE the authed shell (no bottom nav). Flow:
///   1. preview the invite -> show the room name.
///   2. if a browser keypair is already cached -> AUTO-JOIN (returning guest).
///   3. else prompt for a name -> generate+persist a WebCrypto keypair ->
///      POST /api/v1/guest/join -> enter the room.
///
/// On success it swaps itself for [GuestRoomScreen] (the full in-room view for
/// the ONE invited group). It never exposes any other surface.
class GuestLandingScreen extends ConsumerStatefulWidget {
  const GuestLandingScreen({super.key, required this.token});

  /// The invite token from the link (`/g/<token>`).
  final String token;

  @override
  ConsumerState<GuestLandingScreen> createState() => _GuestLandingScreenState();
}

class _GuestLandingScreenState extends ConsumerState<GuestLandingScreen> {
  final _nameCtl = TextEditingController();
  bool _busy = true;
  String? _error;
  String? _groupName;
  bool _validInvite = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final svc = ref.read(guestGroupServiceProvider);
    try {
      final preview = await svc.previewInvite(widget.token);
      _validInvite = preview['valid'] == true;
      _groupName = preview['group_name'] as String?;
      if (!_validInvite) {
        setState(() {
          _busy = false;
          _error = 'This invite link is invalid or has expired.';
        });
        return;
      }
      // Returning guest? (a keypair is already cached for this browser.)
      if (await svc.identity.hasCached()) {
        await _join(autoName: 'Guest');
        return;
      }
      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not load the invite: $e';
      });
    }
  }

  Future<void> _join({String? autoName}) async {
    final name = autoName ?? _nameCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name to join.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(guestGroupServiceProvider).join(
            inviteToken: widget.token,
            displayName: name,
          );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => GuestRoomScreen(join: result),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Join failed — the invite may be invalid or expired.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _busy
                ? const _Loading()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.groups_2_outlined,
                          size: 48, color: SovereignColors.soulLumina),
                      const SizedBox(height: 16),
                      Text(
                        _validInvite
                            ? "You're invited to"
                            : 'Invite unavailable',
                        style: tt.bodyMedium
                            ?.copyWith(color: SovereignColors.textSecondary),
                        textAlign: TextAlign.center,
                      ),
                      if (_groupName != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _groupName!,
                          style: tt.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (_error != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: SovereignColors.accentDanger
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(_error!,
                              style: tt.bodyMedium, textAlign: TextAlign.center),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_validInvite) ...[
                        const _UntrustedNote(),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _nameCtl,
                          decoration: const InputDecoration(
                            labelText: 'Your name',
                            hintText: 'e.g. Alex',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _join(),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => _join(),
                          icon: const Icon(Icons.login),
                          label: const Text('Join room'),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Center(
        child: CircularProgressIndicator(
          color: SovereignColors.soulLumina,
          strokeWidth: 2,
        ),
      );
}

/// Tells the guest they will join as an untrusted, self-asserted identity.
class _UntrustedNote extends StatelessWidget {
  const _UntrustedNote();
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SovereignColors.accentWarning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: SovereignColors.accentWarning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined,
              size: 18, color: SovereignColors.accentWarning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'You will join as a guest. Your identity is self-asserted and '
              'untrusted — you can chat, call, and share files in this room only.',
              style: tt.bodySmall
                  ?.copyWith(color: SovereignColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
