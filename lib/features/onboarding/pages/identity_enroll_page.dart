import 'package:flutter/material.dart';
import '../../../core/theme/sovereign_colors.dart';
import '../../profile/widgets/operator_enrollment_section.dart';

/// Onboarding step 3: enroll THIS device's key so it can obtain an operator
/// session (the CURRENT identity model, replacing the old PGP generate/import
/// page).
///
/// Reuses [OperatorEnrollmentSection] verbatim, the exact same control the
/// Profile screen shows: paste the operator token, tap Link, and the section
/// drives [OperatorSessionService]'s enroll -> session handshake and shows the
/// device fingerprint on success. Enrollment is not mandatory to proceed (a
/// tailnet/loopback user may not need a token, and anyone can link later from
/// Settings), so Continue is always enabled.
class IdentityEnrollPage extends StatelessWidget {
  const IdentityEnrollPage({super.key, this.onNext});

  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 48),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                Text(
                  'Link This Device',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: SovereignColors.textPrimary,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Enroll this device\'s key with your server to unlock '
                  'operator features. A unique key is generated on-device, '
                  'the private key never leaves it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: SovereignColors.textSecondary,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Expanded(
            child: SingleChildScrollView(
              child: OperatorEnrollmentSection(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  onPressed: onNext,
                  style: FilledButton.styleFrom(
                    backgroundColor: SovereignColors.soulLumina,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Continue',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'You can also link this device later from Settings.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: SovereignColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
