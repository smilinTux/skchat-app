import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/mode_c_service.dart';

/// Operator review + counter-sign screen for Mode C (non-federated peer accept).
///
/// The operator sees each pending accept assertion, reads the 6-digit SAS aloud
/// to the peer over a second channel to catch a MITM key swap, then counter-signs
/// to admit them. The heavy crypto is server-side (guest_accept.py); this screen
/// is the human review gate.
class ModeCReviewScreen extends ConsumerStatefulWidget {
  const ModeCReviewScreen({super.key});

  @override
  ConsumerState<ModeCReviewScreen> createState() => _ModeCReviewScreenState();
}

class _ModeCReviewScreenState extends ConsumerState<ModeCReviewScreen> {
  bool _busy = true;
  String? _error;
  List<ModeCPending> _pending = const [];
  List<Map<String, dynamic>> _admitted = const [];
  final Set<String> _working = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final svc = ref.read(modeCServiceProvider);
      final items = await svc.pending();
      final adm = await svc.admitted();
      if (!mounted) return;
      setState(() {
        _pending = items;
        _admitted = adm;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not load join requests (operator origin only).';
      });
    }
  }

  Future<void> _revoke(String peerFp) async {
    setState(() => _working.add(peerFp));
    try {
      await ref.read(modeCServiceProvider).revoke(peerFp);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Peer trust revoked.')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Revoke failed.')));
    } finally {
      if (mounted) setState(() => _working.remove(peerFp));
    }
  }

  Future<void> _counterSign(ModeCPending p) async {
    setState(() => _working.add(p.jti));
    try {
      await ref.read(modeCServiceProvider).counterSign(p.jti);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Peer admitted (join record signed).')),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Counter-sign failed.')));
    } finally {
      if (mounted) setState(() => _working.remove(p.jti));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join requests'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        textAlign: TextAlign.center, style: tt.bodyMedium),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('Pending', style: tt.labelLarge),
                    const SizedBox(height: 8),
                    if (_pending.isEmpty)
                      Text('No pending join requests.', style: tt.bodyMedium)
                    else
                      ..._pending.expand((p) => [
                            _PendingCard(
                              p: p,
                              busy: _working.contains(p.jti),
                              onCounterSign: () => _counterSign(p),
                            ),
                            const SizedBox(height: 12),
                          ]),
                    const SizedBox(height: 20),
                    Text('Admitted peers', style: tt.labelLarge),
                    const SizedBox(height: 8),
                    if (_admitted.isEmpty)
                      Text('No admitted peers yet.', style: tt.bodyMedium)
                    else
                      ..._admitted.map((a) => _AdmittedTile(
                            peerFp: (a['peer_fp'] as String?) ?? '',
                            operatorId: (a['operator_id'] as String?) ?? '',
                            busy: _working.contains(a['peer_fp']),
                            onRevoke: () => _revoke((a['peer_fp'] as String?) ?? ''),
                          )),
                  ],
                ),
    );
  }
}

class _PendingCard extends StatelessWidget {
  const _PendingCard(
      {required this.p, required this.busy, required this.onCounterSign});

  final ModeCPending p;
  final bool busy;
  final VoidCallback onCounterSign;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    // group the SAS 3-3 for readability (e.g. 278 117).
    final sas = p.sas.length == 6
        ? '${p.sas.substring(0, 3)} ${p.sas.substring(3)}'
        : p.sas;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Peer wants to join', style: tt.titleMedium),
            const SizedBox(height: 4),
            Text('Fingerprint: ${p.peerFp}',
                style: tt.bodySmall?.copyWith(fontFamily: 'monospace'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            Text('Confirm this code with them out-of-band:', style: tt.bodySmall),
            const SizedBox(height: 4),
            Text(sas,
                style: tt.headlineMedium
                    ?.copyWith(letterSpacing: 4, color: cs.primary)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: busy ? null : onCounterSign,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_user_outlined),
                label: Text(busy ? 'Signing…' : 'Counter-sign & admit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdmittedTile extends StatelessWidget {
  const _AdmittedTile({
    required this.peerFp,
    required this.operatorId,
    required this.busy,
    required this.onRevoke,
  });

  final String peerFp;
  final String operatorId;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final short = peerFp.length > 16 ? '${peerFp.substring(0, 16)}…' : peerFp;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.verified_user),
      title: Text(short, style: tt.bodyMedium?.copyWith(fontFamily: 'monospace')),
      subtitle: operatorId.isEmpty ? null : Text(operatorId, style: tt.bodySmall),
      trailing: busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(onPressed: onRevoke, child: const Text('Revoke')),
    );
  }
}
