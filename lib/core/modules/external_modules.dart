import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/daemon_config.dart';
import '../router/app_router.dart';
import 'module_manifest.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Dynamic subapp-manifest discovery (card e378d895, umbrella epic 22bcf855).
/// ─────────────────────────────────────────────────────────────────────────
///
/// The shell's module registry is a `const` list ([kBuiltinModules]). Each
/// subapp now also serves a SKWorld Level-2 manifest (`skworld.module.json`,
/// reconciled spec 3.1 / umbrella shell design section 5.2). This file lets the
/// shell DISCOVER those external manifests at runtime and fold them into the
/// same registry, so a brand-new subapp shows up as a nav section WITHOUT a
/// Flutter code change.
///
/// SAFETY: the whole path is behind a compile-time flag ([kUseShellDynamicModules],
/// DEFAULT FALSE). Until Chef flips it the deployed app is byte-for-byte the
/// static registry it is today. Discovery is best-effort: any 404 / timeout /
/// malformed response falls back to exactly [kBuiltinModules] and never breaks
/// the nav.

/// Compile-time gate for runtime manifest discovery. Flip on with:
///   flutter build web --dart-define=USE_SHELL_DYNAMIC_MODULES=true
const bool kUseShellDynamicModules =
    bool.fromEnvironment('USE_SHELL_DYNAMIC_MODULES', defaultValue: false);

/// The shell manifest-discovery endpoint, served by the skchat webui behind the
/// same 443 funnel as `/api/v1/capabilities`. Returns
/// `{"modules": [ <skworld.module.json>, ... ]}`.
const String kShellModulesPath = '/api/v1/shell/modules';

/// Map a manifest `nav.icon` TOKEN (never a URL, per spec 5.2) to a Material
/// [IconData]. Unknown tokens fall back to a generic module glyph, so an
/// unrecognised icon degrades gracefully instead of failing discovery.
IconData iconForToken(String? token) {
  switch ((token ?? '').trim().toLowerCase()) {
    case 'dashboard':
      return Icons.dashboard_outlined;
    case 'chat':
    case 'message':
    case 'messages':
      return Icons.chat_bubble_outline_rounded;
    case 'terminal':
    case 'code':
      return Icons.terminal_outlined;
    case 'folder':
    case 'files':
      return Icons.folder_outlined;
    case 'map':
      return Icons.map_outlined;
    case 'radar':
      return Icons.radar_outlined;
    case 'settings':
    case 'control':
      return Icons.settings_outlined;
    case 'hub':
      return Icons.hub_outlined;
    case 'apps':
    case 'grid':
      return Icons.apps_outlined;
    case 'dns':
    case 'server':
    case 'node':
      return Icons.dns_outlined;
    case 'monitor':
    case 'health':
      return Icons.monitor_heart_outlined;
    case 'graph':
    case 'analytics':
      return Icons.bubble_chart_outlined;
    case 'kanban':
    case 'board':
      return Icons.dashboard_customize_outlined;
    case 'search':
      return Icons.search_outlined;
    case 'security':
    case 'shield':
      return Icons.shield_outlined;
    case 'notifications':
    case 'bell':
      return Icons.notifications_outlined;
    case 'people':
    case 'contacts':
      return Icons.people_outline_rounded;
    default:
      return Icons.widgets_outlined;
  }
}

