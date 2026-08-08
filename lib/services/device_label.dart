/// Best-effort local device label for a labelled device enroll (skchat's R2
/// enrollment feature, `operator_auth_routes.py:enroll`): a short,
/// human-recognisable name for THIS device, sent (and signed, see
/// [OperatorSessionService.enroll]) at enrollment time so the operator's
/// Linked Devices list shows something better than the server's own crude
/// User-Agent guess (`_derive_label`, which collapses every native client to
/// "App device").
///
/// Platform seam, the same shape as `guest_identity.dart`: the real
/// implementation (native, `dart:io` `Platform.operatingSystem` +
/// `Platform.localHostname`) lives in `device_label_io.dart`. On web (no
/// `dart:io`) the stub always returns null.
///
/// `device_info_plus` is deliberately NOT a dependency of this app (checked:
/// not present in pubspec.yaml), so this stays within what `dart:io`'s
/// `Platform` already exposes rather than adding one just for a device name.
/// A null return is always safe: it makes [OperatorSessionService.enroll]
/// omit the `label` field entirely, which is the same backwards-compatible
/// path a pre-label client already exercises, the server then falls back to
/// its own User-Agent-derived guess.
library;

import 'device_label_stub.dart' if (dart.library.io) 'device_label_io.dart'
    as impl;

/// Guess a short label for this device ("Linux (chef-laptop)", "Mac
/// (Chefs-MacBook-Pro)", ...), or null when nothing sensible can be derived
/// (web, or a platform read that failed). Never throws.
String? guessDeviceLabel() => impl.guessDeviceLabel();
