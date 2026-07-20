import "package:dio/dio.dart";
import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/theme/theme.dart";
import "../../../services/operator_session_service.dart";

/// Shown when `enroll/open` (or any step of the enrollment flow) is rejected
/// because the caller is not yet a trusted operator context (HTTP 401/403).
/// Exposed as a top-level constant so tests can assert on it directly rather
/// than duplicating the copy.
const kNotTrustedOperatorMessage =
    "Open this on your local network (tailnet), or set your operator token "
    "first, then try again.";

/// Generic fallback for any OTHER enrollment failure (daemon offline,
/// network error, malformed response, ...). Never a raw exception string.
const _kGenericLinkFailureMessage =
    "Could not link this device. Check the daemon connection and try again.";

enum _LinkStatus { idle, linking, linked, error }

/// "Link this device" operator-enrollment control for the Me / Profile
/// screen.
///
/// Drives [OperatorSessionService]'s existing enrollment flow end to end,
/// reusing its wire calls and signing, none of that is reimplemented here:
///  1. [OperatorSessionService.openEnrollWindow] (`POST
///     /api/v1/auth/enroll/open`), operator-gated on the server.
///  2. [OperatorSessionService.enroll] with the returned window nonce
///     (`POST /api/v1/auth/enroll`).
///  3. [OperatorSessionService.ensureSession] to confirm a session can
///     actually be obtained with the newly-enrolled key.
///
/// On success, shows the device fingerprint (read via
/// [OperatorSessionService.identity], the same [GuestIdentity] instance the
/// service itself signs with). On a 401/403 from any step, shows
/// [kNotTrustedOperatorMessage] instead of a raw exception; any other
/// failure shows a generic, still-friendly fallback. Never crashes: every
/// path is caught and turned into an error-state string.
///
/// Web-first: the device key ([GuestIdentity]) is only a real WebCrypto key
/// on the web build today (native is an in-memory stub, see
/// guest_identity_stub.dart), so on a non-web build this renders a
/// "supported on the web app for now" note instead of the control. Detected
/// via [kIsWeb], overridable through [isWeb] so this can be widget-tested
/// under `flutter test`'s VM target (where [kIsWeb] is always false).
class OperatorEnrollmentSection extends ConsumerStatefulWidget {
  const OperatorEnrollmentSection({super.key, this.isWeb});

  /// Test-only override of the platform's real [kIsWeb] value.
  final bool? isWeb;

  @override
  ConsumerState<OperatorEnrollmentSection> createState() =>
      _OperatorEnrollmentSectionState();
}

