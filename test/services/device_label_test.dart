import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/device_label.dart";

void main() {
  test(
    "guessDeviceLabel() returns a non-empty label under flutter test's Dart "
    "VM target (dart.library.io resolves the native implementation there, "
    "the same as any real desktop/mobile build)",
    () {
      final label = guessDeviceLabel();
      expect(label, isNotNull);
      expect(label, isNotEmpty);
    },
  );
}
