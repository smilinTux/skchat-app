/// skworld_module_api: the UI-facet contract of the SKWorld subapp contract.
///
/// This package holds ONLY the abstract contract types a subapp implements to
/// mount into the SKWorld shell (reconciled spec 3.2 step 1, card f60f4e27):
///
///  * [SkworldModule]  - the interface a subapp implements (id, nav, builder),
///  * [ShellContext]   - what the shell provides a mounted module; NULLABLE at
///                       the boundary so a module detects standalone
///                       (`shell == null`) vs mounted (`shell != null`) mode,
///  * [AuthContext]    - the audience-scoped identity/token surface,
///  * [ShellBus]       - the event/navigation bus abstraction,
///  * [ModuleNav] / [ShellEvent] - the supporting value types.
///
/// It deliberately imports nothing from the shell or from skchat (only Flutter
/// widget/theme primitives), so it can be promoted to its own repo when a
/// second consumer (skcode) adopts it (second-consumer rule, spec 3.2).
library;

export 'src/auth_context.dart';
export 'src/nav_metadata.dart';
export 'src/shell_bus.dart';
export 'src/shell_context.dart';
export 'src/skworld_module.dart';
