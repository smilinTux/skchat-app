import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:skchat/services/livekit_call_service.dart";

MediaDevice _dev(String id, String label) =>
    MediaDevice(id, label, "videoinput", null);

void main() {
  group("isVirtualDeviceLabel", () {
    test("flags known virtual / loopback labels (case-insensitive)", () {
      for (final label in const [
        "DroidCam Source 3",
        "OBS Virtual Camera",
        "v4l2loopback",
        "Virtual Webcam",
        "Snap Camera",
        "ManyCam Virtual Webcam",
        "null",
      ]) {
        expect(LiveKitCallService.isVirtualDeviceLabel(label), isTrue,
            reason: label);
      }
    });

    test("passes real devices through", () {
      for (final label in const [
        "Integrated Camera",
        "Logitech BRIO",
        "FaceTime HD Camera",
        "MacBook Pro Microphone",
      ]) {
        expect(LiveKitCallService.isVirtualDeviceLabel(label), isFalse,
            reason: label);
      }
    });
  });

  group("pickDefaultDeviceId", () {
    test("returns null for an empty list", () {
      expect(LiveKitCallService.pickDefaultDeviceId(const []), isNull);
    });

    test("prefers the first NON-virtual device", () {
      final devices = [
        _dev("dc0", "DroidCam Source 3"),
        _dev("cam1", "Integrated Camera"),
        _dev("cam2", "Logitech BRIO"),
      ];
      expect(LiveKitCallService.pickDefaultDeviceId(devices), "cam1");
    });

    test("falls back to the first device when every candidate is virtual", () {
      final devices = [
        _dev("dc0", "DroidCam Source 3"),
        _dev("obs0", "OBS Virtual Camera"),
      ];
      expect(LiveKitCallService.pickDefaultDeviceId(devices), "dc0");
    });
  });
}