/// Parse ONE Level-2 subapp manifest (spec 5.2) into a [ModuleManifest] the
/// registry pipeline understands. Returns null when the manifest lacks the
/// minimum fields (`id`, `entry.url`) so a single malformed entry is skipped
/// rather than poisoning the whole batch.
///
/// Tolerant of both snake_case (`deeplink_prefix`) and camelCase keys, and of a
/// `nav` block that may be absent (falls back to id-derived label / order 900,
/// which parks unknown modules at the end of the nav).
ModuleManifest? externalManifestFromJson(Map<String, dynamic> json) {
  final id = (json['id'] as String?)?.trim();
  if (id == null || id.isEmpty) return null;

  final entry = (json['entry'] as Map?)?.cast<String, dynamic>() ?? const {};
  final entryUrl = (entry['url'] as String?)?.trim();
  if (entryUrl == null || entryUrl.isEmpty) return null;

  final nav = (json['nav'] as Map?)?.cast<String, dynamic>() ?? const {};
  final navLabel = (nav['label'] as String?)?.trim();
  final name = (json['name'] as String?)?.trim();
  final title =
      (navLabel != null && navLabel.isNotEmpty) ? navLabel : (name ?? id);

  final orderRaw = nav['order'];
  final order = orderRaw is int
      ? orderRaw
      : int.tryParse(orderRaw?.toString() ?? '') ?? 900;

  final icon = iconForToken(nav['icon'] as String?);
  final grade = ((json['grade'] as String?) ?? 'B').trim().toUpperCase();

  return ModuleManifest(
    id: id,
    title: title,
    icon: icon,
    route: AppRoutes.externalModulePath(id),
    // Discovered subapps default into the bottom nav so they surface as a
    // section immediately (spec: skos/skdashboard register nav positions).
    defaultPlacement: ModulePlacement.nav,
    order: order,
    description: name != null && name != title ? name : null,
    external: true,
    externalEntryUrl: entryUrl,
    grade: grade.isEmpty ? 'B' : grade,
  );
}

/// Parse the discovery payload (`{"modules": [...]}`) into module manifests,
/// skipping any malformed entries. Accepts a bare list too, for leniency.
List<ModuleManifest> parseShellModules(dynamic payload) {
  List raw;
  if (payload is Map && payload['modules'] is List) {
    raw = payload['modules'] as List;
  } else if (payload is List) {
    raw = payload;
  } else {
    return const [];
  }
  final out = <ModuleManifest>[];
  for (final item in raw) {
    if (item is Map) {
      final m = externalManifestFromJson(item.cast<String, dynamic>());
      if (m != null) out.add(m);
    }
  }
  return out;
}

/// Thin best-effort client for the shell manifest-discovery endpoint. Mirrors
/// [CapabilitiesClient]: returns an empty list on ANY failure so the caller
/// falls back to the static registry.
class ShellModulesClient {
  ShellModulesClient({String? baseUrl, Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? kDefaultDaemonUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 10),
                headers: {'Content-Type': 'application/json'},
              ),
            ) {
    if (dio != null && baseUrl != null) {
      _dio.options.baseUrl = baseUrl;
    }
  }

  final Dio _dio;

  Future<List<ModuleManifest>> fetch() async {
    try {
      final resp = await _dio.get(kShellModulesPath);
      return parseShellModules(resp.data);
    } catch (_) {
      return const [];
    }
  }
}

final shellModulesClientProvider = Provider<ShellModulesClient>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  return ShellModulesClient(baseUrl: baseUrl);
});

/// Discovered external subapp modules. Resolves to `[]` when the discovery flag
/// is off (the default), when the endpoint is unreachable, or when the payload
/// is malformed, so the registry always has a safe fallback. Re-fetches when
/// the daemon URL changes.
final externalModulesProvider = FutureProvider<List<ModuleManifest>>((ref) async {
  if (!kUseShellDynamicModules) return const [];
  final client = ref.watch(shellModulesClientProvider);
  return client.fetch();
});

/// Merge discovered [external] modules INTO the [builtins]. Builtins win on id
/// collision (a served `skchat`/`skcode`/`spaces` manifest never displaces the
/// native surface); only genuinely-new ids (e.g. `skdashboard`, `skos`) are
/// added. The result is sorted by nav order.
List<ModuleManifest> mergeModules(
  List<ModuleManifest> builtins,
  List<ModuleManifest> external,
) {
  final ids = {for (final m in builtins) m.id};
  final out = <ModuleManifest>[...builtins];
  for (final e in external) {
    if (ids.add(e.id)) out.add(e);
  }
  out.sort((a, b) => a.order.compareTo(b.order));
  return out;
}

/// Look up a discovered module by id (used by the external host route).
final externalModuleByIdProvider =
    Provider.family<ModuleManifest?, String>((ref, id) {
  final list = ref.watch(externalModulesProvider).asData?.value ?? const [];
  for (final m in list) {
    if (m.id == id) return m;
  }
  return null;
});
