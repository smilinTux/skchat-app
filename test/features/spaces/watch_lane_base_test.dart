// Chef: "it's still not syncing the youtube with a late joiner".
//
// Late-join replay is an HTTP GET (LaneService.catchUp). The watch lane was
// built with the COMPILE-TIME kDefaultWebuiUrl, which defaults to "" and is
// NOT passed as a dart-define by the web deploy script, so every one of its
// HTTP calls went to an empty base and failed into a swallowing catch. Live
// play/pause/rate still worked because those ride the LiveKit data channel,
// which is exactly why this looked like "only late joiners are broken".
//
// The rest of the app resolves its base at RUNTIME from backendConfigProvider
// (see spacesServiceProvider). The watch lane must do the same.
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/spaces/watch_session.dart";
import "package:skchat/services/backend_config.dart";
import "package:skchat/services/lane_service.dart";

void main() {
  test("the watch lane is built with the RUNTIME webui base, not the empty "
      "compile-time constant", () {
    const runtimeBase = "https://noroc2027.tail204f0c.ts.net";
    final c = ProviderContainer(overrides: [
      backendConfigProvider.overrideWith(() => _FixedConfig(runtimeBase)),
    ]);
    addTearDown(c.dispose);

    final lane = c.read(laneServiceFactoryProvider)(
        const WatchSessionArgs(spaceId: "s1", identity: "me"));

    expect(lane, isA<LaneService>());
    expect((lane as LaneService).baseUrl, runtimeBase,
        reason: "an empty base makes catchUp fail silently, so late joiners "
            "replay nothing and never see the video");
  });
}

/// Builds the config directly instead of delegating to the real notifier,
/// whose build() reads Hive and would need a box opened for a test that only
/// cares about one URL.
class _FixedConfig extends BackendConfigNotifier {
  _FixedConfig(this.base);
  final String base;
  @override
  BackendConfig build() =>
      BackendConfig.defaults.copyWith(skchatWebuiUrl: base);
}
