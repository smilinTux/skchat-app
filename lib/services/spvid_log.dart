import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'backend_config.dart';

/// TEMPORARY debug scaffolding for the [SPVID] camera-share trace added in
/// commit b0ae75b (skchat-app). Flutter web release does not reliably
/// surface debugPrint to the browser console, so a multi-device (laptop +
/// phone) repro has nowhere common to land. [spvidLog] mirrors every
/// debugPrint with a fire-and-forget POST to the server-side beacon at
/// POST /spvid-log (skchat repo, src/skchat/spvid_debug.py), which appends
/// one line per call to ~/.skchat/spvid-debug.log. Delete this file once the
/// bug is diagnosed.

/// Short stable per-page-load tag so laptop vs phone are distinguishable in
/// the collected log. Generated once, lazily, and cached for the process
/// lifetime (a fresh page load / app start gets a new tag).
String? _deviceTag;
final Random _spvidRand = Random();

String get _tag {
  final cached = _deviceTag;
  if (cached != null) return cached;
  const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
  final tag =
      List.generate(5, (_) => chars[_spvidRand.nextInt(chars.length)]).join();
  _deviceTag = tag;
  return tag;
}

final Dio _spvidDio = Dio();

/// SKChat web-UI base URL, the same source SpacesService / LiveKitCallService
/// build their base from (backend_config.dart: "SKChat web-UI base URL,
/// serves /spaces + /livekit/token"). Using the compile-time seed (rather
/// than watching the runtime-switchable backendConfigProvider) keeps this a
/// plain top-level function callable from anywhere, including free functions
/// with no Riverpod ref, and is correct both for a web build served from
/// that same host (same-origin) and for a native build hitting it directly.
const String _spvidWebuiBase = kDefaultSkchatWebuiUrl;

/// Log an [SPVID] trace line. Always debugPrints locally (harmless) AND
/// fire-and-forgets a POST to the server beacon so a multi-device repro
/// lands in one place. Never throws, never awaited by the caller.
void spvidLog(String line) {
  debugPrint('[SPVID] $line');
  unawaited(_postSpvid(line));
}

Future<void> _postSpvid(String line) async {
  try {
    await _spvidDio.post<void>(
      '$_spvidWebuiBase/spvid-log',
      data: {
        'device': _tag,
        't': DateTime.now().millisecondsSinceEpoch,
        'line': line,
      },
    );
  } catch (_) {
    // Swallow everything: best-effort debug scaffolding, never the request path.
  }
}
