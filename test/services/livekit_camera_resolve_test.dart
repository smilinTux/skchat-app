import "package:flutter_test/flutter_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:skchat/services/livekit_call_service.dart";

MediaDevice _dev(String id, String label) =>
    MediaDevice(id, label, "videoinput", null);

void main() {
  test("saved device wins when still present", () {
    final list = [_dev("v0", "Droidcam"), _dev("v1", "Laptop Camera")];
    expect(LiveKitCallService.resolveCameraDeviceId(list, "v1"), "v1");
  });
  test("skips a droidcam/loopback device when no saved choice", () {
    final list = [_dev("v0", "Droidcam"), _dev("v1", "Laptop Camera")];
    expect(LiveKitCallService.resolveCameraDeviceId(list, null), "v1");
  });
  test("saved-but-gone falls back to the smart default", () {
    final list = [_dev("v0", "Droidcam"), _dev("v1", "Laptop Camera")];
    expect(LiveKitCallService.resolveCameraDeviceId(list, "ghost"), "v1");
  });
  test("only a virtual device present returns it (better than nothing)", () {
    final list = [_dev("v0", "Droidcam")];
    expect(LiveKitCallService.resolveCameraDeviceId(list, null), "v0");
  });
  test("empty enumeration returns null", () {
    expect(LiveKitCallService.resolveCameraDeviceId(<MediaDevice>[], null),
        isNull);
  });
}
