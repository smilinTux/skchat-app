import "package:web_socket_channel/web_socket_channel.dart";

/// A thin seam over [WebSocketChannel] so [SkcodeSessionStore] (and its
/// reconnect/backoff/re-mint state machine) is unit-testable without a real
/// socket. Production code uses [SkcodeWsTransport.connect] (wrapping
/// `WebSocketChannel.connect`); tests inject a fake implementation.
abstract class SkcodeWsTransport {
  /// Default production transport: wraps `WebSocketChannel.connect(uri)`.
  factory SkcodeWsTransport.connect(Uri uri) = _IoSkcodeWsTransport;

  /// Completes once the handshake succeeds, or completes with an error if it
  /// fails (matches [WebSocketChannel.ready]).
  Future<void> get ready;

  /// Frames as they arrive. Callers JSON-decode themselves (mirrors
  /// [WebSocketChannel.stream], which is `Stream<dynamic>`).
  Stream<dynamic> get stream;

  /// The close code once the channel has closed. `1008` (policy violation)
  /// is skcode-hostd's signal for "bad/expired wire token" (spec 4.2).
  /// `null` before close, or when the transport never reports one.
  int? get closeCode;

  Future<void> close();
}

class _IoSkcodeWsTransport implements SkcodeWsTransport {
  _IoSkcodeWsTransport(Uri uri) : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  Future<void> close() => _channel.sink.close();
}