class _OperatorEnrollmentSectionState
    extends ConsumerState<OperatorEnrollmentSection> {
  _LinkStatus _status = _LinkStatus.idle;
  String? _fingerprint;
  String? _errorMessage;

  bool get _isWeb => widget.isWeb ?? kIsWeb;

  @override
  void initState() {
    super.initState();
    if (_isWeb) {
      _checkExistingSession();
    }
  }

  /// Best-effort, side-effect-free check for an already-live session (e.g.
  /// this device was enrolled in a previous visit). Uses
  /// [OperatorSessionService.hasLiveSession] (a pure cache read, no network
  /// call) rather than [OperatorSessionService.ensureSession], so a
  /// not-yet-enrolled device never arms the service's negative-cache window
  /// on mount, which would otherwise also block a real enrollment attempted
  /// moments later via [_link].
  void _checkExistingSession() {
    final service = ref.read(operatorSessionServiceProvider);
    if (!service.hasLiveSession()) return;
    service.identity.ensure().then((kp) {
      if (!mounted) return;
      setState(() {
        _status = _LinkStatus.linked;
        _fingerprint = kp.fingerprint;
      });
    }).catchError((_) {
      // Local identity read failed unexpectedly: stay in the idle state
      // rather than claim "linked" without a fingerprint to back it up.
    });
  }

  Future<void> _link() async {
    setState(() {
      _status = _LinkStatus.linking;
      _errorMessage = null;
    });
    final service = ref.read(operatorSessionServiceProvider);
    try {
      final window = await service.openEnrollWindow();
      final windowNonce = window["window_nonce"] as String?;
      if (windowNonce == null || windowNonce.isEmpty) {
        throw StateError(
          "enrollment window response missing required field "
          "'window_nonce'",
        );
      }
      await service.enroll(windowNonce);
      await service.ensureSession();
      final kp = await service.identity.ensure();
      if (!mounted) return;
      setState(() {
        _status = _LinkStatus.linked;
        _fingerprint = kp.fingerprint;
      });
    } on DioException catch (e) {
      _showFailure(e.response?.statusCode);
    } catch (_) {
      _showFailure(null);
    }
  }

  /// Re-validate an existing link without repeating enrollment: just
  /// [OperatorSessionService.ensureSession] again (e.g. after a token
  /// expired or was revoked).
  Future<void> _refreshSession() async {
    final service = ref.read(operatorSessionServiceProvider);
    try {
      await service.ensureSession();
      final kp = await service.identity.ensure();
      if (!mounted) return;
      setState(() {
        _status = _LinkStatus.linked;
        _fingerprint = kp.fingerprint;
        _errorMessage = null;
      });
    } on DioException catch (e) {
      _showFailure(e.response?.statusCode);
    } catch (_) {
      _showFailure(null);
    }
  }

  void _showFailure(int? statusCode) {
    if (!mounted) return;
    setState(() {
      _status = _LinkStatus.error;
      _errorMessage = (statusCode == 401 || statusCode == 403)
          ? kNotTrustedOperatorMessage
          : _kGenericLinkFailureMessage;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    if (!_isWeb) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: GlassCard(
          padding: EdgeInsets.zero,
          child: Material(
            color: Colors.transparent,
            child: ListTile(
              leading: const Icon(
                Icons.link_off_rounded,
                color: SovereignColors.textTertiary,
              ),
              title: const Text("Link this device"),
              subtitle: const Text(
                "Device linking is supported on the web app for now.",
              ),
            ),
          ),
        ),
      );
    }

    final linked = _status == _LinkStatus.linked;
    final linking = _status == _LinkStatus.linking;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GlassCard(
        padding: EdgeInsets.zero,
        // GlassCard paints its own background on a Container (a
        // DecoratedBox), so a ListTile nested directly inside it would paint
        // its ink splashes/background onto the nearest Material ancestor
        // ABOVE that DecoratedBox, invisibly. Wrapping in a transparent
        // Material gives the ListTiles below their own correct paint
        // surface.
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  Icons.link_rounded,
                  color: linked
                      ? SovereignColors.accentEncrypt
                      : SovereignColors.textTertiary,
                ),
                title: Text(
                  linked ? "This device is linked" : "Link this device",
                ),
                subtitle: _buildSubtitle(tt),
                trailing: linking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        key: const Key("operator-enroll-action"),
                        onPressed: _link,
                        child: Text(linked ? "Re-link" : "Link"),
                      ),
              ),
              if (linked) ...[
                const Divider(height: 1, indent: 56),
                ListTile(
                  key: const Key("operator-enroll-refresh"),
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text("Refresh session"),
                  onTap: _refreshSession,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitle(TextTheme tt) {
    switch (_status) {
      case _LinkStatus.linked:
        return Text(
          "Fingerprint ${_formatFingerprint(_fingerprint ?? "")}",
          style: tt.labelSmall?.copyWith(
            fontFamily: "JetBrainsMono",
            color: SovereignColors.accentEncrypt,
          ),
        );
      case _LinkStatus.error:
        return Text(
          _errorMessage ?? _kGenericLinkFailureMessage,
          style: tt.labelSmall?.copyWith(
            color: SovereignColors.accentWarning,
          ),
        );
      case _LinkStatus.linking:
        return const Text("Linking...");
      case _LinkStatus.idle:
        return const Text(
          "Enroll this device's key so it can obtain an operator session.",
        );
    }
  }
}

/// Short, grouped-hex rendering of a fingerprint, truncated to 16 hex chars
/// (same grouped style as the Encryption card's fingerprint elsewhere on
/// this screen), e.g. "DEAD BEEF DEAD BEEF...".
String _formatFingerprint(String fp) {
  if (fp.isEmpty) return "";
  final clean = fp.replaceAll(" ", "").toUpperCase();
  final truncated = clean.length > 16 ? clean.substring(0, 16) : clean;
  final groups = <String>[];
  for (var i = 0; i < truncated.length; i += 4) {
    groups.add(truncated.substring(i, (i + 4).clamp(0, truncated.length)));
  }
  final out = groups.join(" ");
  return clean.length > 16 ? "$out..." : out;
}
