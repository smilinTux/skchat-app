import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:qr_flutter/qr_flutter.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/guest_group_service.dart";
import "../spaces/space_share.dart";

/// The share message text for an Invite-to-DM link. Mirrors [spaceShareText]:
/// a short human line plus the absolute join URL.
String dmInviteShareText(String url) => "Message me directly: $url";

/// Open the "Invite to DM" sheet (guest-dm C1): mint a link that drops whoever
/// opens it straight into a 1:1 DM with the operator (their own guest identity,
/// renameable), then hand it off via copy / native share / QR.
///
/// Thin UI over [GuestInviteService.createDmInvite]; the guest never needs an
/// account or install (web-first). All server state lives behind that one mint
/// call, gated by the operator token.
Future<void> showInviteToDmSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SovereignColors.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _InviteToDmSheetBody(),
  );
}

class _InviteToDmSheetBody extends ConsumerStatefulWidget {
  const _InviteToDmSheetBody();

  @override
  ConsumerState<_InviteToDmSheetBody> createState() =>
      _InviteToDmSheetBodyState();
}

class _InviteToDmSheetBodyState extends ConsumerState<_InviteToDmSheetBody> {
  final _aliasController = TextEditingController();
  // Single-use is the default per the locked design decision; a reusable link
  // is the operator's standing "my-DM-link".
  bool _singleUse = true;
  bool _loading = false;
  String? _error;
  String? _link;

  @override
  void dispose() {
    _aliasController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = ref.read(guestInviteServiceProvider);
      final res = await svc.createDmInvite(
        singleUse: _singleUse,
        alias: _aliasController.text,
      );
      final joinUrl = (res["join_url"] as String?) ?? "";
      if (joinUrl.isEmpty) {
        setState(() {
          _loading = false;
          _error = "The server did not return an invite link. Try again.";
        });
        return;
      }
      setState(() {
        _loading = false;
        _link = svc.fullLink(joinUrl);
      });
    } on DioException catch (e) {
      setState(() {
        _loading = false;
        _error = _messageForDioError(e);
      });
    } catch (_) {
      setState(() {
        _loading = false;
        _error = "Could not create the invite. Please try again.";
      });
    }
  }

  /// Honest, cause-split errors (mirrors the skworld-app #45 permission pattern):
  /// a missing/rejected operator token is an authorization gap, not an outage;
  /// a disabled guest-links flag is a server config state, not a client bug.
  String _messageForDioError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) {
      return "Inviting to a DM is operator-only. This account can message "
          "agents, but minting guest invites is not available here.";
    }
    if (code == 404 || code == 503) {
      return "Guest links are turned off on the server, so an invite cannot "
          "be created right now.";
    }
    return "Could not reach the server to create the invite. "
        "Check your connection and try again.";
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _grabHandle(),
            _header(),
            const SizedBox(height: 4),
            if (_link != null)
              _ResultView(
                link: _link!,
                onDone: () => Navigator.of(context).maybePop(),
              )
            else
              _form(),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _grabHandle() => Container(
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        alignment: Alignment.center,
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: SovereignColors.textTertiary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _header() => const Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
        child: Row(
          children: [
            Icon(Icons.person_add_alt_1_rounded,
                color: SovereignColors.soulLumina, size: 20),
            SizedBox(width: 8),
            Text(
              "Invite to DM",
              style: TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );

  Widget _form() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Share a link that opens a private 1:1 with you. Whoever joins "
            "gets their own guest name (they can change it), and no account "
            "or install is needed.",
            style: TextStyle(
                color: SovereignColors.textSecondary, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: !_singleUse,
            onChanged: _loading
                ? null
                : (v) => setState(() => _singleUse = !v),
            activeThumbColor: SovereignColors.soulLumina,
            title: const Text(
              "Reusable link",
              style: TextStyle(
                  color: SovereignColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _singleUse
                  ? "Off: a one-time link that expires after the first person joins."
                  : "On: your standing my-DM-link, anyone with it can reach you.",
              style: const TextStyle(
                  color: SovereignColors.textTertiary, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _aliasController,
            enabled: !_loading,
            style: const TextStyle(color: SovereignColors.textPrimary),
            decoration: const InputDecoration(
              labelText: "Private nickname (optional)",
              labelStyle: TextStyle(color: SovereignColors.textSecondary),
              helperText: "Only you see this. Names the contact in your list.",
              helperStyle:
                  TextStyle(color: SovereignColors.textTertiary, fontSize: 11),
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline_rounded,
                    color: SovereignColors.textTertiary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(
                        color: SovereignColors.textSecondary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _loading ? null : _create,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link_rounded),
              label: Text(_loading ? "Creating..." : "Create invite"),
            ),
          ),
        ],
      ),
    );
  }
}

/// The minted-link result: QR + the link + copy / native-share actions. Kept a
/// separate widget so it is trivial to test in isolation with a fake share
/// invoker (see [nativeShareInvokerProvider]).
class _ResultView extends ConsumerWidget {
  const _ResultView({required this.link, required this.onDone});

  final String link;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: link,
              version: QrVersions.auto,
              size: 180,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 14),
          SelectableText(
            link,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: SovereignColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: const Text("Copy link"),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _share(context, ref),
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text("Share via..."),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onDone,
            child: const Text("Done"),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: link));
    messenger.showSnackBar(const SnackBar(content: Text("Link copied")));
  }

  /// Native share via [nativeShareInvokerProvider]. Same cause-split degrade as
  /// space_share_sheet: no share target on the platform -> silent copy; a real
  /// failure -> copy but say so.
  Future<void> _share(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    Future<void> copyWith(String snack) async {
      await Clipboard.setData(ClipboardData(text: link));
      messenger.showSnackBar(SnackBar(content: Text(snack)));
    }

    try {
      await ref.read(nativeShareInvokerProvider)(dmInviteShareText(link));
    } on MissingPluginException {
      await copyWith("Link copied");
    } on UnimplementedError {
      await copyWith("Link copied");
    } catch (_) {
      await copyWith("Share failed, link copied instead");
    }
  }
}
