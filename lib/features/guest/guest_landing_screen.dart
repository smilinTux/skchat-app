import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sovereign_colors.dart';
import '../../services/guest_group_service.dart';
import 'guest_invite_inactive.dart';
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
  const GuestLandingScreen({
    super.key,
    required this.token,
    this.fragmentSecret,
  });

  /// The invite token from the link (`/g/<token>`), already split from any
  /// `&k=` suffix by [GuestLink] - it must be the bare JWT or every call
  /// carrying it fails signature verification.
  final String token;

  /// The `k` fragment secret when the link carried one. Not required to
  /// preview or join (the server reads it on neither path); carried so it is
  /// available rather than silently dropped at the router.
  final String? fragmentSecret;

  @override
  ConsumerState<GuestLandingScreen> createState() => _GuestLandingScreenState();
}

class _GuestLandingScreenState extends ConsumerState<GuestLandingScreen> {
  final _nameCtl = TextEditingController();
  bool _busy = true;
  String? _error;
  // guest-dm C2: a revoked/expired link (S3 reason on join) shows the distinct
  // "no longer active" terminal view, not a generic "join failed".
  String? _terminalReason;
  String? _groupName;
  bool _validInvite = false;
  // guest-dm C2: a mode=dm invite lands the guest straight into a 1:1 with the
  // operator, so the landing shows DM copy (chat with <operator_name>) instead
  // of group copy. Null/"group" keeps the original group framing.
  String? _mode;
  String? _operatorName;
  bool get _isDm => _mode == 'dm';
  // Phase 1 (SKCHAT_PQ_INVITES_ENABLED) operator claims from the preview; absent
  // when the operator hasn't enabled signed invites.
  String? _jti;
  String? _bc;

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
      _mode = preview['mode'] as String?;
      _operatorName = (preview['operator_name'] as String?)?.trim();
      _jti = preview['jti'] as String?;
      _bc = preview['bc'] as String?;
      // DM invite: suggest an editable display name so the guest can join in one
      // tap, but still rename before (or after, see guest_room_screen) joining.
      if (_isDm && _nameCtl.text.isEmpty) {
        _nameCtl.text = 'Guest';
      }
      // Phase 2: hand the service the operator PQ sealing material so guest
      // sends are pqdm1-sealed to the operator's bc-verified hybrid prekey.
      svc.configureSealing(
        signedPrekey: preview['signed_prekey'] as String?,
        bc: preview['bc'] as String?,
        identityKey: preview['full_pubkey'] as String?,
      );
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
            jti: _jti,
            bc: _bc,
          );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => GuestRoomScreen(
            join: result,
            isDm: _isDm,
            operatorName: _operatorName,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final reason = contactTerminalReason(e);
      setState(() {
        _busy = false;
        if (reason != null) {
          _terminalReason = reason;
        } else {
          _error = 'Join failed, the invite may be invalid or expired.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    // A revoked/expired link is terminal: show the distinct inactive view.
    if (_terminalReason != null) {
      return GuestInviteInactiveView(reason: _terminalReason);
    }
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
                      Icon(
                        _isDm
                            ? Icons.chat_bubble_outline_rounded
                            : Icons.groups_2_outlined,
                        size: 48,
                        color: SovereignColors.soulLumina,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        !_validInvite
                            ? 'Invite unavailable'
                            : _isDm
                                ? "You're invited to chat with"
                                : "You're invited to",
                        style: tt.bodyMedium
                            ?.copyWith(color: SovereignColors.textSecondary),
                        textAlign: TextAlign.center,
                      ),
                      if (_validInvite && (_isDm ? _operatorName : _groupName) != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          (_isDm ? _operatorName : _groupName)!,
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
              'untrusted, you can chat, call, and share files in this room only.',
              style: tt.bodySmall
                  ?.copyWith(color: SovereignColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
