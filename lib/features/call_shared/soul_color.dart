import "package:flutter/material.dart" show Color;

import "../../core/theme/sovereign_colors.dart";

/// Maps well-known agent identity names to their soul accent colors.
/// Falls back to [SovereignColors.fromFingerprint] for unknown identities.
///
/// This lives in `call_shared` rather than in a single call screen because a
/// participant's soul color is their identity on EVERY video surface: the same
/// person must get the same ring in a 1:1 call, a conference and a Space, or
/// the color stops meaning "who" and starts meaning "which screen you happen
/// to be looking at". The shared participant tile reads it from here.
const Map<String, Color> kSoulColors = {
  'lumina':   SovereignColors.soulLumina,
  'jarvis':   SovereignColors.soulJarvis,
  'chef':     SovereignColors.soulChef,
  'opus':     Color(0xFFFFA726), // amber, distinct from Jarvis cyan
  'ava':      Color(0xFFEC407A), // rose
  'ara':      Color(0xFF26C6DA), // teal-cyan
  'sentinel': Color(0xFFFF7043), // deep-orange
  'herald':   Color(0xFF66BB6A), // green
  'architect':Color(0xFF5C6BC0), // indigo
  'scholar':  Color(0xFFAB47BC), // purple
  'steward':  Color(0xFF26A69A), // teal
  'coder':    Color(0xFF42A5F5), // blue
};

/// The accent color for [identity]. The lookup key is the local part of the
/// identity, lowercased: a participant joins as `lumina@chef.skworld.io` (and
/// the call agent as `<fqid>#agent`), so keying on the raw string would miss
/// every real identity the app ever sees.
Color soulColorFor(String identity) {
  final key = identity.toLowerCase().split('@').first;
  return kSoulColors[key] ?? SovereignColors.fromFingerprint(identity);
}
