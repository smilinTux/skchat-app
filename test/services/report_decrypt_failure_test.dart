import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:skchat/services/pq_prekey_service.dart';

/// Decrypt-failure NACK, app side (coord 4c054eab, criterion 1).
///
/// When [PqConversationService.openIncomingDetailed] cannot open a sealed
/// `pqdm2`/`pqdm1` token (no slot for this device, or the AEAD open fails), it
/// fires a best-effort, throttled, fire-and-forget NACK to the daemon so the
/// SENDER re-pulls THIS device's freshly-republished bundle immediately instead
/// of waiting for the 6h TTL. A successful open never NACKs; a report that
/// fails is swallowed and never blocks the render.
///
/// Two layers are exercised:
///  1. The wiring in `openIncomingDetailed` (locked -> fires once; success ->
///     never fires) via a fake prekey service that counts NACKs.
///  2. The `PqPrekeyService.reportDecryptFailure` method itself (POSTs once,
///     throttles the repeat, swallows a transport error) via a recording Dio.

/// A fake prekey service that provides just enough for the locked-token paths:
/// a keypair is present (so we reach the open attempt, not the no-key
/// placeholder) and every NACK is counted.
class _FakePrekeyService implements PqPrekeyService {
  int reportCalls = 0;
  final List<String> reportedPeers = [];

  @override
  Future<bool> ensureKeyPair() async => true;

  @override
  Uint8List? get privateKey => Uint8List.fromList(List<int>.filled(2432, 0));

  @override
  String? get keyId => 'aabbccddeeff0011';

  @override
  Future<bool> reportDecryptFailure(String peerShort, {String? messageId}) async {
    reportCalls++;
    reportedPeers.add(peerShort);
    return true;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A Dio adapter that records POSTs to the decrypt-failed endpoint and can be
/// told to fail (to prove the NACK swallows transport errors).
class _RecordingAdapter implements HttpClientAdapter {
  int nackPosts = 0;
  bool fail = false;
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.contains('/dm/decrypt-failed')) {
      nackPosts++;
      if (options.data is Map) {
        bodies.add(Map<String, dynamic>.from(options.data as Map));
      }
    }
    if (fail) {
      throw DioException(requestOptions: options, message: 'transport down');
    }
    return ResponseBody.fromString(
      '{"ok":true,"refreshed":true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

PqPrekeyService _serviceWith(_RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:9384'))
    ..httpClientAdapter = adapter;
  return PqPrekeyService(
    storage: const FlutterSecureStorage(),
    baseUrl: 'http://localhost:9384',
    deviceId: 'test-device',
    dio: dio,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('openIncomingDetailed fires the NACK on a locked token', () {
    test('a pqdm1 token this device cannot open triggers exactly one NACK',
        () async {
      final fake = _FakePrekeyService();
      final svc = PqConversationService(prekeys: fake, localShort: 'chef');

      final r = await svc.openIncomingDetailed(
        'lumina',
        'pqdm1:x25519-mlkem768:NOTFORUS',
      );

      expect(r.opened, isFalse);
      expect(r.text, PqConversationService.lockedCantOpenText);
      expect(fake.reportCalls, 1, reason: 'a locked open must NACK once');
      // The reporting device (this device) is the peer the daemon re-pulls.
      expect(fake.reportedPeers.single, 'chef');
    });

    test('a malformed pqdm2 token this device cannot open triggers one NACK',
        () async {
      final fake = _FakePrekeyService();
      final svc = PqConversationService(prekeys: fake, localShort: 'chef');

      final r = await svc.openIncomingDetailed(
        'lumina',
        '${PqDmCodec.pqdm2Prefix}bogus.header.body',
      );

      expect(r.opened, isFalse);
      expect(fake.reportCalls, 1);
      expect(fake.reportedPeers.single, 'chef');
    });

    test('a successfully opened (non-token) body never NACKs', () async {
      final fake = _FakePrekeyService();
      final svc = PqConversationService(prekeys: fake, localShort: 'chef');

      final r = await svc.openIncomingDetailed('lumina', 'plain hello');

      expect(r.opened, isTrue);
      expect(r.text, 'plain hello');
      expect(fake.reportCalls, 0, reason: 'a successful open must not NACK');
    });
  });

  group('PqPrekeyService.reportDecryptFailure', () {
    test('POSTs the reporting peer to /api/v1/dm/decrypt-failed once', () async {
      final adapter = _RecordingAdapter();
      final svc = _serviceWith(adapter);

      final ok = await svc.reportDecryptFailure('chef', messageId: 'm-1');

      expect(ok, isTrue);
      expect(adapter.nackPosts, 1);
      expect(adapter.bodies.single['peer'], 'chef');
      expect(adapter.bodies.single['message_id'], 'm-1');
    });

    test('a repeat NACK for the same peer inside the window is throttled',
        () async {
      final adapter = _RecordingAdapter();
      final svc = _serviceWith(adapter);

      expect(await svc.reportDecryptFailure('chef'), isTrue);
      expect(await svc.reportDecryptFailure('chef'), isFalse,
          reason: 'the in-window repeat must collapse');
      expect(adapter.nackPosts, 1, reason: 'exactly one POST inside the window');
    });

    test('a transport failure is swallowed (returns false, never throws)',
        () async {
      final adapter = _RecordingAdapter()..fail = true;
      final svc = _serviceWith(adapter);

      final ok = await svc.reportDecryptFailure('chef');

      expect(ok, isFalse);
      expect(adapter.nackPosts, 1, reason: 'the POST was attempted');
    });
  });
}
