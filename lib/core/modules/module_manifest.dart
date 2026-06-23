import 'package:flutter/material.dart';

import '../../services/capabilities_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Module spine — declarative manifest model (Phase 0 of the Comms Suite).
/// ─────────────────────────────────────────────────────────────────────────
///
/// Today every surface the app exposes is hand-wired in three places at once:
/// the AppShell `_tabs` const, the ~30 GoRoutes in `app_router.dart`, and the
/// `HubScreen` tile list. A new feature means editing all three in lockstep.
///
/// A [ModuleManifest] is a *declaration* of one surface — its id, title, icon,
/// route, the capabilities it needs, where it should live (nav / toolbar /
/// drawer), and who may see it. The registry holds a `const` list of these;
/// providers cross them with the live node capability document and the user's
/// per-slot placement preferences to derive what actually renders.
///
/// This is the VS-Code/Obsidian "declarative manifest + named contribution
/// points" pattern, with the decisive split the plan calls out: **availability**
/// (capability-gated, global, honest) vs **placement/visibility**
/// (settings-driven, per-slot).

/// A reference to a node capability a module requires, e.g. `service:geo-cot`
/// or `transport:webrtc`. Parsed from the compact `"<kind>:<id>"` string form
/// used in const manifests so the whole registry stays const-constructible.
@immutable
class CapabilityRef {
  const CapabilityRef(this.raw);

  /// The compact source string, e.g. `"service:geo-cot"`.
  final String raw;

  /// The kind segment — `service` or `transport` (lower-cased).
  String get kind {
    final i = raw.indexOf(':');
    return i < 0 ? '' : raw.substring(0, i).toLowerCase();
  }

  /// The id segment — e.g. `geo-cot`, `webrtc`. Empty when malformed.
  String get id {
    final i = raw.indexOf(':');
    return i < 0 ? raw : raw.substring(i + 1);
  }

  bool get isService => kind == 'service';
  bool get isTransport => kind == 'transport';

  /// Resolve this reference against a node capability document, returning the
  /// matching [CapStatus]. A ref whose kind/id is not present in the document
  /// resolves to [CapStatus.unconfigured] (honest: we can't claim it's up).
  CapStatus resolve(NodeCapabilities? caps) {
    if (caps == null) return CapStatus.unknown;
    if (isService) {
      for (final s in caps.services) {
        if (s.id == id) return s.status;
      }
      return CapStatus.unconfigured;
    }
    if (isTransport) {
      for (final t in caps.transports) {
        if (t.id == id) return t.status;
      }
      return CapStatus.unconfigured;
    }
    return CapStatus.unknown;
  }

  @override
  bool operator ==(Object other) => other is CapabilityRef && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => raw;
}

/// Whether a [CapStatus] counts a capability as **available** for the purpose
/// of un-greying a module. Up / configured / degraded all count as available
/// (the module can be used, perhaps imperfectly); down / unconfigured / unknown
/// do NOT — the module greys out with a reason rather than vanishing.
bool capStatusAvailable(CapStatus status) {
  switch (status) {
    case CapStatus.up:
    case CapStatus.configured:
    case CapStatus.degraded:
      return true;
    case CapStatus.down:
    case CapStatus.unconfigured:
    case CapStatus.unknown:
      return false;
  }
}

/// Where a module surfaces by default. Users can override per-module via the
/// Modules settings tab; this is only the seed.
enum ModulePlacement {
  /// Bottom-nav tab — core sub-apps (Chats, Activity, Calls, …).
  nav,

  /// A per-screen AppBar action icon — the "promote to toolbar" slot.
  toolbar,

  /// The swipe-up app drawer — the "all enabled sub-apps" grid.
  drawer,
}

/// Parse a persisted placement slot string back to [ModulePlacement].
ModulePlacement? modulePlacementFromString(String? s) {
  switch (s) {
    case 'nav':
      return ModulePlacement.nav;
    case 'toolbar':
      return ModulePlacement.toolbar;
    case 'drawer':
      return ModulePlacement.drawer;
    default:
      return null;
  }
}

extension ModulePlacementName on ModulePlacement {
  String get wire => name; // 'nav' | 'toolbar' | 'drawer'
  String get label {
    switch (this) {
      case ModulePlacement.nav:
        return 'Bottom nav';
      case ModulePlacement.toolbar:
        return 'Toolbar';
      case ModulePlacement.drawer:
        return 'App drawer';
    }
  }
}

/// Who may see / use a module. `everyone` modules show to any identity;
/// `operator` modules are operator-control surfaces (Cluster, skos Control, …)
/// and are grouped separately in the drawer.
enum ModuleRole {
  everyone,
  operator,
}

extension ModuleRoleName on ModuleRole {
  String get label => this == ModuleRole.operator ? 'Operator' : 'Everyone';
}

