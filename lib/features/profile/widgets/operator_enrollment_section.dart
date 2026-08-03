import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/theme/theme.dart";
import "../../../services/operator_session_service.dart";
import "../../../services/operator_token.dart" as op_token;
import "../../../services/self_identity_provider.dart";

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
///     /api/v1/auth/enroll/open`), operator-gated on the server: when
///     `SKCHAT_GUEST_OPERATOR_TOKEN` is set, this route requires the
///     manually-pasted operator token as the `X-Operator-Token` header
///     (read internally by the service via `operator_token.dart`). This
///     section renders the paste field for that token, above the Link
///     button, so the flow reads top-to-bottom: paste the token, then link.
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
/// Platform-agnostic: shown on every platform (web and native alike), each
/// backed by its own [GuestIdentity] implementation (see
/// guest_identity_web.dart / guest_identity_io.dart).
class OperatorEnrollmentSection extends ConsumerStatefulWidget {
  const OperatorEnrollmentSection({
    super.key,
    this.tokenReader,
    this.tokenWriter,
  });

  /// Test-only override of the operator-token read seam (defaults to the
  /// real [op_token.operatorToken] when null): production code never passes
  /// this, tests inject a fake so the token field's initial value can be
  /// exercised deterministically without depending on the web-only
  /// localStorage implementation (a no-op under `flutter test`'s VM target,
  /// see `operator_token_stub.dart`).
  final String? Function()? tokenReader;

  /// Test-only override of the operator-token write seam (defaults to the
  /// real [op_token.setOperatorToken] when null).
  final void Function(String?)? tokenWriter;

  @override
  ConsumerState<OperatorEnrollmentSection> createState() =>
      _OperatorEnrollmentSectionState();
}

class _OperatorEnrollmentSectionState
    extends ConsumerState<OperatorEnrollmentSection> {
  _LinkStatus _status = _LinkStatus.idle;
  String? _fingerprint;
  String? _errorMessage;
  late final TextEditingController _tokenController;

  // Obscured by DEFAULT (the token is a secret), with an eye toggle to unmask.
  // NOTE: Flutter web BLOCKS paste + the context menu on an obscured field, so to
  // paste the token the operator taps the eye to unmask first, pastes, then can
  // re-hide. The toggle is what makes both hiding and pasting possible.
  bool _obscureToken = true;

  String? Function() get _readToken =>
      widget.tokenReader ?? op_token.operatorToken;

  void Function(String?) get _writeToken =>
      widget.tokenWriter ?? op_token.setOperatorToken;

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(text: _readToken() ?? "");
    _checkExistingSession();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  /// One-tap paste from the clipboard into the (obscured) token field. Flutter
  /// web blocks paste on an obscured TextField, so reading the clipboard on this
  /// button's tap (a user gesture) is what lets the operator paste without first
  /// unmasking. No-op on empty/unavailable clipboard.
  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _tokenController.text = text;
    _tokenController.selection =
        TextSelection.collapsed(offset: _tokenController.text.length);
    _writeToken(text);
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
    service.identity
        .ensure()
        .then((kp) {
          if (!mounted) return;
          setState(() {
            _status = _LinkStatus.linked;
            _fingerprint = kp.fingerprint;
          });
        })
        .catchError((_) {
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
      // service.enroll() already resets the service's own negative cache on
      // success; ensureSession() below relies on that so it retries the
      // handshake fresh instead of rethrowing a failure recorded before this
      // device was enrolled.
      await service.enroll(windowNonce);
      await service.ensureSession();
      final kp = await service.identity.ensure();
      // This device just went from unenrolled to a live operator session:
      // [selfIdentityProvider]'s tier is derived from
      // [OperatorSessionService.hasLiveSession], a plain method call it has
      // no reactive way to observe on its own, so invalidate it here to
      // force every surface reading it (profile, QR, conf, calls) to
      // recompute to green now instead of staying red until some unrelated
      // rebuild happens to pick it up.
      ref.invalidate(selfIdentityProvider);
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
      // Same reasoning as in [_link]: force [selfIdentityProvider] to
      // recompute now that a live session is confirmed, rather than relying
      // on an unrelated rebuild to notice.
      ref.invalidate(selfIdentityProvider);
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  key: const Key("operator-token-field"),
                  controller: _tokenController,
                  obscureText: _obscureToken,
                  enableInteractiveSelection: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (value) => _writeToken(value.trim()),
                  decoration: InputDecoration(
                    labelText: "Operator token",
                    helperText:
                        "Paste your server's operator token "
                        "(SKCHAT_GUEST_OPERATOR_TOKEN) to authorize linking "
                        "this device.",
                    helperMaxLines: 2,
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Dedicated paste: fills the field from the clipboard
                        // WITHOUT unmasking (web blocks paste on an obscured
                        // field, so a button that reads the clipboard on tap is
                        // the intuitive one-tap paste).
                        IconButton(
                          icon: const Icon(Icons.content_paste_rounded,
                              size: 20),
                          tooltip: "Paste token",
                          onPressed: _pasteToken,
                        ),
                        IconButton(
                          icon: Icon(
                            _obscureToken
                                ? Icons.visibility_rounded
                                : Icons.visibility_off_rounded,
                            size: 20,
                          ),
                          tooltip: _obscureToken ? "Show" : "Hide",
                          onPressed: () =>
                              setState(() => _obscureToken = !_obscureToken),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
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
          style: tt.labelSmall?.copyWith(color: SovereignColors.accentWarning),
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
