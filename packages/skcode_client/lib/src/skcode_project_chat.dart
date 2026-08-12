import "package:flutter/widgets.dart";

/// The project-chat injection seam (card C-12, spec section 10: "an skchat
/// group carrying `meta.project = repo:<name>`"; spec section 4.1's module
/// contract rule that this package "imports only skworld_module_api" means
/// it cannot import the host's chat surface directly).
///
/// Mirrors the pattern [SkcodeModule.origin] (card C-3b) and
/// [SkcodeModule.onOpenLink] (card C-9) already established: the ONE thing
/// this package cannot resolve itself is injected through the module
/// constructor as a builder, never pulled in as a dependency. A host
/// implementation returns the EXISTING native skchat thread surface
/// (`buildLiveSkchatModule()` / `live_chats_surface.dart`'s machinery, spec
/// section 10: "zero new chat infrastructure") scoped to the group bound to
/// [repo], WITHOUT its own `Scaffold`/`AppBar` chrome -- this package
/// supplies that chrome itself where one is needed (the phone chat-chip
/// push route), and places the bare widget directly everywhere else (the
/// four-column tier's chat column, the collapsed Chat tab).
///
/// [repo] is never empty when this builder is invoked: every call site in
/// this package (`SkcodeResponsiveBody`, the phone chat chip) only invokes
/// it once a concrete session's `SkcodeSessionSummary.repo` is known, and
/// renders its OWN honest empty state ("no session selected") otherwise
/// without ever calling this builder. A host whose resolution finds no
/// group bound to that repo (spec section 10, "no project group bound for
/// this repo") is responsible for its own empty state, degrading honestly
/// rather than crashing -- this package cannot express that state itself,
/// since it has no visibility into the host's group store at all.
typedef SkcodeProjectChatBuilder = Widget Function(BuildContext context, String repo);