/// Optional activation hook context (Obsidian `register*` model). Reserved for
/// later phases — modules that need to register handlers / warm caches on first
/// activation receive this. Kept intentionally minimal for Phase 0.
@immutable
class ModuleContext {
  const ModuleContext({this.moduleId});
  final String? moduleId;
}

/// A declared app surface — const-constructible so the whole registry is a
/// compile-time constant.
@immutable
class ModuleManifest {
  const ModuleManifest({
    required this.id,
    required this.title,
    required this.icon,
    required this.route,
    this.activeIcon,
    this.version = 1,
    this.minDaemonApi = 0,
    this.requires = const [],
    this.defaultPlacement = ModulePlacement.drawer,
    this.role = ModuleRole.everyone,
    this.order = 0,
    this.description,
    this.onActivate,
  });

  /// Stable identifier, e.g. `'skmap'`, `'chats'`, `'cluster'`.
  final String id;

  /// Human-facing title.
  final String title;

  /// Icon for nav/drawer/toolbar.
  final IconData icon;

  /// Optional active-state icon (bottom nav uses a filled variant when active).
  final IconData? activeIcon;

  /// GoRoute path the module routes to, e.g. `'/skmap'`.
  final String route;

  /// Module schema version (for future migrations).
  final int version;

  /// Minimum daemon API version (`capabilities.api`) this module needs. `0`
  /// means "no daemon-API floor".
  final int minDaemonApi;

  /// Capabilities EVERY one of which must resolve to an available [CapStatus]
  /// for the module to light up. Empty = always available.
  final List<CapabilityRef> requires;

  /// Where the module surfaces by default (user-overridable).
  final ModulePlacement defaultPlacement;

  /// Audience / grouping.
  final ModuleRole role;

  /// Sort order within a slot (lower first).
  final int order;

  /// Optional one-line description (drawer/settings subtitle).
  final String? description;

  /// Optional lazy-activation hook (reserved — not invoked in Phase 0).
  final Future<void> Function(ModuleContext)? onActivate;

  /// Icon shown when this module's nav tab is active.
  IconData get effectiveActiveIcon => activeIcon ?? icon;
}

/// The resolved availability of a module against a capability document — what
/// the UI needs to render either a live tile or a greyed-with-a-reason one.
@immutable
class ModuleAvailability {
  const ModuleAvailability({
    required this.manifest,
    required this.available,
    this.reason,
  });

  final ModuleManifest manifest;

  /// True when every required capability is available AND the daemon API floor
  /// is met. False → render greyed with [reason].
  final bool available;

  /// Human-readable reason a module is unavailable (e.g. "Geo / CoT is down").
  /// Null when [available].
  final String? reason;

  /// Compute availability of [manifest] against [caps] (and the node's
  /// advertised daemon `api` version). Returns the first failing reason so the
  /// UI can be honest about *why* a module is greyed — never silently hidden.
  factory ModuleAvailability.resolve(
    ModuleManifest manifest,
    NodeCapabilities? caps, {
    int? daemonApi,
  }) {
    // Daemon API floor.
    if (manifest.minDaemonApi > 0) {
      if (daemonApi == null) {
        return ModuleAvailability(
          manifest: manifest,
          available: false,
          reason: 'Daemon API version unknown',
        );
      }
      if (daemonApi < manifest.minDaemonApi) {
        return ModuleAvailability(
          manifest: manifest,
          available: false,
          reason:
              'Needs daemon API v${manifest.minDaemonApi} (node is v$daemonApi)',
        );
      }
    }

    // Capability gating — EVERY required ref must be available.
    for (final ref in manifest.requires) {
      final status = ref.resolve(caps);
      if (!capStatusAvailable(status)) {
        return ModuleAvailability(
          manifest: manifest,
          available: false,
          reason: '${_refLabel(ref)} is ${_statusWord(status)}',
        );
      }
    }

    return ModuleAvailability(manifest: manifest, available: true);
  }
}

/// Friendly label for a capability ref in a "X is down" reason string.
String _refLabel(CapabilityRef ref) {
  switch (ref.raw) {
    case 'service:geo-cot':
      return 'Geo / CoT';
    case 'service:text':
      return 'Chat';
    case 'service:voice':
      return 'Voice';
    case 'service:video':
      return 'Video';
    case 'service:file-transfer':
      return 'File transfer';
    case 'service:data-streaming':
      return 'Data streaming';
    case 'service:federation':
      return 'Federation';
    case 'service:access-plane':
      return 'Access plane';
    case 'transport:webrtc':
      return 'WebRTC';
    case 'transport:nostr':
      return 'Nostr';
    default:
      return ref.id;
  }
}

String _statusWord(CapStatus status) {
  switch (status) {
    case CapStatus.down:
      return 'down';
    case CapStatus.unconfigured:
      return 'unconfigured';
    case CapStatus.unknown:
      return 'unavailable';
    case CapStatus.up:
      return 'up';
    case CapStatus.configured:
      return 'configured';
    case CapStatus.degraded:
      return 'degraded';
  }
}
