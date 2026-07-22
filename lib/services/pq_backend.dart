import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sk_pqc/sk_pqc.dart';

/// Post-quantum backend availability + a total (never-throwing) constructor.
///
/// The real hybrid KEM ([HybridKemImpl]) loads its ML-KEM-768 backend eagerly in
/// its constructor: native = liboqs via dart:ffi, web = noble via JS-interop. On
/// a device where that backend cannot load (liboqs not installed, noble not
/// bundled) the constructor THROWS `sk_pqc: could not load liboqs`. Because the
/// PQ services are built inside Riverpod provider bodies, that throw used to
/// escape the provider read and crash the conversation screen (Flutter rendered
/// its grey ErrorWidget in place of the whole app bar).
///
/// This module makes PQ construction total: [createHybridKemOrUnavailable]
/// catches the load failure and returns an [UnavailableHybridKem] stand-in whose
/// every KEM op throws a (caught, downstream) [SkPqcError]. The app's send /
/// receive paths already treat a KEM failure as a negotiated downgrade to the
/// classical path (`PqPrekeyService.ensureKeyPair` catches → no keypair →
/// classical; `PqConversationService.openIncoming` catches → placeholder), so an
/// unavailable backend simply runs classical-only instead of crashing.

/// A [HybridKem] used when the real PQ backend cannot load. It is constructible
/// (so the providers never throw) but every KEM operation fails with a caught
/// [SkPqcError], which the send/receive paths already handle as classical.
class UnavailableHybridKem extends HybridKem {
  static const _err =
      SkPqcError('sk_pqc: PQ backend unavailable on this device (classical-only)');

  @override
  String get info => HybridCombiner.defaultInfo;

  // async bodies so the failure surfaces as a rejected Future (the HybridKem
  // contract), which `await` in the send/receive paths already catches.
  @override
  Future<HybridKeyPair> generateKeyPair() async => throw _err;

  @override
  Future<EncapResult> encapsulate(Uint8List peerPublicKey) async => throw _err;

  @override
  Future<Uint8List> decapsulate(Uint8List ciphertext, Uint8List privateKey) async =>
      throw _err;
}

/// Construct the platform hybrid KEM, or an [UnavailableHybridKem] when the
/// backend can't load. NEVER throws.
HybridKem createHybridKemOrUnavailable() {
  try {
    return HybridKemImpl();
  } catch (_) {
    return UnavailableHybridKem();
  }
}

/// The app-wide hybrid KEM, guarded so a missing PQ backend degrades to
/// classical instead of crashing. All PQ services resolve their KEM through this
/// provider so the load is attempted exactly once and its failure is contained.
final hybridKemProvider =
    Provider<HybridKem>((ref) => createHybridKemOrUnavailable());

/// Whether a real post-quantum backend loaded on this device (false → the app
/// runs classical-only). Handy for diagnostics / a future "PQ unavailable" hint.
final pqBackendAvailableProvider = Provider<bool>(
    (ref) => ref.watch(hybridKemProvider) is! UnavailableHybridKem);
