import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/models/attachment_ref.dart';
import 'package:skchat/services/skcomms_client.dart';

/// Canned-response adapter — resolves each request from [routes] by path and
/// records the last request so the multipart body/method can be asserted.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    final body = routes[options.path] ?? routes[options.uri.path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  group('UploadResult.fromJson', () {
    test('parses a complete upload response', () {
      final r = UploadResult.fromJson({
        'id': 'msg-1',
        'transfer_id': 't-abc',
        'filename': 'cat.png',
      });
      expect(r.id, 'msg-1');
      expect(r.transferId, 't-abc');
      expect(r.filename, 'cat.png');
    });

    test('defaults missing fields to empty strings', () {
      final r = UploadResult.fromJson({});
      expect(r.id, '');
      expect(r.transferId, '');
      expect(r.filename, '');
    });
  });

  group('URL helpers', () {
    test('fileUrl / thumbUrl build off the configured base URL', () {
      final c = SKCommsClient(baseUrl: 'http://daemon.local:9384');
      expect(c.fileUrl('t-123'), 'http://daemon.local:9384/file/t-123');
      expect(c.thumbUrl('t-123'), 'http://daemon.local:9384/file/t-123/thumb');
    });

    test('strips a trailing slash on the base URL', () {
      final c = SKCommsClient(baseUrl: 'http://daemon.local:9384/');
      expect(c.fileUrl('t-9'), 'http://daemon.local:9384/file/t-9');
    });

    test('url-encodes the transfer id', () {
      final c = SKCommsClient(baseUrl: 'http://h:9384');
      expect(c.fileUrl('a b/c'), 'http://h:9384/file/a%20b%2Fc');
    });
  });

  group('uploadFile', () {
    late _CannedAdapter adapter;
    late SKCommsClient client;

    setUp(() {
      adapter = _CannedAdapter({});
      final dio = Dio()..httpClientAdapter = adapter;
      client = SKCommsClient(baseUrl: 'http://test.local:9384', dio: dio);
    });

    test('POSTs multipart to /upload and parses the result', () async {
      adapter.routes['/upload'] = {
        'id': 'm-9',
        'transfer_id': 't-9',
        'filename': 'note.txt',
      };

      final result = await client.uploadFile(
        recipient: 'lumina',
        bytes: utf8.encode('hello'),
        filename: 'note.txt',
        caption: 'a note',
      );

      expect(result.transferId, 't-9');
      expect(result.filename, 'note.txt');

      final req = adapter.lastRequest;
      expect(req, isNotNull);
      expect(req!.method, 'POST');
      expect(req.path, '/upload');
      // Multipart sets its own content-type with a boundary.
      expect(req.contentType, contains('multipart/form-data'));
      expect(req.data, isA<FormData>());
      final form = req.data as FormData;
      expect(
        form.fields.firstWhere((f) => f.key == 'recipient').value,
        'lumina',
      );
      expect(
        form.fields.firstWhere((f) => f.key == 'caption').value,
        'a note',
      );
      expect(form.files.map((f) => f.key), contains('file'));
      expect(form.files.first.value.filename, 'note.txt');
    });
  });

  group('AttachmentRef encode/parse', () {
    test('round-trips through encode → parse', () {
      const ref = AttachmentRef(
        transferId: 't-1',
        filename: 'pic.jpg',
        size: 2048,
        caption: 'sunset',
      );
      final encoded = ref.encode();
      expect(encoded.startsWith(AttachmentRef.prefix), isTrue);

      final parsed = AttachmentRef.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.transferId, 't-1');
      expect(parsed.filename, 'pic.jpg');
      expect(parsed.size, 2048);
      expect(parsed.caption, 'sunset');
      expect(parsed.isImage, isTrue);
    });

    test('returns null for non-attachment bodies', () {
      expect(AttachmentRef.parse('just text'), isNull);
      expect(AttachmentRef.parse(null), isNull);
      expect(AttachmentRef.parse('__ATTACH__:not-json'), isNull);
      // Missing transfer_id is not a valid reference.
      expect(AttachmentRef.parse('__ATTACH__:{"filename":"x"}'), isNull);
    });

    test('isImage is false for non-image extensions', () {
      const ref = AttachmentRef(transferId: 't', filename: 'doc.pdf');
      expect(ref.isImage, isFalse);
    });
  });
}
