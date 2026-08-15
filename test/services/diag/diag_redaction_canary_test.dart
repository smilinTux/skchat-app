// The redaction canary: no client secret may ever reach a diagnostic event.
//
// Card 893f55fa (Obs P1.3). Spec section 7, "Security and privacy", in
// docs/superpowers/specs/2026-08-14-client-observability-ai-support-design.md.
//
// ─────────────────────────────────────────────────────────────────────────
// WHY THIS FILE IS THE ENFORCEMENT POINT, NOT A BELT-AND-BRACES EXTRA
// ─────────────────────────────────────────────────────────────────────────
// The spec's safety claim is "redaction by whitelist by construction": the
// code catalog is the only path into a snapshot, so no schema slot can hold
// a secret. Half of that is literally true at the type level and half of it
// is not, and the half that is not is what this file exists to cover.
//
// True at the type level: which KEYS a code may carry. DiagEvent.tryCreate
// runs DiagCodes.firstViolation, so an event with an undeclared field, or a
// declared field of the wrong type, cannot exist. That is a real, compiled,
// unbypassable constraint.
//
// NOT true at the type level (diag_codes.dart):
//
//     factory DiagFieldSpec.string(String key, {bool optional = false}) =>
//         DiagFieldSpec._(
//           key,
//           typeName: 'String',
//           isValidValue: (v) => v is String,
//           optional: optional,
//         );
//
// `isValidValue` accepts ANY String. `host`, `pathTemplate`, `buildId` and
// `errorType` are String slots that will hold whatever a call site puts in
// them. The catalog constrains which fields exist; it does not and cannot
// constrain what a future field's contents are. Today the only thing
// standing between `DiagFieldSpec.string('sessionToken')` and a bearer JWT
// in a diagnostic snapshot uploaded to a server is a reviewer noticing.
//
// This file is the automated half of that review. It fails at PR time on:
//
//   1. a new String field in the catalog that nobody has justified in
//      _stringFields below (you cannot add a free-form string slot without
//      writing down why it cannot hold a secret);
//   2. a String field whose NAME is secret-shaped (token, jwt, secret,
//      credential, privkey and friends: see _secretShapedNames);
//   3. a new DiagFieldSpec factory that widens the type surface beyond the
//      five reviewed scalar/enum shapes;
//   4. an actual planted secret value appearing in any diag serialization
//      path;
//   5. a new serialization member landing in lib/services/diag/ without
//      being registered with this canary (see _encoderSymbolGuard).
//
// This is deliberately NOT a blacklist scrubber. Nothing here strips or
// masks anything at runtime. If a secret can reach a buffer, the schema or
// the call site is wrong and the fix belongs there; the canary's only job
// is to make that wrongness loud before it merges.
//
// Anti-vacuity: a canary that plants nothing and scans nothing passes
// silently forever. Every planted secret is READ BACK from the store it was
// planted in, and the scanner itself is positive-controlled, so this file
// cannot pass by doing nothing.
//
// Extension: the ring buffer, persisted tail and snapshot encoder land in
// cards b62da57c / 7cebe96a / 270ea324. Adding them here is adding one
// entry to _encoders (and, if a new secret store arrives with them, one
// entry to _seedEverySecretStore). _encoderSymbolGuard makes that
// mandatory rather than optional.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sk_pqc/sk_pqc.dart';
import 'package:skchat/core/crypto/pgp_bridge.dart';
import 'package:skchat/features/guest/guest_link.dart';
import 'package:skchat/services/audience_token_service.dart';
import 'package:skchat/services/device_recovery_codec.dart';
import 'package:skchat/services/diag/diag_codes.dart';
import 'package:skchat/services/diag/diag_event.dart';
import 'package:skchat/services/guest_key_store.dart';
import 'package:skchat/services/identity_service.dart';
import 'package:skchat/services/livekit_call_service.dart';
import 'package:skchat/services/operator_session_store.dart';
import 'package:skchat/services/operator_token.dart';
import 'package:skchat/services/pq_prekey_service.dart';
import 'package:skchat/services/skcomms_client.dart';

// ─────────────────────────────────────────────────────────────────────────
// 1. The planted secrets
// ─────────────────────────────────────────────────────────────────────────

/// A fake secret planted in one real client secret store.
///
/// [source] is the file that owns the store, so a reader can check this
/// list against the codebase rather than trusting it. [readBack] is what
/// the store returned AFTER planting: if seeding silently failed, the
/// read-back does not match and "no secret leaked" would be vacuously true.
typedef PlantedSecret = ({
  String label,
  String source,
  String planted,
  String readBack,
});

