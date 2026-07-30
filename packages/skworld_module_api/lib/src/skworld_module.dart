import 'package:flutter/widgets.dart';

import 'nav_metadata.dart';
import 'shell_context.dart';

/// The UI-facet contract a subapp implements to mount into the SKWorld shell.
///
/// This is one of the TWO facets of the single subapp contract (reconciled
/// spec 2.3): the UI facet, consumed in-process by the Dart shell. The other
/// facet (operator: explain/observe/act) is validated separately by
/// `operator_seat/adapter.py` in Python. Both facets are declared by the one
/// signed `skworld.module.json` manifest; this Dart interface is the UI
/// facet's validator/consumer.
///
/// A module implementation is intentionally tiny: an id, its navigation
/// metadata, and a widget builder. Everything the module needs at runtime
/// arrives through the [ShellContext] passed to [build], and that context is
/// NULLABLE so the same module runs standalone (`shell == null`) or mounted
/// (`shell != null`). Add no shell or skchat imports to an implementation of
/// this interface beyond `skworld_module_api` itself (enforced by the
/// standalone import grep gate, reconciled spec 3.2 step 4).
abstract interface class SkworldModule {
  /// Stable module id, matching the manifest `id` (for example "skchat").
  /// Used as the registry key and the `skworld://<id>/` deep-link authority.
  String get id;

  /// Navigation metadata for placement in the shell's primary navigation.
  ModuleNav get nav;

  /// Builds the module's root widget.
  ///
  /// [shell] is NULL in standalone mode (run under the module's own runner,
  /// with its own theme / login / router) and NON-NULL in mounted mode (use
  /// the shell's theme, auth, and bus). Implementations MUST handle both.
  Widget build(BuildContext context, ShellContext? shell);
}
