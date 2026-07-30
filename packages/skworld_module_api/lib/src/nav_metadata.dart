import 'package:flutter/widgets.dart';

/// Navigation metadata a [SkworldModule] declares so the shell can place it in
/// the primary navigation (left rail / bottom bar) without knowing anything
/// about the module's internals.
///
/// This mirrors the `nav` block of the signed `skworld.module.json` manifest
/// (reconciled spec 3.1): `{icon, order, label}` plus the module's deep-link
/// prefix. The manifest is the source of truth at registration time; this
/// value type is the in-process Dart shape the shell consumes once a module is
/// mounted.
@immutable
class ModuleNav {
  const ModuleNav({
    required this.label,
    required this.icon,
    this.order = 100,
    this.deeplinkPrefix,
  });

  /// Human-visible destination label (for example "Chats").
  final String label;

  /// Destination icon shown in the shell navigation.
  final IconData icon;

  /// Sort order among sibling modules. Lower sorts earlier. Matches the
  /// manifest `nav.order`.
  final int order;

  /// The `skworld://<id>/` deep-link prefix this module answers to, if any.
  /// The shell routes matching links into the module and Atlas escalations use
  /// the same prefix (reconciled spec 2.3, shared vocabulary).
  final String? deeplinkPrefix;

  ModuleNav copyWith({
    String? label,
    IconData? icon,
    int? order,
    String? deeplinkPrefix,
  }) {
    return ModuleNav(
      label: label ?? this.label,
      icon: icon ?? this.icon,
      order: order ?? this.order,
      deeplinkPrefix: deeplinkPrefix ?? this.deeplinkPrefix,
    );
  }
}