/// Marker embedded in every planted value that can carry one, so a hit in a
/// serialized buffer is unambiguous and greppable.
const _marker = 'CANARY7f31b0';

// A note on the SHAPE of the planted values below.
//
// They deliberately do NOT look like real credentials: no base64 JWT
// header prefix, no ASCII-armor header lines. The repo's
// secret scanners (gitleaks, GitGuardian) match on exactly those shapes and
// would flag this file forever, which is the scanners working correctly:
// committing something credential-shaped to prove secrets are not committed
// would be a silly way to lose the signal on the checks that guard the rest
// of the tree. Shape buys this canary nothing. Every assertion here is an
// exact-substring search, so all a planted value has to be is unique, and
// each is planted through its store's real API, so the STORE is real even
// though the value is obviously synthetic.

/// Every client secret store, per spec section 2 ("Secrets on the client",
/// which section 7 points at as the reason redaction is a whitelist), each
/// seeded through the REAL store API rather than a stand-in.
///
/// flutter_secure_storage is swapped for its own in-memory test platform
/// (`setMockInitialValues`), so IdentityService.save, PqPrekeyService's
/// keygen path and SecureGuestKeyStore all execute their real read/write
/// code against it.
Future<List<PlantedSecret>> _seedEverySecretStore() async {
  final secure = <String, String>{};
  FlutterSecureStorage.setMockInitialValues(secure);
  const storage = FlutterSecureStorage();

  final planted = <PlantedSecret>[];

  // 1. Operator raw token (web localStorage / native in-memory).
  const operatorRaw = 'skop_${_marker}_OPERATOR_RAW_TOKEN';
  setOperatorToken(operatorRaw);
  planted.add((
    label: 'operator raw token',
    source: 'lib/services/operator_token.dart',
    planted: operatorRaw,
    readBack: operatorToken() ?? '',
  ));

  // 2. Minted operator SESSION JWT. A distinct slot from (1) on purpose;
  //    see the header of operator_session_store.dart.
  const sessionJwt = 'sessionjwt.$_marker.OPERATOR_SESSION.sig';
  setOperatorSessionToken(sessionJwt);
  planted.add((
    label: 'operator session JWT',
    source: 'lib/services/operator_session_store.dart',
    planted: sessionJwt,
    readBack: operatorSessionToken() ?? '',
  ));

  // 3. Capauth audience token, held in AudienceTokenService's in-memory
  //    cache. Minted through a canned adapter so the value lands in the
  //    real private cache by the real code path.
  const audienceToken = 'aud_${_marker}_AUDIENCE_BEARER';
  final audienceDio = Dio(BaseOptions(baseUrl: 'http://localhost:9384'))
    ..httpClientAdapter = _CannedJson({
      'token': audienceToken,
      'audience': 'skchat',
      'expires_at':
          DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
    });
  final audienceService = AudienceTokenService(
    client: SKCommsClient(dio: audienceDio),
  );
  await audienceService.mint('skchat');
  // Second mint: served from the in-memory cache, so the read-back proves
  // the secret is resident in the service, not merely echoed back by the
  // fake transport.
  final audienceCached = await audienceService.mint('skchat');
  planted.add((
    label: 'capauth audience token',
    source: 'lib/services/audience_token_service.dart',
    planted: audienceToken,
    readBack: audienceCached ?? '',
  ));

  // 4. PGP identity private key, in the OS keychain via IdentityService.
  const pgpPrivate = 'pgpprivatekeybody.$_marker.PGP_IDENTITY_PRIVATE';
  await IdentityService(storage).save(
    const PgpKeyPair(
      fingerprint: 'AAAA BBBB CCCC DDDD EEEE  FFFF 0000 1111 2222 3333',
      publicKeyPem: 'pgppublickeybody.canary.PGP_IDENTITY_PUBLIC',
      privateKeyPem: pgpPrivate,
    ),
  );
  planted.add((
    label: 'PGP identity private key',
    source: 'lib/services/identity_service.dart',
    planted: pgpPrivate,
    readBack: (await IdentityService(storage).load())?.privateKeyPem ?? '',
  ));

  // 5. PQ hybrid prekey private key. The real PqPrekeyService writes it,
  //    hex-encoded, to secure storage; only the KEM is faked, so the
  //    storage key name and encoding are the app's own and stay correct
  //    even if they are renamed.
  final pqPrivateBytes = Uint8List.fromList(
    utf8.encode('${_marker}_PQ_HYBRID_PRIVATE_KEY_MATERIAL'),
  );
  final pqService = PqPrekeyService(
    storage: storage,
    baseUrl: 'http://localhost:9384',
    deviceId: 'canary-device',
    kem: _FixedHybridKem(
      Uint8List.fromList(utf8.encode('canary-public')),
      pqPrivateBytes,
    ),
  );
  expect(
    await pqService.ensureKeyPair(),
    isTrue,
    reason: 'prekey seeding must actually store key material',
  );
  final pqPrivateHex = _hex(pqPrivateBytes);
  planted.add((
    label: 'PQ hybrid prekey private key (hex)',
    source: 'lib/services/pq_prekey_service.dart',
    planted: pqPrivateHex,
    readBack: _hex(pqService.privateKey ?? Uint8List(0)),
  ));

  // 6. Device operator private key (base64 P-256 scalar d), the thing the
  //    recovery phrase encodes. Written through the real keystore seam at
  //    the real key name (`skchat.guest.priv`, guest_identity_io.dart:18).
  const deviceKeyName = 'skchat.guest.priv';
  final deviceScalar = base64.encode(
    utf8.encode('${_marker}_DEVICE_P256_SCALAR_D_32B'),
  );
  const keyStore = SecureGuestKeyStore(storage);
  await keyStore.write(deviceKeyName, deviceScalar);
  planted.add((
    label: 'device operator private key',
    source: 'lib/services/guest_key_store.dart',
    planted: deviceScalar,
    readBack: await keyStore.read(deviceKeyName) ?? '',
  ));

  // 7. Guest invite JWT and its `#k=` fragment secret.
  const guestJwt = 'invitejwt.$_marker.GUEST_INVITE.sig';
  const guestFragment = 'k_${_marker}_GUEST_FRAGMENT_SECRET';
  final link = GuestLink.parse('$guestJwt&k=$guestFragment');
  planted.add((
    label: 'guest invite JWT',
    source: 'lib/features/guest/guest_link.dart',
    planted: guestJwt,
    readBack: link.token,
  ));
  planted.add((
    label: 'guest link fragment secret',
    source: 'lib/features/guest/guest_link.dart',
    planted: guestFragment,
    readBack: link.fragmentSecret ?? '',
  ));

  // 8. LiveKit room token, held in memory for the life of a call.
  const livekitToken = 'roomjwt.$_marker.LIVEKIT_ROOM.sig';
  final livekit = LiveKitTokenResult.fromJson(const <String, dynamic>{
    'token': livekitToken,
    'room': 'dm-canary',
    'identity': 'canary',
  });
  planted.add((
    label: 'LiveKit room token',
    source: 'lib/services/livekit_call_service.dart',
    planted: livekitToken,
    readBack: livekit.token,
  ));

  // 9. The 24-word recovery phrase. BIP39 words cannot carry the marker, so
  //    the searched value is the full phrase (a 24-word string will not
  //    occur by accident) plus the marker-bearing entropy it encodes.
  //    Individual words are deliberately NOT searched: "camera", "silent"
  //    and friends are ordinary English and would false-positive forever.
  final recoveryEntropy = Uint8List.fromList(
    utf8.encode('CANARY-RECOVERY-ENTROPY-32BYTES!'),
  );
  final phrase = DeviceRecoveryCodec.entropyToWords(recoveryEntropy).join(' ');
  planted.add((
    label: '24-word recovery phrase',
    source: 'lib/services/device_recovery_codec.dart',
    planted: phrase,
    readBack:
        DeviceRecoveryCodec.entropyToWords(recoveryEntropy).join(' '),
  ));
  planted.add((
    label: 'recovery phrase entropy (hex)',
    source: 'lib/services/device_recovery_codec.dart',
    planted: _hex(recoveryEntropy),
    readBack: _hex(DeviceRecoveryCodec.wordsToEntropy(phrase.split(' '))),
  ));

  return planted;
}

