import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Carries the root route's visibility across the shell's nested Navigator.
final class NavigationGlitchScope extends InheritedWidget {
  const NavigationGlitchScope({
    required this.route,
    required this.isCurrent,
    required super.child,
    super.key,
  });

  final ModalRoute<dynamic>? route;
  final bool isCurrent;

  @override
  bool updateShouldNotify(NavigationGlitchScope oldWidget) =>
      route != oldWidget.route || isCurrent != oldWidget.isCurrent;
}

/// A brief, non-interactive signal effect for route navigation.
///
/// The live route stays mounted beneath a temporary glitched snapshot, so the
/// effect cannot reset page state, duplicate work, or intercept input.
final class NavigationGlitch extends StatefulWidget {
  const NavigationGlitch({required this.child, this.random, super.key});

  static const duration = Duration(milliseconds: 190);

  final Widget child;
  @visibleForTesting
  final math.Random? random;

  @override
  State<NavigationGlitch> createState() => _NavigationGlitchState();
}

class _NavigationGlitchState extends State<NavigationGlitch>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // The shader intentionally distorts the snapshot, so more resolution only
  // increases transient texture memory without improving the visible effect.
  static const _maxCapturePixelRatio = 1.5;
  static const _shaderAsset = 'packages/animated_glitch/shader/glitch.frag';

  final _captureBoundaryKey = GlobalKey();
  late final _random = widget.random ?? math.Random();
  late final _animation = AnimationController(
    vsync: this,
    duration: NavigationGlitch.duration,
  )..addStatusListener(_handleAnimationStatus);
  ui.Image? _snapshot;
  ui.FragmentShader? _shader;
  bool _visible = false;
  bool _pending = false;
  int _captureGeneration = 0;
  ModalRoute<dynamic>? _route;
  ModalRoute<dynamic>? _shellRoute;

  bool get _canCapture =>
      _visible &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      _isSettled(_route) &&
      _isSettled(_shellRoute);

  bool _isSettled(ModalRoute<dynamic>? route) =>
      route?.isCurrent != false &&
      route?.animation?.isAnimating != true &&
      route?.secondaryAnimation?.isAnimating != true;

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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleCapture();
    } else {
      _cancelEffect(rebuild: true, keepPending: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = context
        .dependOnInheritedWidgetOfExactType<NavigationGlitchScope>();
    final route = ModalRoute.of(context);
    if (_route != route || _shellRoute != shell?.route) {
      _listenToRoutes(add: false);
      _route = route;
      _shellRoute = shell?.route;
      _listenToRoutes(add: true);
    }
    final wasVisible = _visible;
    _visible =
        ModalRoute.isCurrentOf(context) != false && shell?.isCurrent != false;
    if (!_visible || _reduceMotion) {
      _cancelEffect();
      return;
    }
    if (!wasVisible) {
      // Choose once on arrival, not again while waiting for the final frame.
      _pending = _random.nextInt(4) == 0;
    }
    _scheduleCapture();
  }

  void _listenToRoutes({required bool add}) {
    for (final route in [_route, _shellRoute]) {
      for (final animation in [route?.animation, route?.secondaryAnimation]) {
        if (add) {
          animation?.addStatusListener(_handleRouteAnimationStatus);
        } else {
          animation?.removeStatusListener(_handleRouteAnimationStatus);
        }
      }
    }
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    _scheduleCapture();
  }

  void _scheduleCapture() {
    if (!mounted || !_pending || _snapshot != null || !_canCapture) return;
    unawaited(_captureRoute(++_captureGeneration));
  }

  Future<void> _captureRoute(int generation, {bool retry = true}) async {
    if (!mounted || generation != _captureGeneration) return;

    ui.Image? capturedImage;
    try {
      // Shader loading can outlast the first layout. Capture only afterward so
      // the overlay never replays a frame from before the shader was ready.
      final program = _shader == null
          ? await ui.FragmentProgram.fromAsset(_shaderAsset)
          : null;
      WidgetsBinding.instance.ensureVisualUpdate();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _captureGeneration || !_canCapture) {
        return;
      }
      final renderObject = _captureBoundaryKey.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) {
        _pending = false;
        return;
      }
      capturedImage = renderObject.toImageSync(
        pixelRatio: math.min(
          MediaQuery.devicePixelRatioOf(context),
          _maxCapturePixelRatio,
        ),
      );
      if (program != null) _shader ??= program.fragmentShader();
    } on Object {
      capturedImage?.dispose();
      if (!mounted || generation != _captureGeneration) return;
      if (retry) {
        unawaited(_captureRoute(generation, retry: false));
      } else {
        _pending = false;
      }
      return;
    }

    setState(() => _snapshot = capturedImage);
    // Start the clock only after the overlay's first frame has been painted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _captureGeneration) {
        unawaited(_animation.forward(from: 0));
      }
    });
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _finishEffect();
  }

  void _finishEffect() {
    if (!mounted) return;
    _pending = false;
    _animation.reset();
    final image = _snapshot;
    setState(() => _snapshot = null);
    if (image != null) _disposeAfterFrame(image);
  }

  void _cancelEffect({bool rebuild = false, bool keepPending = false}) {
    if (!keepPending) _pending = false;
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
    _listenToRoutes(add: false);
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
