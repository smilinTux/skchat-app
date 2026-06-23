import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/sovereign_colors.dart';

/// Glass-surface input bar pinned at the bottom of the conversation screen.
/// Left: attachment button. Center: text field. Right: voice/send.
/// On desktop: Enter sends, Shift+Enter inserts newline.
class InputBar extends StatefulWidget {
  const InputBar({
    super.key,
    required this.onSend,
    this.onAttach,
    this.onShareLocation,
    this.onTyping,
    this.soulColor = SovereignColors.soulLumina,
  });

  final void Function(String text) onSend;

  /// Best-effort typing signal. Called with `true` when the user begins
  /// composing (throttled so it fires at most once per active stretch) and
  /// `false` when the field is cleared or a message is sent. Null disables
  /// typing transport entirely.
  final void Function(bool isTyping)? onTyping;

  /// Called when the user taps the attach button and the upload should run.
  /// The conversation screen owns the actual pick→upload→send flow (it has the
  /// recipient + riverpod client).  Null leaves the button disabled.
  final Future<void> Function()? onAttach;

  /// Called when the user picks "Share location" from the +-menu. The
  /// conversation screen owns the geolocation prompt → precise/approx choice
  /// → typed `location` send. Null hides the location entry.
  final Future<void> Function()? onShareLocation;

  final Color soulColor;

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  bool _attaching = false;

  /// True once a typing-start signal has been emitted for the current stretch,
  /// so we don't spam one per keystroke. Reset on clear/send.
  bool _typingActive = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
      // Best-effort typing signal: start once when text appears, stop when it
      // empties. Throttled by the _typingActive latch.
      if (hasText && !_typingActive) {
        _typingActive = true;
        widget.onTyping?.call(true);
      } else if (!hasText && _typingActive) {
        _typingActive = false;
        widget.onTyping?.call(false);
      }
    });
  }

  @override
  void dispose() {
    if (_typingActive) widget.onTyping?.call(false);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    if (_typingActive) {
      _typingActive = false;
      widget.onTyping?.call(false);
    }
    // Dismiss the soft keyboard after sending (was requestFocus, which kept the
    // mobile keyboard up). Closes the keyboard on send per operator request.
    _focusNode.unfocus();
  }

  Future<void> _attach() async {
    final onAttach = widget.onAttach;
    if (onAttach == null || _attaching) return;
    setState(() => _attaching = true);
    try {
      await onAttach();
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
  }

  /// Open the +-menu: attach a file, or share location. With only one option
  /// available we invoke it directly (no needless sheet).
  Future<void> _openPlusMenu() async {
    final hasAttach = widget.onAttach != null;
    final hasLocation = widget.onShareLocation != null;
    if (hasAttach && !hasLocation) return _attach();
    if (hasLocation && !hasAttach) return _shareLocation();

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.attach_file_rounded,
                  color: SovereignColors.textSecondary),
              title: const Text('Attach file',
                  style: TextStyle(color: SovereignColors.textPrimary)),
              onTap: () => Navigator.of(sheetCtx).pop('attach'),
            ),
            ListTile(
              leading: const Icon(Icons.location_on_outlined,
                  color: SovereignColors.textSecondary),
              title: const Text('Share location',
                  style: TextStyle(color: SovereignColors.textPrimary)),
              subtitle: const Text(
                'Approximate by default — you choose precise',
                style: TextStyle(
                    color: SovereignColors.textTertiary, fontSize: 12),
              ),
              onTap: () => Navigator.of(sheetCtx).pop('location'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'attach') {
      await _attach();
    } else if (choice == 'location') {
      await _shareLocation();
    }
  }

  Future<void> _shareLocation() async {
    final onShare = widget.onShareLocation;
    if (onShare == null) return;
    await onShare();
  }

  /// Enter sends on desktop; Shift+Enter inserts a newline.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: const BoxDecoration(
            color: SovereignColors.surfaceGlass,
            border: Border(
              top: BorderSide(
                color: SovereignColors.surfaceGlassBorder,
                width: 1,
              ),
            ),
          ),
          // Bottom inset (home indicator) is handled by SafeArea below — do
          // NOT also add MediaQuery.padding.bottom here or the composer floats
          // up with a gap beneath it ("input too high").
          padding: const EdgeInsets.all(8),
          child: SafeArea(
            top: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // + menu (attach file / share location)
                IconButton(
                  icon: _attaching
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(widget.soulColor),
                          ),
                        )
                      : const Icon(Icons.add_rounded),
                  color: SovereignColors.textSecondary,
                  onPressed: (widget.onAttach == null &&
                              widget.onShareLocation == null) ||
                          _attaching
                      ? null
                      : _openPlusMenu,
                  tooltip: 'Add',
                ),

                // Text field with explicit focus management
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    decoration: BoxDecoration(
                      color: SovereignColors.surfaceRaised,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: SovereignColors.surfaceGlassBorder,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    child: Focus(
                      onKeyEvent: _handleKeyEvent,
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: true,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        style: const TextStyle(
                          fontSize: 15,
                          color: SovereignColors.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Message...',
                          hintStyle: TextStyle(
                            color: SovereignColors.textTertiary,
                            fontSize: 15,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 4),

                // Send / Voice button
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _hasText
                      ? _SendButton(
                          key: const ValueKey('send'),
                          onTap: _submit,
                          soulColor: widget.soulColor,
                        )
                      : _VoiceButton(
                          key: const ValueKey('voice'),
                          soulColor: widget.soulColor,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({super.key, required this.onTap, required this.soulColor});

  final VoidCallback onTap;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: soulColor,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.send_rounded, color: Colors.black, size: 20),
      ),
    );
  }
}

class _VoiceButton extends StatelessWidget {
  const _VoiceButton({super.key, required this.soulColor});

  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // TODO(A5-attach): wire push-to-talk voice notes. Needs an audio-record
      // plugin (e.g. `record`) + an /upload of the captured clip as an
      // attachment, reusing the same uploadFile() path as files. Left as a
      // visual placeholder for now (no recorder dependency in pubspec yet).
      onLongPress: () {},
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: soulColor.withValues(alpha: 0.15),
          shape: BoxShape.circle,
          border: Border.all(color: soulColor.withValues(alpha: 0.3)),
        ),
        child: Icon(Icons.mic_rounded, color: soulColor, size: 20),
      ),
    );
  }
}