/// Returns the labels of every planted secret found in [haystack].
List<String> _findSecrets(String haystack, List<PlantedSecret> secrets) => [
      for (final s in secrets)
        if (haystack.contains(s.planted)) s.label,
      // A bare marker hit means a secret arrived in some mangled form
      // (truncated, re-cased, re-encoded) that an exact-substring check
      // would miss. Still a leak.
      if (haystack.contains(_marker) &&
          !secrets.any((s) => haystack.contains(s.planted)))
        'raw marker $_marker (mangled or partial secret)',
    ];

// ─────────────────────────────────────────────────────────────────────────
// 2. The serialization paths
// ─────────────────────────────────────────────────────────────────────────

/// One way a [DiagEvent] can become bytes or text.
///
/// REGISTER EVERY NEW ONE HERE. `_encoderSymbolGuard` below fails the suite
/// if a serialization member appears in lib/services/diag/ that is not
/// covered, so the ring buffer (b62da57c), persisted tail (7cebe96a) and
/// snapshot encoder (270ea324) cannot land without extending this list.
typedef DiagEncoder = ({String name, String Function(DiagEvent) encode});

final List<DiagEncoder> _encoders = [
  // The only string-producing member DiagEvent exposes today.
  (name: 'DiagEvent.toString()', encode: (DiagEvent e) => e.toString()),
  // What any encoder ultimately walks: the fields map, recursively, keys
  // and values both.
  (name: 'fields map (deep walk)', encode: (DiagEvent e) => _deepWalk(e.fields)),
  // The wire shape spec 4.1 declares, `{seq, ts, level, category, code,
  // fields}`. Written here rather than imported so this canary does not
  // depend on diag_log.dart's internals (that file is in flight on another
  // branch); when its real encoder lands, add it as a further entry.
  (
    name: 'canonical JSON (spec 4.1 wire shape)',
    encode: (DiagEvent e) => jsonEncode({
      'seq': e.seq,
      'ts': e.ts.toIso8601String(),
      'level': e.level.name,
      'category': e.category.name,
      'code': e.code,
      'fields': {
        for (final entry in e.fields.entries)
          entry.key: entry.value is num || entry.value is bool
              ? entry.value
              : entry.value.toString(),
      },
    }),
  ),
];

