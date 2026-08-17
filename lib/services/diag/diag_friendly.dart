// Me > Logs, half 1: plain-language rendering of a [DiagEvent].
//
// The catalog (diag_codes.dart) deliberately carries no free-form message
// field (see that file's header) -- a code plus typed fields, never prose.
// That is exactly right for the ring buffer's job (never an empty
// `str(e)`), and exactly wrong for a human reading the Me > Logs screen
// directly: nobody wants to read `net.request_failed kind=connectTimeout
// host=skworld-100 port=18794`. This file is the one and only place that
// gap is bridged: a pure, independently-testable function per concern
// (matches the shape diag_interceptor.dart already established --
// `classifyNetFailure` / `pathTemplate` -- small top-level functions, no
// class state), never folded into the widget layer so it can be unit
// tested without pumping a widget tree.
//
// [friendlyDiagEvent] never invents information the event does not carry:
// the headline is built ONLY from the event's own typed fields (never a
// caught exception's message -- there isn't one available here, and that
// is the point of the catalog). [technicalDetail] is the raw fallback,
// always available on tap/expand, so nothing is ever truly hidden, only
// summarized.

import 'diag_event.dart';

/// One event, rendered for a human: a short plain-language [headline], plus
/// the full technical detail (code + every field) for an expand/tap.
class DiagFriendlyEvent {
  const DiagFriendlyEvent({required this.headline, required this.detail});

  final String headline;
  final String detail;
}

/// Best-effort human label for the service behind [host]/[pathTemplate],
/// matching against the same 5 known service ids `HealthService` uses
/// ([kKnownServiceLabels] in `health_service.dart`; not imported here to
/// keep this file dependency-free of that one -- the ids are duplicated as
/// a small literal map, see note below). Returns `null` rather than a
/// guess when nothing matches: a wrong service name would be worse than
/// none, so the caller falls back to the bare `host:port`.
///
/// Duplicated (not shared) from `health_service.dart` deliberately: that
/// file's map is keyed for the health CONTRACT (ids the server sends);
/// this one is a heuristic for a client-observed hostname, a different
/// enough purpose that coupling the two would make an unrelated health-
/// contract change silently reformat log lines.
const Map<String, String> _kServiceHints = {
  'stt': 'Speech to text',
  'tts': 'Text to speech',
  'llm': 'Language model',
  'sfu': 'Calling',
  'webui': 'Server',
};

String? _guessServiceLabel(String host, String pathTemplate) {
  final haystack = '$host $pathTemplate'.toLowerCase();
  for (final entry in _kServiceHints.entries) {
    if (haystack.contains(entry.key)) return entry.value;
  }
  return null;
}

/// `NetFailureKind` -> a short plain-language phrase. Never the raw enum
/// name (spec: no message slot exists, so this is the entire translation
/// layer for it).
String _kindPhrase(NetFailureKind kind) {
  switch (kind) {
    case NetFailureKind.dns:
      return "the address couldn't be found";
    case NetFailureKind.refused:
      return 'the connection was refused';
    case NetFailureKind.connectTimeout:
      return 'connection timed out';
    case NetFailureKind.readTimeout:
      return 'timed out waiting for a reply';
    case NetFailureKind.tls:
      return "a secure connection couldn't be made";
    case NetFailureKind.http4xx:
      return 'the request was rejected';
    case NetFailureKind.http5xx:
      return 'the server reported an error';
    case NetFailureKind.aborted:
      return 'the request was cancelled';
    case NetFailureKind.unknown:
      return 'a network error occurred';
  }
}

String _place(Map<String, Object> fields) {
  final host = fields['host'] as String? ?? '';
  final port = fields['port'] as int?;
  final pathTemplate = fields['pathTemplate'] as String? ?? '';
  final guess = _guessServiceLabel(host, pathTemplate);
  final hostPort = port != null ? '$host:$port' : host;
  if (guess != null && hostPort.isNotEmpty) return '$guess ($hostPort)';
  if (guess != null) return guess;
  return hostPort.isNotEmpty ? hostPort : 'the server';
}

String _credentialWord(CredentialKind kind) {
  switch (kind) {
    case CredentialKind.session:
      return 'session';
    case CredentialKind.audience:
      return 'audience token';
    case CredentialKind.operator:
      return 'operator session';
  }
}

