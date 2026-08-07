import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:qr_flutter/qr_flutter.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/guest_group_service.dart";
import "../../services/skcomms_client.dart";
import "../spaces/space_share.dart";

/// guest-dm G5: share text for a group guest invite.
String guestGroupShareText(String url) => "Join my group chat: $url";

/// Add another guest to an EXISTING guest DM (guest-dm G5, part 1). This is the
/// SECURITY-SENSITIVE promote: adding a guest turns the 1:1 into a group, so a
/// confirm dialog spells that out before anything is minted. On confirm it mints
/// a per-person invite against [groupId] (the server, G1, flips it to gdm in
/// place) and shows the shareable link.
Future<void> showAddGuestToDmSheet(
  BuildContext context, {
  required String groupId,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text("Add another guest?"),
      content: const Text(
        "This 1:1 will become a group. The current guest will see a notice, "
        "and anyone you add now will NOT be able to read earlier messages. "
        "This cannot be undone.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(false),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dctx).pop(true),
          child: const Text("Add guest"),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  return _showMintSheet(context, groupId: groupId, allowSharedLink: false);
}

/// New guest group (guest-dm G5, part 2): name the group, create it, then open
/// the group mint sheet offering per-person invites AND one shared link.
Future<void> showNewGuestGroupFlow(BuildContext context, WidgetRef ref) async {
  final name = await _promptName(context);
  if (name == null || name.trim().isEmpty || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  String? groupId;
  try {
    final res =
        await ref.read(skcommsClientProvider).createGroup(name: name.trim());
    groupId = res.groupId;
  } catch (_) {
    groupId = null;
  }
  if (groupId == null || groupId.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text("Could not create the group.")),
    );
    return;
  }
  if (!context.mounted) return;
  return _showMintSheet(context, groupId: groupId, allowSharedLink: true);
}

Future<String?> _promptName(BuildContext context) => showDialog<String>(
      context: context,
      builder: (dctx) {
        final ctl = TextEditingController();
        return AlertDialog(
          title: const Text("New guest group"),
          content: TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: "Group name",
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(dctx).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(ctl.text),
              child: const Text("Create"),
            ),
          ],
        );
      },
    );

Future<void> _showMintSheet(
  BuildContext context, {
  required String groupId,
  required bool allowSharedLink,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SovereignColors.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _GroupMintBody(groupId: groupId, allowSharedLink: allowSharedLink),
  );
}

class _GroupMintBody extends ConsumerStatefulWidget {
  const _GroupMintBody({required this.groupId, required this.allowSharedLink});
  final String groupId;
  final bool allowSharedLink;

  @override
  ConsumerState<_GroupMintBody> createState() => _GroupMintBodyState();
}

class _GroupMintBodyState extends ConsumerState<_GroupMintBody> {
  final _aliasCtl = TextEditingController();
  final List<String> _links = [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _aliasCtl.dispose();
    super.dispose();
  }

  GuestInviteService get _svc => ref.read(guestInviteServiceProvider);

  String _errorFor(Object e) {
    if (e is DioException) {
      final c = e.response?.statusCode;
      if (c == 401 || c == 403) {
        return "Minting guest invites is operator-only and not available here.";
      }
      if (c == 404 || c == 503) return "Guest links are turned off on the server.";
    }
    return "Could not create the invite. Please try again.";
  }

  Future<void> _mintPerson() => _mint(() async {
        final res = await _svc.createDmInvite(
          groupId: widget.groupId,
          alias: _aliasCtl.text,
        );
        _aliasCtl.clear();
        return res["join_url"] as String?;
      });

  Future<void> _mintShared() => _mint(() async {
        final res = await _svc.createInvite(
          groupId: widget.groupId,
          singleUse: false,
        );
        return res["join_url"] as String?;
      });

  Future<void> _mint(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final joinUrl = await action();
      if (joinUrl == null || joinUrl.isEmpty) {
        setState(() {
          _busy = false;
          _error = "The server did not return a link. Try again.";
        });
        return;
      }
      setState(() {
        _busy = false;
        _links.insert(0, _svc.fullLink(joinUrl));
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = _errorFor(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 4, bottom: 12),
                  decoration: BoxDecoration(
                    color: SovereignColors.textTertiary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text("Invite guests", style: tt.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _aliasCtl,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: "Private alias for the next guest (optional)",
                  helperText: "Only you see this.",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _busy ? null : _mintPerson,
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                label: const Text("Create a per-person invite"),
              ),
              if (widget.allowSharedLink) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _mintShared,
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: const Text("Create one shared link"),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    "Anyone with the shared URL can join (rate-limited).",
                    style: TextStyle(
                        color: SovereignColors.textTertiary, fontSize: 11),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(
                        color: SovereignColors.accentDanger, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              for (final link in _links) _MintedLink(link: link),
            ],
          ),
        ),
      ),
    );
  }
}

/// A minted link row: the link + copy / share / a tap-to-expand QR.
class _MintedLink extends ConsumerWidget {
  const _MintedLink({required this.link});
  final String link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      color: SovereignColors.surfaceRaised,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(link,
                style: const TextStyle(
                    color: SovereignColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: const Text("Copy"),
                ),
                TextButton.icon(
                  onPressed: () => _share(ref),
                  icon: const Icon(Icons.ios_share_rounded, size: 16),
                  label: const Text("Share"),
                ),
                TextButton.icon(
                  onPressed: () => _showQr(context),
                  icon: const Icon(Icons.qr_code_rounded, size: 16),
                  label: const Text("QR"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: link));
    messenger.showSnackBar(const SnackBar(content: Text("Link copied")));
  }

  Future<void> _share(WidgetRef ref) async {
    try {
      await ref.read(nativeShareInvokerProvider)(guestGroupShareText(link));
    } on MissingPluginException {
      await Clipboard.setData(ClipboardData(text: link));
    } on UnimplementedError {
      await Clipboard.setData(ClipboardData(text: link));
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: link));
    }
  }

  void _showQr(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: link, version: QrVersions.auto, size: 200),
          ),
        ),
      ),
    );
  }
}
