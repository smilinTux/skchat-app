import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../services/biometric_service.dart';
import '../../services/device_recovery_codec.dart';
import '../../services/guest_identity.dart';
import '../../services/operator_session_service.dart';

/// Reveals the 24-word BIP39 recovery phrase for THIS device's operator key.
///
/// The phrase IS the private key: anyone who holds all 24 words can become
/// this identity on any device. So the reveal is gated behind biometric /
/// device-credential auth when available, and the screen is blunt about the
/// stakes: write it on paper, never screenshot it, never type it into anything
/// but a genuine SKChat restore.
///
/// Only the native device keystore can produce a phrase (it holds the raw
/// scalar). On web / stub the identity is not a [RecoverableIdentity], so this
/// screen shows an "unsupported here" state instead of crashing.
class RecoveryPhraseScreen extends ConsumerStatefulWidget {
  const RecoveryPhraseScreen({super.key});

  @override
  ConsumerState<RecoveryPhraseScreen> createState() =>
      _RecoveryPhraseScreenState();
}

enum _Stage { authenticating, locked, revealed, unsupported, error }

class _RecoveryPhraseScreenState extends ConsumerState<RecoveryPhraseScreen> {
  _Stage _stage = _Stage.authenticating;
  List<String> _words = const [];
  String _error = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _gateAndReveal());
  }

  /// Explicit consent gate for platforms with no biometric / device-credential
  /// provider (e.g. Linux desktop). Returns true only if the user deliberately
  /// confirms after reading the danger warning. The confirm button is NOT the
  /// default action, so a stray Enter / tap does not reveal the key.
  Future<bool?> _confirmRevealWithoutAuth() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Reveal recovery phrase?'),
        content: const Text(
          'This device has no biometric or screen lock available, so SKChat '
          'cannot verify it is you.\n\n'
          'The 24 words about to be shown ARE your private identity key. Anyone '
          'who sees them (in person, over screen-share, or in a screenshot) can '
          'become you on any device.\n\n'
          'Only continue if no one else can see your screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: SovereignColors.accentDanger,
            ),
            child: const Text('Reveal anyway'),
          ),
        ],
      ),
    );
  }

  Future<void> _gateAndReveal() async {
    setState(() => _stage = _Stage.authenticating);

    final identity = ref.read(operatorSessionServiceProvider).identity;
    if (identity is! RecoverableIdentity) {
      setState(() => _stage = _Stage.unsupported);
      return;
    }
    final recoverable = identity as RecoverableIdentity;

    // Biometric / device-credential gate when the platform offers one.
    final bio = ref.read(biometricServiceProvider);
    if (await bio.isAvailable()) {
      final ok = await bio.authenticate(
        reason: 'Reveal your device recovery phrase',
      );
      if (!ok) {
        setState(() => _stage = _Stage.locked);
        return;
      }
    } else {
      // No biometric / device-credential provider on this platform (notably
      // Linux desktop, which local_auth does not support). FAIL SAFE, not open:
      // require a deliberate, explicit confirmation instead of silently
      // revealing the raw private key, so a shoulder-surfer / screen-share
      // viewer of an unlocked window cannot grab the phrase with one tap.
      if (!mounted) return;
      final confirmed = await _confirmRevealWithoutAuth();
      if (confirmed != true) {
        if (!mounted) return;
        setState(() => _stage = _Stage.locked);
        return;
      }
    }

    try {
      final words = await recoverable.exportRecoveryPhrase();
      if (!mounted) return;
      setState(() {
        _words = words;
        _stage = _Stage.revealed;
      });
    } on RecoveryPhraseException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _stage = _Stage.error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read the device key.';
        _stage = _Stage.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: const Text('Recovery phrase'),
      ),
      body: switch (_stage) {
        _Stage.authenticating => const Center(
            child: CircularProgressIndicator(color: SovereignColors.soulLumina),
          ),
        _Stage.locked => _LockedView(onRetry: _gateAndReveal),
        _Stage.unsupported => const _UnsupportedView(),
        _Stage.error => _ErrorView(message: _error, onRetry: _gateAndReveal),
        _Stage.revealed => _RevealedView(words: _words),
      },
    );
  }
}

class _RevealedView extends StatelessWidget {
  const _RevealedView({required this.words});
  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        // ── Danger banner ────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: SovereignColors.accentDanger.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: SovereignColors.accentDanger.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: SovereignColors.accentDanger,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Anyone with these 24 words IS your identity. Write them on '
                  'paper and store them offline. Never screenshot them, never '
                  'type them into anything but a genuine SKChat "Restore" '
                  'screen. SKChat cannot recover them for you.',
                  style: tt.bodySmall?.copyWith(
                    color: SovereignColors.textPrimary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // ── Word grid ────────────────────────────────────────────────────
        GlassCard(
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: words.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 4.2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemBuilder: (context, i) => _WordChip(index: i + 1, word: words[i]),
          ),
        ),
        const SizedBox(height: 16),

        // ── Copy (with an explicit clipboard warning) ────────────────────
        OutlinedButton.icon(
          onPressed: () => _confirmCopy(context),
          icon: const Icon(Icons.copy_rounded, size: 18),
          style: OutlinedButton.styleFrom(
            foregroundColor: SovereignColors.textSecondary,
            side: const BorderSide(color: SovereignColors.surfaceGlassBorder),
            minimumSize: const Size(double.infinity, 48),
          ),
          label: const Text('Copy to clipboard (risky)'),
        ),
        const SizedBox(height: 8),
        Text(
          'Copying puts the phrase on your clipboard where other apps can read '
          'it. Prefer writing it down.',
          style: tt.labelSmall?.copyWith(color: SovereignColors.textTertiary),
        ),
      ],
    );
  }

  void _confirmCopy(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text('Copy recovery phrase?'),
        content: const Text(
          'Any app on this device can read the clipboard. Only do this if you '
          'are pasting into an offline password manager right now.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: SovereignColors.textTertiary),
            ),
          ),
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: words.join(' ')));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Recovery phrase copied — clear it soon'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentDanger,
            ),
            child: const Text('Copy anyway'),
          ),
        ],
      ),
    );
  }
}

class _WordChip extends StatelessWidget {
  const _WordChip({required this.index, required this.word});
  final int index;
  final String word;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: SovereignColors.surfaceGlass,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SovereignColors.surfaceGlassBorder),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$index',
              style: const TextStyle(
                color: SovereignColors.textTertiary,
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              word,
              style: const TextStyle(
                color: SovereignColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LockedView extends StatelessWidget {
  const _LockedView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _CenteredMessage(
      icon: Icons.lock_outline_rounded,
      color: SovereignColors.accentWarning,
      title: 'Authentication required',
      body: 'Unlock with your biometric or device credential to reveal the '
          'recovery phrase.',
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

class _UnsupportedView extends StatelessWidget {
  const _UnsupportedView();

  @override
  Widget build(BuildContext context) {
    return const _CenteredMessage(
      icon: Icons.devices_other_rounded,
      color: SovereignColors.textTertiary,
      title: 'Not available here',
      body: 'A recovery phrase can only be exported from a native device that '
          'holds its own key (the desktop/mobile app). This build keeps its '
          'key in the browser, which cannot export it.',
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _CenteredMessage(
      icon: Icons.error_outline_rounded,
      color: SovereignColors.accentDanger,
      title: 'Cannot show recovery phrase',
      body: message,
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 16),
            Text(
              title,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: tt.bodySmall?.copyWith(
                color: SovereignColors.textSecondary,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: SovereignColors.soulLumina,
                  foregroundColor: Colors.black,
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