/// Every key and every value in a nested structure, flattened to one
/// string, so a secret nested inside a map or list is still visible to the
/// scanner.
String _deepWalk(Object? value) {
  if (value is Map) {
    return value.entries
        .map((e) => '${_deepWalk(e.key)}=${_deepWalk(e.value)}')
        .join(' ');
  }
  if (value is Iterable) {
    return value.map(_deepWalk).join(' ');
  }
  return '$value';
}

// ─────────────────────────────────────────────────────────────────────────
// 3. The reviewed String-field inventory (the actual gate)
// ─────────────────────────────────────────────────────────────────────────

/// Every `String` field in [DiagCodes.catalog], keyed `code.field`, with a
/// realistic sample value and a written reason it cannot hold a secret.
///
/// This map is the merge gate. `DiagFieldSpec.string` accepts any String
/// (see the header), so a new free-form string slot is invisible to the
/// type system; it is visible here, because the suite goes red until
/// somebody adds the entry and states why the slot is safe. "It is only
/// ever set to a constant at the one call site" is a valid reason. "It
/// holds whatever the server sent back" is not.
const _stringFields = <String, ({String sample, String why})>{
  'net.request_failed.host': (
    sample: 'skworld-100',
    why: 'hostname of an operator-owned backend; never userinfo or a query',
  ),
  'net.request_failed.pathTemplate': (
    sample: '/api/v1/messages/{id}',
    why: 'TEMPLATE, not the resolved path: ids and query strings are '
        'substituted out before the event is built',
  ),
  'net.request_failed.method': (
    sample: 'POST',
    why: 'HTTP verb, a closed set',
  ),
  'net.request_slow.host': (
    sample: 'skworld-100',
    why: 'same as net.request_failed.host',
  ),
  'net.request_slow.pathTemplate': (
    sample: '/api/v1/messages/{id}',
    why: 'same as net.request_failed.pathTemplate',
  ),
  'call.state.state': (
    sample: 'connected',
    why: 'LiveKit ConnectionState name, a closed set',
  ),
  'call.state.room': (
    sample: 'dm-9f2c1a',
    why: 'server-derived room name; the room TOKEN is a separate value and '
        'has no slot in this catalog',
  ),
  'call.quality.quality': (
    sample: 'poor',
    why: 'LiveKit ConnectionQuality name, a closed set',
  ),
  'call.quality.participant': (
    sample: 'capauth://agent/lumina',
    why: 'peer capauth URI, admitted deliberately by spec 7 (operator-owned '
        'infrastructure, triage is useless without it). Guest DISPLAY names '
        'and guest link material stay excluded',
  ),
  'call.media_silent.directionEnum': (
    sample: 'inbound',
    why: 'inbound/outbound, a closed set (the name says enum on purpose)',
  ),
  'voice.turn.stage': (
    sample: 'stt',
    why: 'pipeline stage name, a closed set; never the transcript',
  ),
  'health.change.dep': (
    sample: 'stt',
    why: 'dependency registry name, a closed set',
  ),
  'health.change.from': (
    sample: 'unknown',
    why: 'health state name, a closed set',
  ),
  'health.change.to': (
    sample: 'down',
    why: 'health state name, a closed set',
  ),
  'health.change.probe': (
    sample: 'http',
    why: 'probe kind, a closed set; never the probe response body',
  ),
  'beat.missed.loop': (
    sample: 'skcomms.poll',
    why: 'heartbeat registry loop name, a closed set',
  ),
  'store.box_corrupt.box': (
    sample: 'diag_tail',
    why: 'Hive box name, a closed set; never box CONTENTS',
  ),
  'store.flush_failed.box': (
    sample: 'diag_tail',
    why: 'same as store.box_corrupt.box',
  ),
  'lifecycle.start.buildId': (
    sample: '2026.8.15+417',
    why: 'build stamp from the bundle, identical on every install',
  ),
  'lifecycle.start.errorType': (
    sample: 'DioException',
    why: 'runtimeType name only. Spec 7: the trace TEXT and the exception '
        'MESSAGE are never representable, which is the whole point of the '
        'catalog having no message slot',
  ),
  'lifecycle.resume.buildId': (
    sample: '2026.8.15+417',
    why: 'same as lifecycle.start.buildId',
  ),
  'lifecycle.resume.errorType': (
    sample: 'DioException',
    why: 'same as lifecycle.start.errorType',
  ),
  'lifecycle.error.buildId': (
    sample: '2026.8.15+417',
    why: 'same as lifecycle.start.buildId',
  ),
  'lifecycle.error.errorType': (
    sample: 'DioException',
    why: 'same as lifecycle.start.errorType',
  ),
};

