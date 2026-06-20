import 'dart:convert';

/// Reference to a file attachment carried inside a chat message body.
///
/// Attachments are delivered out-of-band (the daemon's `/upload` + `/file`
/// endpoints handle the bytes); the *chat message* only carries a small
/// pointer so both sides can render a [FileTransferBubble] for the same
/// transfer.  We encode that pointer as a single-line sentinel so it survives
/// the plain-text message transport and is trivial to detect:
///
///   __ATTACH__:{"transfer_id":"t-123","filename":"cat.png","size":4096,
///               "caption":"look"}
///
/// [parse] returns null for any body that is not a well-formed attachment
/// sentinel, so callers can fall back to ordinary text rendering.
class AttachmentRef {
  const AttachmentRef({
    required this.transferId,
    required this.filename,
    this.size = 0,
    this.caption = '',
  });

  final String transferId;
  final String filename;
  final int size;
  final String caption;

  /// Sentinel prefix that marks a message body as an attachment pointer.
  static const String prefix = '__ATTACH__:';

  /// Image extensions for which a thumbnail preview is worth fetching.
  static const Set<String> _imageExts = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic',
  };

  /// True when the filename looks like an image (so the bubble shows a thumb).
  bool get isImage {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return false;
    return _imageExts.contains(filename.substring(dot + 1).toLowerCase());
  }

  /// Encode this reference as the single-line message body to send.
  String encode() => '$prefix${jsonEncode({
        'transfer_id': transferId,
        'filename': filename,
        'size': size,
        'caption': caption,
      })}';

  /// Parse a raw message body into an [AttachmentRef], or null if it is not a
  /// valid attachment sentinel.
  static AttachmentRef? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (!trimmed.startsWith(prefix)) return null;
    final payload = trimmed.substring(prefix.length);
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final transferId = decoded['transfer_id'] as String? ?? '';
      if (transferId.isEmpty) return null;
      return AttachmentRef(
        transferId: transferId,
        filename: decoded['filename'] as String? ?? 'file',
        size: (decoded['size'] as num?)?.toInt() ?? 0,
        caption: decoded['caption'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}
