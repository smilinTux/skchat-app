import "package:flutter/material.dart";

/// Drives a [ZoomableVideo]'s zoom/pan state and reset gesture.
///
/// Owns the underlying [TransformationController] (so a caller can inspect
/// or drive the transform directly, e.g. in tests) and, once attached to a
/// mounted [ZoomableVideo], can trigger an animated reset back to the
/// identity (fit) transform via [reset].
///
/// [reset] exists so a caller that has ALREADY claimed double-tap for
/// something else on the same gesture surface (see
/// `fullscreen_video_stage.dart`, which claims double-tap to enter/exit
/// fullscreen) can still drive the reset from ITS OWN gesture handler,
/// instead of [ZoomableVideo] installing a second, competing double-tap
/// recognizer. Pass [ZoomableVideo.enableInternalDoubleTapReset] as false in
/// that case.
///
/// A single controller drives at most one mounted [ZoomableVideo] at a
/// time. [reset] is a safe no-op before the widget has built and after it
/// has been unmounted or disposed.
class ZoomableVideoController {
  ZoomableVideoController();

  /// The live transform. Exposed directly so callers (and tests) can read
  /// or seed the current scale/pan without reaching into widget internals.
  final TransformationController transformationController =
      TransformationController();

  ZoomableVideoState? _state;

  void _attach(ZoomableVideoState state) {
    _state = state;
  }

  void _detach(ZoomableVideoState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  /// Animates the zoom/pan back to the identity (fit) transform. No-op if
  /// no [ZoomableVideo] is currently attached.
  void reset() => _state?.resetZoom();

  /// Releases the underlying [TransformationController]. Callers that
  /// construct their own [ZoomableVideoController] own its lifecycle and
  /// must call this exactly like any other Flutter controller (e.g. in
  /// `State.dispose`).
  void dispose() => transformationController.dispose();
}

/// Wraps [child] (a video surface, e.g. a LiveKit `VideoTrackRenderer`) in
/// an [InteractiveViewer] so the viewer can pinch-to-zoom and pan it, on
/// touch (mobile / web) and via scroll or ctrl-scroll on desktop.
/// [ZoomableVideo] does not care what [child] renders; it just supplies the
/// zoom/pan chrome around whatever is given.
///
/// Panning is bounded to the child's own bounds: [InteractiveViewer]'s
/// default zero `boundaryMargin` means the child can be zoomed and dragged
/// around, but never panned so far that empty space would show, i.e. it can
/// never be dragged fully off-screen.
///
/// Double-tap-to-reset is built in by default
/// ([enableInternalDoubleTapReset] true), which is right for a standalone
/// [ZoomableVideo] with nothing else on the same surface wanting
/// double-tap. A caller that already owns double-tap for something else
/// (the Space's fullscreen video stage claims double-tap to enter/exit
/// fullscreen) should pass false and instead drive the reset externally
/// through [controller] (see [ZoomableVideoController.reset]), so there is
/// exactly one double-tap recognizer on the surface, never two competing
/// for the same gesture.
class ZoomableVideo extends StatefulWidget {
  const ZoomableVideo({
    super.key,
    required this.child,
    this.controller,
    this.minScale = 1.0,
    this.maxScale = 5.0,
    this.enableInternalDoubleTapReset = true,
  });

  /// The bare video content, e.g. `VideoTrackRenderer(track)`.
  final Widget child;

  /// Optional external controller. If omitted, [ZoomableVideo] creates and
  /// owns its own (disposed automatically with the widget). Pass one in
  /// when a caller needs to trigger [ZoomableVideoController.reset] itself,
  /// e.g. from its own double-tap handler when
  /// [enableInternalDoubleTapReset] is false.
  final ZoomableVideoController? controller;

  final double minScale;
  final double maxScale;

  /// Whether this widget installs its own double-tap-to-reset gesture.
  /// Set to false when an ancestor already claims double-tap for something
  /// else, to avoid an ambiguous double-tap on the same surface.
  final bool enableInternalDoubleTapReset;

  @override
  State<ZoomableVideo> createState() => ZoomableVideoState();
}

/// Public only so [ZoomableVideoController] can reach it and tests can
/// (if ever needed) drive it directly; always created via [ZoomableVideo].
class ZoomableVideoState extends State<ZoomableVideo>
    with SingleTickerProviderStateMixin {
  late ZoomableVideoController _controller;
  bool _ownsController = false;
  late final AnimationController _animController;
  Animation<Matrix4>? _resetAnimation;

  @override
  void initState() {
    super.initState();
    _bindController();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(_onAnimTick);
  }

  void _bindController() {
    final provided = widget.controller;
    if (provided != null) {
      _controller = provided;
      _ownsController = false;
    } else {
      _controller = ZoomableVideoController();
      _ownsController = true;
    }
    _controller._attach(this);
  }

  @override
  void didUpdateWidget(ZoomableVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller._detach(this);
      if (_ownsController) {
        _controller.dispose();
      }
      _bindController();
    }
  }

  @override
  void dispose() {
    _controller._detach(this);
    if (_ownsController) {
      _controller.dispose();
    }
    _animController.dispose();
    super.dispose();
  }

  void _onAnimTick() {
    final animation = _resetAnimation;
    if (animation != null) {
      _controller.transformationController.value = animation.value;
    }
  }

  /// Animates the current zoom/pan back to the identity (fit) transform.
  void resetZoom() {
    final begin = _controller.transformationController.value;
    if (begin == Matrix4.identity()) return;
    _resetAnimation = Matrix4Tween(begin: begin, end: Matrix4.identity())
        .animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _animController.forward(from: 0).whenComplete(() {
      // Snap exactly to identity: the tween's interpolated end value can
      // carry tiny floating-point drift from the decompose/recompose in
      // Matrix4Tween.lerp, and callers (and tests) compare against the
      // exact identity matrix.
      if (mounted) {
        _controller.transformationController.value = Matrix4.identity();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewer = InteractiveViewer(
      transformationController: _controller.transformationController,
      minScale: widget.minScale,
      maxScale: widget.maxScale,
      panEnabled: true,
      scaleEnabled: true,
      clipBehavior: Clip.hardEdge,
      child: widget.child,
    );

    if (!widget.enableInternalDoubleTapReset) {
      return viewer;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: resetZoom,
      child: viewer,
    );
  }
}