/// Field-name shapes that must never appear on a `String` slot.
///
/// A name-shape guard on the SCHEMA, not a value scrubber on the DATA: it
/// rejects `DiagFieldSpec.string('sessionToken')` at review time and never
/// touches a runtime value. Tripping it on a genuinely innocent name is the
/// system working; add the field to [_secretShapedNameExemptions] with a
/// reason and the reviewer sees exactly what was waved through.
const _secretShapedNames = <String>[
  'token',
  'jwt',
  'secret',
  'password',
  'passphrase',
  'phrase',
  'mnemonic',
  'credential',
  'bearer',
  'cookie',
  'privkey',
  'private',
  'signature',
  'seedphrase',
  'apikey',
  'authorization',
  'keymaterial',
];

/// `code.field` entries allowed to trip [_secretShapedNames], each with a
/// reason. Empty today, and it should stay hard to add to.
const _secretShapedNameExemptions = <String, String>{};

/// The reviewed set of value shapes the catalog may declare. A new
/// `DiagFieldSpec` factory (a map, a list, a `dynamic`, a raw object) is a
/// new way for structure to enter a snapshot, so it lands here or it goes
/// red.
const _allowedTypeNames = <String>{
  'String',
  'int',
  'bool',
  'NetFailureKind',
  'CredentialKind',
};

/// Non-String sample values, by declared type name. These slots cannot hold
/// a secret by construction, so they need no inventory entry.
const _typedSamples = <String, Object>{
  'int': 4242,
  'bool': true,
  'NetFailureKind': NetFailureKind.connectTimeout,
  'CredentialKind': CredentialKind.session,
};

/// Build a valid, realistic, secret-free field map for [spec], drawing
/// every String value from [_stringFields]. Throws (red) on an unknown
/// String field, which is the completeness half of the gate.
Map<String, Object> _sampleFieldsFor(DiagCodeSpec spec) {
  final fields = <String, Object>{};
  for (final field in spec.fields) {
    if (field.typeName == 'String') {
      final entry = _stringFields['${spec.code}.${field.key}'];
      if (entry == null) {
        fail(
          'Catalog code "${spec.code}" declares String field "${field.key}", '
          'which is not in _stringFields in this file.\n'
          'DiagFieldSpec.string accepts ANY String, so the type system does '
          'not constrain what this slot holds. Add an entry with a sample '
          'value and a written reason it cannot carry a secret, or remove '
          'the field. See spec section 7.',
        );
      }
      fields[field.key] = entry.sample;
      continue;
    }
    final sample = _typedSamples[field.typeName];
    if (sample == null) {
      fail(
        'Catalog code "${spec.code}" field "${field.key}" declares type '
        '"${field.typeName}", which this canary has no sample for. A new '
        'field type is a new shape of data entering a snapshot: add it to '
        '_allowedTypeNames and _typedSamples after reviewing it.',
      );
    }
    fields[field.key] = sample;
  }
  return fields;
}

