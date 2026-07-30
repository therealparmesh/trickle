import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:animated_glitch/animated_glitch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/constants.dart';

/// A brief, non-interactive signal effect for route navigation.
///
/// The live route stays mounted beneath a temporary glitched snapshot, so the
/// effect cannot reset page state, duplicate work, or intercept input.
final class NavigationGlitch extends StatefulWidget {
  const NavigationGlitch({required this.child, this.routeObserver, super.key});

  static const duration = Duration(milliseconds: 280);

  final Widget child;
  final RouteObserver<ModalRoute<dynamic>>? routeObserver;

  @override
  State<NavigationGlitch> createState() => _NavigationGlitchState();
}

class _NavigationGlitchState extends State<NavigationGlitch> with RouteAware {
  static const _maxCapturePixelRatio = 1.25;

  final _captureBoundaryKey = GlobalKey();
  late final _glitchController = AnimatedGlitchController(
    autoStart: false,
    frequency: const Duration(milliseconds: 120),
    chance: 100,
    level: 1.2,
    colorChannelShift: const ColorChannelShift(
      colors: [AppConstants.cyan, AppConstants.magenta, AppConstants.acid],
      delay: Duration(milliseconds: 18),
      spread: 8,
    ),
    distortionShift: const DistortionShift(
      count: 3,
      delay: Duration(milliseconds: 18),
      hideDelay: Duration(milliseconds: 55),
    ),
  );
  Timer? _timer;
  ui.Image? _snapshot;
  bool _started = false;
  int _captureGeneration = 0;
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeToRoute();
    if (MediaQuery.disableAnimationsOf(context)) {
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

  void _scheduleEffect() {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    _cancelEffect(rebuild: true);
    final generation = ++_captureGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_captureRoute(generation));
    });
  }

  Future<void> _captureRoute(int generation) async {
    if (!mounted || generation != _captureGeneration) return;
    final renderObject = _captureBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return;

    ui.Image image;
    try {
      image = await renderObject.toImage(
        pixelRatio: math.min(
          MediaQuery.devicePixelRatioOf(context),
          _maxCapturePixelRatio,
        ),
      );
    } on Object {
      return;
    }

    if (!mounted || generation != _captureGeneration) {
      image.dispose();
      return;
    }
    setState(() => _snapshot = image);
    _glitchController.start();
    _timer = Timer(NavigationGlitch.duration, _finishEffect);
  }

  void _finishEffect() {
    if (!mounted) return;
    _timer = null;
    _glitchController.reset();
    final image = _snapshot;
    setState(() => _snapshot = null);
    if (image != null) _disposeAfterFrame(image);
  }

  void _cancelEffect({bool rebuild = false}) {
    _captureGeneration++;
    _timer?.cancel();
    _timer = null;
    _glitchController.reset();
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
    widget.routeObserver?.unsubscribe(this);
    _timer?.cancel();
    _glitchController.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _captureBoundaryKey, child: widget.child),
        if (snapshot != null)
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: AnimatedGlitch(
                  controller: _glitchController,
                  child: RawImage(
                    image: snapshot,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.low,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
