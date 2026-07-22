import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme/sovereign_colors.dart';
import '../../services/peer_trust_store.dart';
import '../../services/safety_number.dart';
import '../../services/self_identity_provider.dart';
import 'widgets/trust_badge.dart';

/// Opens the safety-number verify-peer bottom sheet for [peerId].
///
/// Shows the peer's current trust tier, the shared safety number derived
/// from both fingerprints, the raw peer fingerprint, and a QR encoding of it
/// for out-of-band comparison. When the peer's key has rotated since the
/// last verification, a warning leads the sheet. "Mark verified" promotes
/// the CURRENT fingerprint to amber; it is disabled when there is no
/// fingerprint to anchor the verification to.
Future<void> showVerifyPeerSheet(
  BuildContext context,
  WidgetRef ref, {
  required String peerId,
  required String peerName,
  required String? peerFingerprint,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SovereignColors.surfaceRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _VerifyPeerSheet(
      peerId: peerId,
      peerName: peerName,
      peerFingerprint: peerFingerprint,
    ),
  );
}

class _VerifyPeerSheet extends ConsumerStatefulWidget {
  const _VerifyPeerSheet({
    required this.peerId,
    required this.peerName,
    required this.peerFingerprint,
  });

  final String peerId;
  final String peerName;
  final String? peerFingerprint;

  @override
  ConsumerState<_VerifyPeerSheet> createState() => _VerifyPeerSheetState();
}

class _VerifyPeerSheetState extends ConsumerState<_VerifyPeerSheet> {
  bool _loading = true;
  bool _keyChanged = false;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final changed = await ref
        .read(peerTrustResolverProvider)
        .isKeyChanged(widget.peerId, widget.peerFingerprint);
    if (!mounted) return;
    setState(() {
      _keyChanged = changed;
      _loading = false;
    });
  }

  Future<void> _markVerified() async {
    final fp = widget.peerFingerprint;
    if (fp == null || fp.isEmpty) return;
    setState(() => _verifying = true);
    await ref.read(peerTrustControllerProvider).markVerified(widget.peerId, fp);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final fp = widget.peerFingerprint;
    final hasFingerprint = fp != null && fp.isNotEmpty;
    final selfFp = ref.watch(selfIdentityProvider).valueOrNull?.fingerprint ??
        '';
    final tierAsync = ref.watch(peerTrustTierProvider(
      (peerId: widget.peerId, fingerprint: fp),
    ));
    final tier = tierAsync.valueOrNull ?? PeerTrustTier.red;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.peerName,
                    style: const TextStyle(
                      color: SovereignColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TrustBadge(tier: selfTierForPeer(tier), compact: false),
              ],
            ),
            const SizedBox(height: 16),
            if (!_loading && _keyChanged) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: SovereignColors.accentDanger.withValues(alpha: 0.12),
                  border: Border.all(
                    color: SovereignColors.accentDanger,
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  "Safety number changed. The peer's key differs from "
                  'what you verified before. Only mark verified again if '
                  'you trust this change.',
                  style: TextStyle(
                    color: SovereignColors.accentDanger,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            const Text(
              'Safety number',
              style: TextStyle(
                color: SovereignColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              safetyNumber(selfFp, fp ?? ''),
              style: const TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 18,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Peer fingerprint',
              style: TextStyle(
                color: SovereignColors.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasFingerprint ? fp : 'unknown',
              style: const TextStyle(
                color: SovereignColors.textSecondary,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
            if (hasFingerprint) ...[
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrImageView(
                    data: fp,
                    size: 160,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: hasFingerprint && !_verifying
                    ? _markVerified
                    : null,
                child: const Text('Mark verified'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
