import 'package:flutter/material.dart' show ThemeData;

import 'auth_context.dart';
import 'shell_bus.dart';

/// Everything the SKWorld shell provides to a mounted [SkworldModule]: the
/// resolved theme tokens, the audience-scoped [AuthContext], and the
/// [ShellBus] for events and navigation.
///
/// CRUCIAL nullability rule: a [SkworldModule] always receives this as a
/// `ShellContext?`. A NULL context is the STANDALONE signal (reconciled spec
/// 3.2 step 1): the module is running under its own runner (for example
/// `apps/skchat_standalone`) with no shell, and must fall back to its own
/// theme, login, and router. A NON-NULL context is MOUNTED mode: the module
/// composes into the shell and uses these surfaces. A first-class subapp MUST
/// behave correctly in both modes (the standalone CI boot gate proves
/// `shell == null`, reconciled spec 3.2 step 4).
///
/// ABSTRACT: the shell supplies the concrete implementation. No shell or
/// skchat import crosses this boundary; the only Flutter dependency is
/// [ThemeData] for the theme bridge.
abstract interface class ShellContext {
  /// The shell's current theme tokens, so a mounted module renders in the
  /// shell's look (the Sovereign Glass theme) rather than its own.
  ThemeData get theme;

  /// The audience-scoped identity and token surface for this module.
  AuthContext get auth;

  /// The event and navigation bus back to the shell.
  ShellBus get bus;
}
