import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/theme/sovereign_colors.dart';

/// The S3 reason codes that make a guest contact/link permanently unusable.
/// Distinct from a generic "join failed" (which is retryable / transient).
const _terminalReasons = {'contact_revoked', 'contact_expired'};

/// Pull the S3 `reason` out of a 403 error body, or null if this is not a
/// contact-terminal 403. The server returns `{detail: {reason: "..."}}`.
String? contactTerminalReason(Object error) {
  if (error is! DioException) return null;
  if (error.response?.statusCode != 403) return null;
  final data = error.response?.data;
  final detail = data is Map ? data['detail'] : null;
  final reason = detail is Map ? detail['reason'] : (data is Map ? data['reason'] : null);
  if (reason is String && _terminalReasons.contains(reason)) return reason;
  return null;
}

/// A terminal "this invite is no longer active" screen, shown when a guest's
/// contact was revoked or its link expired (guest-dm C2, S3 reason codes).
/// Deliberately distinct from a generic join failure: there is nothing to
/// retry, the operator ended (or time expired) this access.
class GuestInviteInactiveView extends StatelessWidget {
  const GuestInviteInactiveView({super.key, this.reason});

  /// One of `contact_revoked` / `contact_expired`, or null (unknown terminal).
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final expired = reason == 'contact_expired';
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  expired
                      ? Icons.hourglass_disabled_rounded
                      : Icons.link_off_rounded,
                  size: 48,
                  color: SovereignColors.textTertiary,
                ),
                const SizedBox(height: 16),
                Text(
                  'This invite is no longer active',
                  style: tt.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  expired
                      ? 'This chat invite has expired. Ask for a new link to '
                          'reconnect.'
                      : 'Access to this chat was ended by the person who '
                          'invited you. Ask for a new link if you need to '
                          'reconnect.',
                  style: tt.bodyMedium
                      ?.copyWith(color: SovereignColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
