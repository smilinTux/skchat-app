// Unit tests for the runtime-settable backend (Spaces/LiveKit/skcapstone)
// config: defaults, preset apply, custom-host derivation, and a Hive
// persistence round-trip through BackendConfigNotifier.
import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:skchat/services/backend_config.dart";

void main() {
  group("BackendConfig defaults", () {
    test("defaults match the compile-time seeds", () {
      const d = BackendConfig.defaults;
      expect(d.skchatWebuiUrl, kDefaultSkchatWebuiUrl);
      expect(d.livekitWebuiUrl, kDefaultLivekitWebuiUrl);
      expect(d.livekitUrl, kDefaultLivekitUrl);
      expect(d.skcapstoneUrl, kDefaultSkcapstoneUrl);
      expect(d.skcapstoneDashboardUrl, kDefaultSkcapstoneDashboardUrl);
      expect(d.instanceId, "default");
    });

    test("equality + hashCode are value-based", () {
      const a = BackendConfig.defaults;
      final b = BackendConfig.defaults.copyWith();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      final c = a.copyWith(skchatWebuiUrl: "https://other");
      expect(a == c, isFalse);
    });
  });

  group("presets", () {
    test("lumina + jarvis presets resolve by id", () {
      expect(presetById("lumina")?.label, "lumina @ .158");
      expect(presetById("jarvis")?.label, "jarvis @ .41");
      expect(presetById("nope"), isNull);
    });

    test("jarvis preset uses the .41 MagicDNS host on tail204f0c", () {
      final jarvis = presetById("jarvis")!;
      const host = "cbrd21-laptop12thgenintelcore.tail204f0c.ts.net";
      expect(jarvis.daemonUrl, "https://$host");
      expect(jarvis.config.skchatWebuiUrl, "https://$host");
      expect(jarvis.config.livekitUrl, "wss://$host:8443");
      expect(jarvis.config.skcapstoneUrl, "http://$host:7777");
      expect(jarvis.config.skcapstoneDashboardUrl, "http://$host:7778");
    });
  });

  group("BackendConfigNotifier", () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp("skchat_backend_cfg_test");
      Hive.init(tmp.path);
    });

    tearDown(() async {
      // Let any in-flight async _loadPersisted() (fired by build()) settle
      // before we tear down Hive, so it never races a deleted box file.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await Hive.close();
      await Hive.deleteFromDisk();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test("seeds from the compile-time defaults", () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // build() returns defaults synchronously (persisted load is async).
      final cfg = container.read(backendConfigProvider);
      expect(cfg, BackendConfig.defaults);
      // Let the async _loadPersisted() finish so it doesn't leak into tearDown.
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    test("applyPreset overrides every non-daemon backend", () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(backendConfigProvider.notifier);

      await notifier.applyPreset(presetById("jarvis")!);

      final cfg = container.read(backendConfigProvider);
      expect(cfg.instanceId, "jarvis");
      expect(
        cfg.skchatWebuiUrl,
        "https://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net",
      );
      expect(
        cfg.livekitUrl,
        "wss://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net:8443",
      );
    });

    test("setCustomHost derives ws + port-specific URLs from one host",
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(backendConfigProvider.notifier);

      await notifier.setCustomHost("https://myhost.example.ts.net/");

      final cfg = container.read(backendConfigProvider);
      expect(cfg.instanceId, "custom");
      expect(cfg.skchatWebuiUrl, "https://myhost.example.ts.net");
      expect(cfg.livekitWebuiUrl, "https://myhost.example.ts.net");
      expect(cfg.livekitUrl, "wss://myhost.example.ts.net:8443");
      expect(cfg.skcapstoneUrl, "http://myhost.example.ts.net:7777");
      expect(cfg.skcapstoneDashboardUrl, "http://myhost.example.ts.net:7778");
    });

    test("persists across a fresh container (round-trip)", () async {
      // Container 1 sets a preset.
      final c1 = ProviderContainer();
      await c1.read(backendConfigProvider.notifier).applyPreset(
            presetById("jarvis")!,
          );
      c1.dispose();

      // Container 2 must load the persisted override from Hive.
      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      // Touch the provider to trigger build() + async _loadPersisted().
      c2.read(backendConfigProvider);
      // Allow the async Hive load to complete.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final cfg = c2.read(backendConfigProvider);
      expect(cfg.instanceId, "jarvis");
      expect(
        cfg.skchatWebuiUrl,
        "https://cbrd21-laptop12thgenintelcore.tail204f0c.ts.net",
      );
    });

    test("reset clears the persisted override", () async {
      final c1 = ProviderContainer();
      await c1.read(backendConfigProvider.notifier).applyPreset(
            presetById("lumina")!,
          );
      await c1.read(backendConfigProvider.notifier).reset();
      expect(c1.read(backendConfigProvider), BackendConfig.defaults);
      c1.dispose();

      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      c2.read(backendConfigProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c2.read(backendConfigProvider), BackendConfig.defaults);
    });
  });
}
