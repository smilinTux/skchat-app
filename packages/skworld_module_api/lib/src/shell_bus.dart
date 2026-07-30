/// A single event on the [ShellBus].
///
/// Events are the module-to-shell and shell-to-module signalling primitive:
/// intentionally small and serializable-shaped (a name plus a string-keyed
/// map) so the same vocabulary survives an eventual out-of-process transport
/// (postmessage-v1, reconciled spec R0.2) without changing the interface.
class ShellEvent {
  const ShellEvent(this.name, {this.data = const {}});

  /// The event name (for example "unreadChanged", "callIncoming").
  final String name;

  /// Optional string-keyed payload. Keep values JSON-friendly.
  final Map<String, Object?> data;

  @override
  String toString() => 'ShellEvent($name, $data)';
}

/// The event and navigation bus a mounted [SkworldModule] uses to talk to the
/// shell: request navigation (including cross-module deep links) and
/// publish/observe [ShellEvent]s.
///
/// ABSTRACT: the shell supplies the concrete bus. In standalone mode a module
/// receives a null [ShellContext] (hence no bus) and falls back to its own
/// router, or is handed a local no-op / in-memory implementation. The bus is
/// deliberately transport-agnostic so the in-process Dart implementation and a
/// future postmessage bridge share one contract.
abstract interface class ShellBus {
  /// Requests the shell navigate to a deep link (for example
  /// "skworld://skchat/thread/abc"). Cross-module links are routed by the
  /// shell to the owning module.
  void navigate(String deeplink);

  /// Publishes an event to the shell and any subscribers.
  void emit(ShellEvent event);

  /// The stream of events visible to this module. Implementations may scope
  /// which events a given module sees.
  Stream<ShellEvent> get events;
}
