import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'access_client.dart';
import 'access_token_signer.dart';
import 'skos_models.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// skos access-plane (P9) Riverpod wiring.
/// ─────────────────────────────────────────────────────────────────────────

/// The active access-plane client.
///
/// **v1 default = [MockAccessClient]** so the Files browser / corpus search /
/// control panel are demonstrable without a backend or the tailnet.
///
/// ▶ TO GO LIVE: return a [DaemonAccessClient] wired to the app's capauth
///   signer. See the worked example + the single TODO in `access_client.dart`
///   (`DaemonAccessClient.tokenForCall`). Everything downstream is client-
///   agnostic, so this is the single line that flips mock → live:
///
/// ```dart
/// final accessClientProvider = Provider<AccessClient>((ref) {
///   final signer = ref.watch(pgpCapauthSignerProvider);
///   return DaemonAccessClient(
///     tokenForCall: (node, tool, args) =>
///         signer.signAccessEnvelope(node: node, tool: tool, arguments: args),
///   );
/// });
/// ```
final accessClientProvider = Provider<AccessClient>((ref) {
  // LIVE (P9): talk to each node's sk-access `/tool` over the tailnet, with the
  // per-call capauth token minted by the local SKComms daemon (the daemon holds
  // the OpenPGP CapAuth key the gate requires, see [AccessTokenSigner]).
  //
  // Read-only by default: `canWriteOverride` stays false until a write scope is
  // granted to this identity server-side (`python -m skcomms.access.grants`).
  // To demo offline without a daemon, swap this back to `MockAccessClient()`.
  final signer = ref.watch(accessTokenSignerProvider);
  final client = DaemonAccessClient(
    tokenForCall: signer.tokenForCall,
    canWriteOverride: false,
  );
  ref.onDispose(client.dispose);
  return client;
});

/// True when the active client holds a granted write scope. Drives the Files
/// viewer's Save affordance (read-only by default, see P7 security model).
final canWriteProvider = Provider<bool>((ref) {
  return ref.watch(accessClientProvider).canWrite;
});

/// The node the Files browser is currently pointed at (`.158` / `.41`).
final selectedNodeProvider =
    StateProvider<String>((ref) => kDefaultAccessNode);

/// The current directory path within the selected node. Null = show the node's
/// exposed roots (`list_roots`).
final currentPathProvider = StateProvider<String?>((ref) => null);

/// (node, path) key for the directory listing, rebuilds when either changes.
typedef DirKey = ({String node, String? path});

final _dirKeyProvider = Provider<DirKey>((ref) {
  return (
    node: ref.watch(selectedNodeProvider),
    path: ref.watch(currentPathProvider),
  );
});

/// The directory listing for the current (node, path). When path is null it
/// resolves to the node's exposed roots; otherwise `file_list(dir)`.
final dirListingProvider = FutureProvider<List<FsEntry>>((ref) async {
  final client = ref.watch(accessClientProvider);
  final key = ref.watch(_dirKeyProvider);
  // Null OR empty path = the node's roots (an empty breadcrumb segment must not
  // fall through to file_list("") which errors).
  if (key.path == null || key.path!.isEmpty) return client.listRoots(key.node);
  return client.listDir(key.node, key.path!);
});

/// The exposed-root absolute paths for a node (cached), used to clamp "go up a
/// folder" so it never navigates above an allowlisted root.
final rootsProvider = FutureProvider.family<List<String>, String>((ref, node) async {
  final client = ref.watch(accessClientProvider);
  final roots = await client.listRoots(node);
  return roots.map((e) => e.path).toList();
});

/// Navigate up one folder from [current], clamped to [roots]: at an exposed
/// root (or above) it returns null (the roots list); otherwise the parent dir.
String? parentPathWithinRoots(String? current, List<String> roots) {
  if (current == null || current.isEmpty) return null; // already at roots
  if (roots.contains(current)) return null; // at a root → up = roots list
  final i = current.lastIndexOf('/');
  final parent = i > 0 ? current.substring(0, i) : '';
  if (parent.isEmpty) return null;
  final withinRoot =
      roots.any((r) => parent == r || parent.startsWith('$r/'));
  return withinRoot ? parent : null;
}

/// (node, path) of the file currently open in the viewer, or null.
typedef FileRef = ({String node, String path});

final openFileProvider = StateProvider<FileRef?>((ref) => null);

/// The contents of the open file (`file_read`). Errors surface in the viewer.
final fileContentProvider = FutureProvider<String>((ref) async {
  final open = ref.watch(openFileProvider);
  if (open == null) return '';
  return ref.watch(accessClientProvider).readFile(open.node, open.path);
});

/// The current corpus search query (`pg_search`). Empty = no search.
final searchQueryProvider = StateProvider<String>((ref) => '');

/// The corpus search hits for the current query.
final searchResultsProvider = FutureProvider<List<SearchHit>>((ref) async {
  final q = ref.watch(searchQueryProvider).trim();
  if (q.isEmpty) return const <SearchHit>[];
  return ref.watch(accessClientProvider).search(q, k: 15);
});

/// Per-node info (`node_info` + `health`) for the control panel. Family keyed
/// by node label.
final nodeInfoProvider =
    FutureProvider.family<NodeInfo, String>((ref, node) async {
  return ref.watch(accessClientProvider).nodeInfo(node);
});

/// All known nodes (the keys of the node→URL map), for the control panel.
final knownNodesProvider = Provider<List<String>>((ref) {
  return kAccessNodes.keys.toList();
});
