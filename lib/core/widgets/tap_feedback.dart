import "package:flutter/material.dart";
import "package:flutter/services.dart";

/// Immediate, local acknowledgement that a tap landed.
///
/// Chef, on a Space control bar: "can you add some feedback when you hit the
/// buttons? just so it flashes or something so you know it received the finger
/// touch, like when I click to accept a speaker, it hangs like 5 secs before
/// it moves them into speaker position so you cant tell if you hit the button
/// or if it registered."
///
/// The two halves of that are separate problems and this widget is only the
/// first one. Anything that reaches across the network cannot answer "did it
/// work" for as long as the round trip takes, but it can always answer "did I
/// hear you", instantly and without waiting for anything. That is what this
/// does: it reacts on tap DOWN, from local state only, so the acknowledgement
/// is never gated on the thing being acknowledged.
///
/// Why not just use [InkWell]: the controls that need this most (the Spaces
/// control bar, the reactions and device controls) are circles drawn with
/// [BoxDecoration] over a dark surface. A Material ripple needs an ancestor
/// [Material] to paint on, clips to a rectangle unless given a matching custom
/// border, and is close to invisible against these colors anyway. A scale
/// press reads clearly on any shape, on any background, and needs no ancestor.
/// Widgets that already sit on a Material and already ripple (ListTile,
/// IconButton, TextButton) do not need wrapping and are deliberately left
/// alone.
class TapFeedback extends StatefulWidget {
  const TapFeedback({
    super.key,
    required this.child,
    required this.onTap,
    this.haptic = true,
    this.pressedScale = 0.92,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;

  /// Null disables the control: no press animation, no haptic, no callback,
  /// so a disabled control cannot claim to have heard a tap it will not act
  /// on.
  final VoidCallback? onTap;

  /// Fire a selection click on press. Left on by default and turned off only
  /// for controls that fire their own, richer haptic (the reaction picker
  /// already does), so a single tap never buzzes twice.
  final bool haptic;

  /// How far the child shrinks while held. 0.92 is deliberately modest: this
  /// has to be legible at a glance on a 56px control without turning a
  /// mis-tap into something that looks like a state change.
  final double pressedScale;

  /// Defaults to opaque so the whole painted area of a control is tappable,
  /// including the transparent middle of a bordered circle, which is where a
  /// thumb actually lands.
  final HitTestBehavior behavior;

  @override
  State<TapFeedback> createState() => _TapFeedbackState();
}

class _TapFeedbackState extends State<TapFeedback> {
  bool _down = false;

  bool get _enabled => widget.onTap != null;

  void _setDown(bool v) {
    if (!_enabled || _down == v) return;
    setState(() => _down = v);
  }

  void _handleTapDown(TapDownDetails _) {
    if (!_enabled) return;
    _setDown(true);
    // On press, not on release. A tap that is later dragged off and cancelled
    // still DID land, and the honest answer to "did you hear me" is yes.
    if (widget.haptic) HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _handleTapDown,
      onTapUp: (_) => _setDown(false),
      onTapCancel: () => _setDown(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        // Fast in, slower out. The press has to feel simultaneous with the
        // finger (anything above ~100ms reads as lag, which is the exact
        // complaint this exists to fix); the release can afford to settle.
        duration: Duration(milliseconds: _down ? 70 : 130),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: _enabled ? (_down ? 0.75 : 1.0) : 0.45,
          duration: const Duration(milliseconds: 90),
          child: widget.child,
        ),
      ),
    );
  }
}
