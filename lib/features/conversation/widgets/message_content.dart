import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import '../../../core/theme/theme.dart';
import '../../../core/chat_text.dart';
import '../../../models/chat_message.dart';
import '../location/location_payload.dart';
import 'location_card.dart';

/// Renders a message's body **by `content_type`** -- the GOLDEN RULE.
///
/// Known content types get a bespoke renderer. An UNKNOWN content type (e.g. a
/// future `application/skchat.location+json` or `application/skchat.poll+json`
/// that this client predates) must still degrade gracefully: it renders the
/// message's [ChatMessage.content] (the contract's mandatory human-readable
/// `body` fallback) as plain text, never breaking the timeline. New phases add
/// renderers here; old clients keep working.
///
/// This widget is the single dispatch point so the bubble doesn't grow a
/// content-type switch inline -- it just calls [MessageContent].
class MessageContent extends StatelessWidget {
  const MessageContent({
    super.key,
    required this.message,
    this.textColor = SovereignColors.textPrimary,
  });

  final ChatMessage message;
  final Color textColor;

  /// Content types this client knows how to render natively (beyond the
  /// plain-text fallback). Kept here so tests + the bubble can introspect it.
  static const Set<String> knownTypes = {
    'text',
    'plain',
    'markdown',
    'md',
    'system',
    'location',
  };

  bool get _isKnown => knownTypes.contains(message.contentType.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final ct = message.contentType.toLowerCase();

    switch (ct) {
      case 'location':
        // Phase 4: render a map-pin card. If the rich payload is missing/garbled
        // we fall through to the body fallback (Golden rule), a location with no
        // coordinates still shows its `body` text.
        final loc = LocationPayload.tryParse(message.rich);
        if (loc != null) {
          return LocationCard(payload: loc, textColor: textColor);
        }
        return _PlainBody(text: _bodyText(), color: textColor);
      case 'system':
        return _SystemLine(text: _bodyText(), color: textColor);
      case 'text':
      case 'plain':
      case 'markdown':
      case 'md':
        // Render Markdown, agent (Lumina) replies are LLM output and almost
        // always Markdown (bold, headers, lists, code, links, tables). Plain
        // text with no markdown markers renders as-is, so routing text/plain
        // through here is safe and fixes raw `**` / `#` showing in bubbles.
        return _MarkdownBody(text: _bodyText(), color: textColor);
      default:
        // GOLDEN RULE: unknown content_type -> render the body fallback, with a
        // subtle chip noting the type so it's clear this is a forward-compat
        // degrade rather than a plain message.
        return _UnknownFallback(
          contentType: message.contentType,
          text: _bodyText(),
          color: textColor,
        );
    }
  }

  /// The text to show. Prefers the contract `body`; if a known control/envelope
  /// sentinel slipped through, [displayTextFor] still cleans it. For unknown
  /// types we show the raw body verbatim (never hide it).
  String _bodyText() {
    if (_isKnown) {
      return displayTextFor(message.content) ?? message.content;
    }
    return message.content;
  }
}

class _PlainBody extends StatelessWidget {
  const _PlainBody({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 15, height: 1.4),
      ),
    );
  }
}

/// Renders Markdown (bold/italic/headers/lists/code/links/tables) for chat
/// bubbles, used for text + markdown messages so Lumina's LLM output renders
/// instead of showing raw `**`/`#`. Selectable; links open externally.
class _MarkdownBody extends StatelessWidget {
  const _MarkdownBody({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GptMarkdown(
        text,
        style: TextStyle(color: color, fontSize: 15, height: 1.4),
      ),
    );
  }
}

class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          color: color.withValues(alpha: 0.7),
          fontSize: 13,
          fontStyle: FontStyle.italic,
          height: 1.4,
        ),
      ),
    );
  }
}

/// Forward-compat fallback for an unrecognized `content_type`: shows the body
/// plus a tiny type tag so the message is never lost or silently dropped.
class _UnknownFallback extends StatelessWidget {
  const _UnknownFallback({
    required this.contentType,
    required this.text,
    required this.color,
  });

  final String contentType;
  final String text;
  final Color color;

  /// Short, human label for the unknown type (drop the `application/skchat.`
  /// prefix + `+json` suffix when present, e.g. `location`, `poll`).
  String get _label {
    var t = contentType;
    const prefix = 'application/skchat.';
    if (t.startsWith(prefix)) t = t.substring(prefix.length);
    if (t.endsWith('+json')) t = t.substring(0, t.length - '+json'.length);
    return t.isEmpty ? contentType : t;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.20)),
          ),
          child: Text(
            _label,
            style: TextStyle(
              color: color.withValues(alpha: 0.6),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
        Text(
          text.isEmpty ? '[$_label]' : text,
          style: TextStyle(color: color, fontSize: 15, height: 1.4),
        ),
      ],
    );
  }
}