/// The plain-language headline for [event]. Covers every code currently in
/// [DiagCodes.catalog]; a code this switch does not recognize (future
/// catalog growth landing before this file is updated) falls back to
/// [_genericHeadline] rather than throwing, so a new code degrades to
/// "something happened" instead of crashing the screen.
String _headline(DiagEvent event) {
  final f = event.fields;
  switch (event.code) {
    case 'net.request_failed':
      final kind = f['kind'] as NetFailureKind?;
      final phrase = kind != null ? _kindPhrase(kind) : 'a network error occurred';
      return "Couldn't reach ${_place(f)}: $phrase";
    case 'net.request_slow':
      final ms = f['durationMs'] as int?;
      final durationText = ms != null ? '$ms ms' : 'a while';
      return '${_place(f)} is responding slowly ($durationText)';
    case 'auth.retry':
      final kind = f['credential'] as CredentialKind?;
      final word = kind != null ? _credentialWord(kind) : 'session';
      return 'Retrying after a $word hiccup';
    case 'auth.session_expired':
      final kind = f['credential'] as CredentialKind?;
      final word = kind != null ? _credentialWord(kind) : 'session';
      return 'Your $word expired and needs to be renewed';
    case 'auth.mint_failed':
      final kind = f['credential'] as CredentialKind?;
      final word = kind != null ? _credentialWord(kind) : 'session';
      return 'Could not establish a $word';
    case 'call.state':
      final state = f['state'] as String? ?? 'unknown';
      final room = f['room'] as String?;
      return room != null && room.isNotEmpty
          ? 'Call in $room: $state'
          : 'Call state: $state';
    case 'call.quality':
      final quality = f['quality'] as String? ?? 'unknown';
      final participant = f['participant'] as String?;
      return participant != null && participant.isNotEmpty
          ? 'Call quality with $participant: $quality'
          : 'Call quality: $quality';
    case 'call.media_silent':
      final ms = f['silentForMs'] as int?;
      final seconds = ms != null ? (ms / 1000).toStringAsFixed(0) : 'several';
      return 'No audio detected for $seconds seconds';
    case 'voice.turn':
      final stage = f['stage'] as String? ?? 'unknown';
      return 'Voice: $stage';
    case 'health.change':
      final dep = f['dep'] as String? ?? 'a service';
      final from = f['from'] as String? ?? '?';
      final to = f['to'] as String? ?? '?';
      return '$dep changed from $from to $to';
    case 'beat.missed':
      final loop = f['loop'] as String? ?? 'a background task';
      return '$loop stopped responding';
    case 'store.box_corrupt':
      final box = f['box'] as String? ?? 'local storage';
      return '$box was corrupted and had to be reset';
    case 'store.flush_failed':
      final box = f['box'] as String? ?? 'local storage';
      return 'Could not save $box';
    case 'lifecycle.start':
      return 'App started';
    case 'lifecycle.resume':
      return 'App resumed';
    case 'lifecycle.error':
      final type = f['errorType'] as String?;
      return type != null && type.isNotEmpty
          ? 'App error ($type)'
          : 'App error';
    default:
      return _genericHeadline(event);
  }
}

/// Fallback for a code this file's switch does not (yet) know: the code
/// itself, human-spaced, rather than a crash or a blank line.
String _genericHeadline(DiagEvent event) =>
    event.code.replaceAll('.', ' - ').replaceAll('_', ' ');

/// Every field, rendered `key: value`, enums via their name (never a
/// `.toString()` of the whole map, so this stays stable if [DiagEvent]'s
/// own `toString()` ever changes shape).
String technicalDetail(DiagEvent event) {
  final parts = <String>['code: ${event.code}'];
  for (final entry in event.fields.entries) {
    parts.add('${entry.key}: ${_fieldValueText(entry.value)}');
  }
  return parts.join(' - ');
}

String _fieldValueText(Object value) {
  if (value is NetFailureKind) return value.name;
  if (value is CredentialKind) return value.name;
  return value.toString();
}

/// Renders [event] as a headline + full technical detail. This is the only
/// exported entry point most callers need; [technicalDetail] is exposed
/// separately too for a caller that wants only the raw side.
DiagFriendlyEvent friendlyDiagEvent(DiagEvent event) =>
    DiagFriendlyEvent(headline: _headline(event), detail: technicalDetail(event));
