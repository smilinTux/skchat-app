import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/guest_identity.dart';
// `show` avoids an ambiguous-import error: guest_identity.dart and
// guest_identity_io.dart each declare their own top-level
// createGuestIdentity(); only the type is needed here.
import 'package:skchat/services/guest_identity_io.dart'
    show NativeGuestIdentity;

void main() {
  test('native factory yields the real NativeGuestIdentity, not the stub', () {
    expect(createGuestIdentity(), isA<NativeGuestIdentity>());
  });
}
