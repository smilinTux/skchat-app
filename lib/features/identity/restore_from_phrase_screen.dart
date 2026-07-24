import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../services/device_recovery_codec.dart';
import '../../services/guest_identity.dart';
import '../../services/operator_session_service.dart';

/// Restore this device's operator identity from a 24-word BIP39 recovery
/// phrase. Reconstructs the SAME ECDSA P-256 keypair the phrase was exported
/// from and persists it, replacing whatever key this device currently holds.
///
/// This OVERWRITES the local device key, so the screen makes the destructive
/// nature explicit and requires a confirm. Restore is native-only (the key
/// must be persistable + the scalar reconstructable); on web / stub the
/// identity is not a [RecoverableIdentity] and the screen says so.
class RestoreFromPhraseScreen extends ConsumerStatefulWidget {
  const RestoreFromPhraseScreen({super.key});

  @override
  ConsumerState<RestoreFromPhraseScreen> createState() =>
      _RestoreFromPhraseScreenState();
}

class _RestoreFromPhraseScreenState
    extends ConsumerState<RestoreFromPhraseScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  int _wordCount = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_recount);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _recount() {
    final n = DeviceRecoveryCodec.normalize(_controller.text).length;
    if (n != _wordCount) setState(() => _wordCount = n);
  }

  Future<void> _restore() async {
    final identity = ref.read(operatorSessionServiceProvider).identity;
    if (identity is! RecoverableIdentity) {
      setState(() => _error =
          'Restore is only available in the native app (this build keeps its '
          'key in the browser).');
      return;
    }
    final recoverable = identity as RecoverableIdentity;

    final words = DeviceRecoveryCodec.normalize(_controller.text);
    if (words.length != 24) {
      setState(() => _error = 'Enter all 24 words (found ${words.length}).');
      return;
    }

    // Destructive: confirm before overwriting the on-device key.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text('Replace this device key?'),
        content: const Text(
          'Restoring will overwrite the key currently on this device with the '
          'one encoded by your phrase. Any enrollment tied to the old key will '
          'need to be re-done. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: SovereignColors.textTertiary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentWarning,
              foregroundColor: Colors.black,
            ),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final kp = await recoverable.restoreFromRecoveryPhrase(words);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Identity restored · ${kp.fingerprint}'),
          duration: const Duration(seconds: 3),
        ),
      );
      Navigator.of(context).pop();
    } on RecoveryPhraseException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Restore failed. Check the words and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: const Text('Restore from phrase'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          Text(
            'Enter your 24-word recovery phrase, in order, separated by spaces. '
            'This reconstructs your device identity on this device.',
            style: tt.bodySmall?.copyWith(
              color: SovereignColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('recovery-phrase-field'),
                  controller: _controller,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 8,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.none,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [
                    // Words + single spaces only; keeps the field tidy.
                    FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z ]')),
                  ],
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 14,
                    color: SovereignColors.textPrimary,
                    height: 1.5,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'word1 word2 word3 ...',
                    hintStyle: TextStyle(color: SovereignColors.textTertiary),
                  ),
                ),
                const Divider(color: SovereignColors.surfaceGlassBorder),
                Row(
                  children: [
                    Icon(
                      _wordCount == 24
                          ? Icons.check_circle_outline
                          : Icons.pending_outlined,
                      size: 16,
                      color: _wordCount == 24
                          ? SovereignColors.accentEncrypt
                          : SovereignColors.textTertiary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$_wordCount / 24 words',
                      style: tt.labelSmall?.copyWith(
                        color: _wordCount == 24
                            ? SovereignColors.accentEncrypt
                            : SovereignColors.textTertiary,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _busy ? null : _pasteFromClipboard,
                      icon: const Icon(Icons.paste_rounded, size: 16),
                      label: const Text('Paste'),
                      style: TextButton.styleFrom(
                        foregroundColor: SovereignColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: SovereignColors.accentDanger,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: tt.bodySmall?.copyWith(
                      color: SovereignColors.accentDanger,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: (_busy || _wordCount != 24) ? null : _restore,
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.soulLumina,
              foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 52),
              disabledBackgroundColor: SovereignColors.surfaceGlass,
            ),
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : const Text('Restore identity'),
          ),
        ],
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.trim().isNotEmpty) {
      _controller.text = DeviceRecoveryCodec.normalize(text).join(' ');
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }
}
