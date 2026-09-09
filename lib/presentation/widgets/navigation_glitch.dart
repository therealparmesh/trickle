import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A brief, non-interactive signal effect for route navigation.
///
/// The live route stays mounted beneath a temporary glitched snapshot, so the
/// effect cannot reset page state, duplicate work, or intercept input.
final class NavigationGlitch extends StatefulWidget {
  const NavigationGlitch({required this.child, this.routeObserver, super.key});

  static const duration = Duration(milliseconds: 190);

  final Widget child;
  final RouteObserver<ModalRoute<dynamic>>? routeObserver;

  @override
  State<NavigationGlitch> createState() => _NavigationGlitchState();
}

class _NavigationGlitchState extends State<NavigationGlitch>
    with RouteAware, SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // The shader intentionally distorts the snapshot, so more resolution only
  // increases transient texture memory without improving the visible effect.
  static const _maxCapturePixelRatio = 1.5;
  static final _program = ui.FragmentProgram.fromAsset(
    'packages/animated_glitch/shader/glitch.frag',
  );

  final _captureBoundaryKey = GlobalKey();
  late final _animation = AnimationController(
    vsync: this,
    duration: NavigationGlitch.duration,
  )..addStatusListener(_handleAnimationStatus);
  ui.Image? _snapshot;
  ui.FragmentShader? _shader;
  bool _started = false;
  int _captureGeneration = 0;
  ModalRoute<dynamic>? _route;

  bool get _reduceMotion =>
      MediaQuery.disableAnimationsOf(context) ||
      View.of(context).platformDispatcher.accessibilityFeatures.reduceMotion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (_reduceMotion) _cancelEffect(rebuild: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeToRoute();
    if (_reduceMotion) {
      _started = true;
      _cancelEffect();
      return;
    }
    if (_started) return;
    _started = true;
    _scheduleEffect();
  }

  @override
  void didUpdateWidget(covariant NavigationGlitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routeObserver == widget.routeObserver) return;
    oldWidget.routeObserver?.unsubscribe(this);
    _route = null;
    _subscribeToRoute();
  }

  void _subscribeToRoute() {
    final observer = widget.routeObserver;
    final route = ModalRoute.of(context);
    if (observer == null || route is! ModalRoute<dynamic> || route == _route) {
      return;
    }
    if (_route != null) observer.unsubscribe(this);
    _route = route;
    observer.subscribe(this, route);
  }

  @override
  void didPopNext() {
    _scheduleEffect();
  }

  @override
  void didPushNext() {
    _cancelEffect(rebuild: true);
  }

  void _scheduleEffect() {
    if (!mounted || _reduceMotion) return;
    _cancelEffect(rebuild: true);
    final generation = _captureGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_captureRoute(generation));
    });
  }

  Future<void> _captureRoute(int generation) async {
    if (!mounted || generation != _captureGeneration) return;
    final renderObject = _captureBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return;

    ui.Image? capturedImage;
    try {
      // Shader loading can outlast the first layout. Capture only afterward so
      // the overlay never replays a frame from before the shader was ready.
      final program = await _program;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _captureGeneration) return;
      capturedImage = await renderObject.toImage(
        pixelRatio: math.min(
          MediaQuery.devicePixelRatioOf(context),
          _maxCapturePixelRatio,
        ),
      );
      if (!mounted || generation != _captureGeneration) {
        capturedImage.dispose();
        return;
      }
      _shader ??= program.fragmentShader();
    } on Object {
      capturedImage?.dispose();
      return;
    }

    if (!mounted || generation != _captureGeneration) {
      capturedImage.dispose();
      return;
    }
    setState(() => _snapshot = capturedImage);
    unawaited(_animation.forward(from: 0));
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _finishEffect();
  }

  void _finishEffect() {
    if (!mounted) return;
    _animation.reset();
    final image = _snapshot;
    setState(() => _snapshot = null);
    if (image != null) _disposeAfterFrame(image);
  }

  void _cancelEffect({bool rebuild = false}) {
    _captureGeneration++;
    _animation
      ..stop()
      ..reset();
    final image = _snapshot;
    if (image != null && rebuild && mounted) {
      setState(() => _snapshot = null);
    } else {
      _snapshot = null;
    }
    if (image != null) _disposeAfterFrame(image);
  }

  void _disposeAfterFrame(ui.Image image) {
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  @override
  void dispose() {
    _captureGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    widget.routeObserver?.unsubscribe(this);
    _animation.dispose();
    _shader?.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final shader = _shader;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _captureBoundaryKey, child: widget.child),
        if (snapshot != null && shader != null)
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey('navigation-glitch-overlay'),
                  painter: _GlitchPainter(
                    image: snapshot,
                    shader: shader,
                    animation: _animation,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

final class _GlitchPainter extends CustomPainter {
  _GlitchPainter({
    required this.image,
    required this.shader,
    required this.animation,
  }) : super(repaint: animation);

  static const _distortionLevel = 0.018;
  static const _colorChannelLevel = 0.006;
  static const _glitchChance = 100.0;
  static const _glitchSlices = 4.0;

  final ui.Image image;
  final ui.FragmentShader shader;
  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final elapsedSeconds =
        animation.value *
        NavigationGlitch.duration.inMicroseconds /
        Duration.microsecondsPerSecond;
    shader
      ..setFloat(0, elapsedSeconds)
      ..setFloat(1, size.width)
      ..setFloat(2, size.height)
      ..setFloat(3, _distortionLevel)
      ..setFloat(4, _colorChannelLevel)
      ..setFloat(5, 1)
      ..setFloat(6, _glitchChance)
      ..setFloat(7, 1)
      ..setFloat(8, 1)
      ..setFloat(9, 0)
      ..setFloat(10, 1)
      ..setFloat(11, _glitchSlices)
      ..setImageSampler(0, image, filterQuality: FilterQuality.medium);

    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _GlitchPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.shader != shader;
}