// ─────────────────────────────────────────────────────────────────────────
// 4. Test helpers
// ─────────────────────────────────────────────────────────────────────────

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A Dio adapter that answers every request with one canned JSON body.
class _CannedJson implements HttpClientAdapter {
  _CannedJson(this.body);

  final Object body;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
}

/// A hybrid KEM yielding a fixed keypair, so [PqPrekeyService] stores known
/// key material by its real code path. Mirrors `_FixedHybridKem` in
/// test/services/pq_prekey_publish_test.dart.
class _FixedHybridKem extends HybridKem {
  _FixedHybridKem(this._pub, this._priv);

  final Uint8List _pub;
  final Uint8List _priv;

  @override
  String get info => HybridCombiner.defaultInfo;

  @override
  Future<HybridKeyPair> generateKeyPair() async =>
      HybridKeyPair(publicKey: _pub, privateKey: _priv);

  @override
  Future<EncapResult> encapsulate(Uint8List peerPublicKey) async =>
      throw const SkPqcError('not used by the redaction canary');

  @override
  Future<Uint8List> decapsulate(
    Uint8List ciphertext,
    Uint8List privateKey,
  ) async =>
      throw const SkPqcError('not used by the redaction canary');
}

/// Walks up to the repo root, so the source-scanning guard works whatever
/// directory the runner was invoked from. Same approach as
/// test/font_literal_guard_test.dart.
Directory _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/lib').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate repo root from ${Directory.current}');
    }
    dir = parent;
  }
}

/// Method declarations in lib/services/diag/ that turn an object into text
/// or bytes. Conservative on purpose: it matches a declaration (return type
/// then name then `(`), not a call, so `jsonEncode(...)` inside a body does
/// not trip it.
final _encoderDeclaration = RegExp(
  r'^\s*(?:@override\s+)?[\w<>?,\s]*\b'
  r'(toString|toJson|toMap|toWire|encode|serialize|toBytes|toNdjson'
  r'|toSnapshot)'
  r'\s*\(',
);

/// Serialization members already covered by [_encoders]. `toString` is here
/// as a live positive control: `DiagEvent.toString()` exists in
/// lib/services/diag/diag_event.dart, so the scanner below is proven to
/// find real declarations rather than silently matching nothing.
const _registeredEncoderSymbols = <String>{'toString'};

// ─────────────────────────────────────────────────────────────────────────
// 5. The tests
// ─────────────────────────────────────────────────────────────────────────

