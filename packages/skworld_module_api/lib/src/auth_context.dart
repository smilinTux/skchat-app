/// The audience-scoped identity and token surface a mounted [SkworldModule]
/// sees.
///
/// A module never holds a root credential and never sees the human's full
/// session. The shell mints a SHORT-LIVED, AUDIENCE-SCOPED token per module
/// (reconciled spec 2.3, "different trust postures": a compromised pane is
/// contained to its audience). The module reads its subject, its granted
/// scopes, and asks the shell to hand it a token when it needs one.
///
/// This is an ABSTRACT interface: the shell supplies the concrete
/// implementation (backed by `capauth` audience minting once M2 lands). A
/// module in standalone mode supplies its own implementation, or receives a
/// null [ShellContext] and runs unauthenticated. No `capauth` or shell import
/// crosses this boundary.
abstract interface class AuthContext {
  /// The audience this context is scoped to (for example "skchat"). Matches the
  /// manifest `auth.audience`.
  String get audience;

  /// The audience-scoped subject identity (a fully-qualified id / FQID), or
  /// null when no identity is established yet.
  String? get subjectFqid;

  /// The set of granted capability scopes (for example
  /// {"chat.read", "chat.send"}). Matches the manifest `auth.scopes`.
  Set<String> get scopes;

  /// Whether [scope] is present in [scopes].
  bool hasScope(String scope);

  /// Fetches (or mints) the current audience-scoped bearer token, or null when
  /// none is available. Async because minting may round-trip to the identity
  /// kernel. Callers must treat the result as short-lived and never persist it.
  Future<String?> token();
}