void main() {
  late List<PlantedSecret> secrets;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    secrets = await _seedEverySecretStore();
  });

  group('planting actually happened (anti-vacuity)', () {
    test('every enumerated secret store holds its planted value', () {
      for (final s in secrets) {
        expect(
          s.readBack,
          contains(s.planted),
          reason: 'planting failed for "${s.label}" (${s.source}); a canary '
              'that never planted anything would pass every leak assertion '
              'below for free',
        );
      }
    });

    test('the scanner detects a planted secret when one is present', () {
      for (final s in secrets) {
        expect(
          _findSecrets('prefix ${s.planted} suffix', secrets),
          contains(s.label),
          reason: 'the scanner must be able to see "${s.label}"',
        );
      }
      expect(
        _findSecrets('nothing sensitive here', secrets),
        isEmpty,
        reason: 'and must not fire on innocent text',
      );
    });

    test('all nine secret stores from spec section 2 are covered', () {
      // Cross-check by SOURCE file, so deleting a planting block without
      // deleting its store is caught.
      expect(
        secrets.map((s) => s.source).toSet(),
        {
          'lib/services/operator_token.dart',
          'lib/services/operator_session_store.dart',
          'lib/services/audience_token_service.dart',
          'lib/services/identity_service.dart',
          'lib/services/pq_prekey_service.dart',
          'lib/services/guest_key_store.dart',
          'lib/features/guest/guest_link.dart',
          'lib/services/livekit_call_service.dart',
          'lib/services/device_recovery_codec.dart',
        },
        reason: 'spec section 2 "Secrets on the client" enumerates the stores '
            'this canary must cover',
      );
    });
  });

  group('the catalog cannot grow an unreviewed secret-carrying slot', () {
    test('every String field in the catalog is justified in _stringFields', () {
      final missing = <String>[];
      for (final spec in DiagCodes.catalog.values) {
        for (final field in spec.fields) {
          if (field.typeName != 'String') continue;
          if (!_stringFields.containsKey('${spec.code}.${field.key}')) {
            missing.add('${spec.code}.${field.key}');
          }
        }
      }
      expect(
        missing,
        isEmpty,
        reason: 'DiagFieldSpec.string accepts ANY String, so these slots are '
            'unconstrained by the type system. Add each to _stringFields '
            'with a sample and a written reason it cannot hold a secret '
            '(spec section 7), or drop the field.',
      );
    });

    test('_stringFields has no stale entries', () {
      final live = <String>{
        for (final spec in DiagCodes.catalog.values)
          for (final field in spec.fields)
            if (field.typeName == 'String') '${spec.code}.${field.key}',
      };
      expect(
        _stringFields.keys.where((k) => !live.contains(k)),
        isEmpty,
        reason: 'a stale justification hides which slots are really live; '
            'remove entries for fields the catalog no longer declares',
      );
    });

    test('no String field has a secret-shaped name', () {
      final offenders = <String>[];
      for (final spec in DiagCodes.catalog.values) {
        for (final field in spec.fields) {
          if (field.typeName != 'String') continue;
          final id = '${spec.code}.${field.key}';
          if (_secretShapedNameExemptions.containsKey(id)) continue;
          final lower = field.key.toLowerCase();
          for (final pattern in _secretShapedNames) {
            if (lower.contains(pattern)) {
              offenders.add('$id (matches "$pattern")');
            }
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'a String slot named like a credential is the exact failure '
            'this canary exists to stop. If the name is innocent, add it to '
            '_secretShapedNameExemptions with a reason so the waiver is '
            'visible in review.',
      );
    });

    test('the catalog declares no value shape outside the reviewed set', () {
      final declared = <String>{
        for (final spec in DiagCodes.catalog.values)
          for (final field in spec.fields) field.typeName,
      };
      expect(
        declared.difference(_allowedTypeNames),
        isEmpty,
        reason: 'a new DiagFieldSpec factory is a new shape of data able to '
            'enter a snapshot (a map or list could carry anything). Review '
            'it, then add it to _allowedTypeNames and _typedSamples.',
      );
    });

    test('no planted secret is hard-coded into the catalog itself', () {
      final surface = StringBuffer();
      for (final spec in DiagCodes.catalog.values) {
        surface.writeln(spec.code);
        for (final field in spec.fields) {
          surface.writeln('${field.key}:${field.typeName}');
        }
      }
      expect(_findSecrets(surface.toString(), secrets), isEmpty);
    });
  });

  group('no secret survives any diag serialization path', () {
    test('every catalog code, through every encoder, is secret-free', () {
      var encodings = 0;
      for (final spec in DiagCodes.catalog.values) {
        final event = DiagEvent.tryCreate(
          seq: 1,
          ts: DateTime.utc(2026, 8, 15, 12),
          level: DiagLevel.error,
          category: DiagCategory.net,
          code: spec.code,
          fields: _sampleFieldsFor(spec),
        );
        expect(
          event,
          isNotNull,
          reason: 'the sample fields for "${spec.code}" must satisfy the '
              'catalog, otherwise this canary is testing nothing for that code',
        );
        for (final encoder in _encoders) {
          final out = encoder.encode(event!);
          encodings++;
          expect(
            _findSecrets(out, secrets),
            isEmpty,
            reason: 'secret leaked from "${spec.code}" via ${encoder.name}',
          );
        }
      }
      expect(
        encodings,
        DiagCodes.catalog.length * _encoders.length,
        reason: 'every code must be run through every encoder',
      );
    });

    test('a secret cannot be smuggled into an undeclared field', () {
      // Whitelist by construction, asserted rather than assumed: an event
      // carrying an extra field is rejected outright, so there is nothing
      // to serialize. Checked via firstViolation because that is the layer
      // which survives release builds stripping asserts.
      for (final secret in secrets) {
        for (final spec in DiagCodes.catalog.values) {
          final fields = _sampleFieldsFor(spec)
            ..['leaked'] = secret.planted;
          final violation = DiagCodes.firstViolation(spec.code, fields);
          expect(
            violation,
            isNotNull,
            reason: 'an undeclared field must be rejected for "${spec.code}"',
          );
          expect(
            _findSecrets(violation!, secrets),
            isEmpty,
            reason: 'the rejection message must not echo the value it '
                'rejected: it names the KEY and the runtimeType, never the '
                'contents',
          );
        }
      }
    });

    test('a secret cannot be smuggled into a typed (non-String) slot', () {
      final secret = secrets.first.planted;
      var checked = 0;
      for (final spec in DiagCodes.catalog.values) {
        for (final field in spec.fields) {
          if (field.typeName == 'String') continue;
          final fields = _sampleFieldsFor(spec)..[field.key] = secret;
          final violation = DiagCodes.firstViolation(spec.code, fields);
          expect(
            violation,
            isNotNull,
            reason: 'field "${spec.code}.${field.key}" is declared '
                '${field.typeName} and must reject a String',
          );
          expect(_findSecrets(violation!, secrets), isEmpty);
          checked++;
        }
      }
      expect(checked, greaterThan(0));
    });

    test('an unregistered code cannot produce an event at all', () {
      final violation = DiagCodes.firstViolation(
        'net.request_failed_but_with_a_token',
        {'token': secrets.first.planted},
      );
      expect(violation, isNotNull);
      expect(_findSecrets(violation!, secrets), isEmpty);
    });
  });

  group('coverage cannot silently rot', () {
    test('_encoderSymbolGuard: new diag serializers must register here', () {
      // The ring buffer, persisted tail and snapshot encoder (cards
      // b62da57c / 7cebe96a / 270ea324) land in lib/services/diag/. When
      // one of them adds a toJson/encode/serialize member, this fails until
      // it is added to _encoders, so the canary's coverage grows with the
      // feature instead of quietly falling behind it.
      final dir = Directory('${_findRepoRoot().path}/lib/services/diag');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'lib/services/diag must exist for this guard to mean anything',
      );

      final unregistered = <String>[];
      var matched = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        var lineNo = 0;
        for (final line in entity.readAsLinesSync()) {
          lineNo++;
          final trimmed = line.trim();
          if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
          final match = _encoderDeclaration.firstMatch(line);
          if (match == null) continue;
          matched++;
          final symbol = match.group(1)!;
          if (_registeredEncoderSymbols.contains(symbol)) continue;
          unregistered.add(
            '${entity.path.split('/lib/').last}:$lineNo -> $symbol',
          );
        }
      }

      // Positive control: DiagEvent.toString() is a real declaration in this
      // directory. If the scanner stops finding it (a refactor, a broken
      // regex) the guard has become a no-op and must fail loudly rather than
      // pass by matching nothing.
      expect(
        matched,
        greaterThan(0),
        reason: 'the serializer scanner matched no declarations at all; it is '
            'no longer guarding anything',
      );

      expect(
        unregistered,
        isEmpty,
        reason: 'a new serialization path exists in lib/services/diag that '
            'this canary does not exercise. Add it to _encoders and to '
            '_registeredEncoderSymbols. Spec section 7: the persisted tail '
            'and the snapshot encoder must both be asserted secret-free.',
      );
    });

    test('every encoder is distinct and non-empty', () {
      final event = DiagEvent.tryCreate(
        seq: 7,
        ts: DateTime.utc(2026, 8, 15, 12),
        level: DiagLevel.info,
        category: DiagCategory.health,
        code: 'health.change',
        fields: _sampleFieldsFor(DiagCodes.catalog['health.change']!),
      )!;
      final outputs = <String, String>{};
      for (final encoder in _encoders) {
        final out = encoder.encode(event);
        expect(
          out,
          isNotEmpty,
          reason: '${encoder.name} produced nothing, so it asserts nothing',
        );
        // `stt` is health.change's `dep` sample. Asserting on a FIELD VALUE
        // rather than on the code string is deliberate: the fields map is
        // the surface a secret would actually ride on, and the fields-only
        // encoder does not carry the code at all.
        expect(
          out,
          contains('stt'),
          reason: '${encoder.name} must actually serialize the event fields, '
              'otherwise the leak assertions above scan an empty surface',
        );
        outputs[encoder.name] = out;
      }
      expect(outputs.length, _encoders.length);
    });
  });
}
