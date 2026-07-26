import 'package:flutter/material.dart';

import '../../core/constants.dart';

/// A deliberately small, removable motion layer for trickle's signal effects.
///
/// Set [enabled] to false to disable every effect. Removing this file only
/// requires replacing the wrappers in `router.dart` and `main.dart`.
abstract final class CyberGlitchMotion {
  static const enabled = true;
  static const routeDuration = Duration(milliseconds: 300);
  static const reverseRouteDuration = Duration(milliseconds: 180);
  static const revealDuration = Duration(milliseconds: 360);

  static bool isEnabled(BuildContext context) =>
      enabled && !MediaQuery.disableAnimationsOf(context);

  static Widget routeTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> _,
    Widget child,
  ) {
    if (!isEnabled(context)) return child;
    if (animation.status == AnimationStatus.reverse) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeIn),
        child: child,
      );
    }
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (context, child) =>
          _GlitchFrame(progress: animation.value, child: child!),
    );
  }
}

/// Plays one signal-lock reveal when inserted into the tree.
final class CyberGlitchReveal extends StatelessWidget {
  const CyberGlitchReveal({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!CyberGlitchMotion.isEnabled(context)) return child;
    return TweenAnimationBuilder<double>(
      duration: CyberGlitchMotion.revealDuration,
      tween: Tween(begin: 0, end: 1),
      child: RepaintBoundary(child: child),
      builder: (context, progress, child) =>
          _GlitchFrame(progress: progress, child: child!),
    );
  }
}

final class _GlitchFrame extends StatelessWidget {
  const _GlitchFrame({required this.progress, required this.child});

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0);
    final settled = Curves.easeOutCubic.transform(value);
    final intensity = (1 - value / 0.84).clamp(0.0, 1.0);
    final phase = (value * 6).floor().clamp(0, 5);
    final offset = intensity == 0
        ? 0.0
        : switch (phase) {
            0 => -16.0,
            1 => 11.0,
            2 => -8.0,
            3 => 5.0,
            4 => -2.0,
            _ => 0.0,
          };

    return ClipRect(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Transform.scale(
            scale: 0.985 + settled * 0.015,
            child: Transform.translate(
              offset: Offset(offset, 0),
              child: Opacity(opacity: 0.38 + settled * 0.62, child: child),
            ),
          ),
          if (intensity > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: CustomPaint(
                    painter: _SignalNoisePainter(
                      intensity: intensity,
                      phase: phase,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _SignalNoisePainter extends CustomPainter {
  const _SignalNoisePainter({required this.intensity, required this.phase});

  final double intensity;
  final int phase;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || intensity <= 0) return;
    final cyan = Paint()
      ..color = AppConstants.cyan.withValues(alpha: 0.34 * intensity);
    final magenta = Paint()
      ..color = AppConstants.magenta.withValues(alpha: 0.28 * intensity);
    final firstY = size.height * (0.18 + phase * 0.09);
    final secondY = size.height * (0.74 - phase * 0.07);
    final sweepY = size.height * (1 - intensity);
    canvas
      ..drawRect(Rect.fromLTWH(0, firstY, size.width, 4), cyan)
      ..drawRect(
        Rect.fromLTWH(size.width * 0.08, secondY, size.width * 0.84, 6),
        magenta,
      )
      ..drawRect(Rect.fromLTWH(0, sweepY, size.width, 2), cyan)
      ..drawRect(
        Rect.fromLTWH(size.width * 0.72, 0, 2, size.height * intensity),
        cyan,
      );
  }

  @override
  bool shouldRepaint(covariant _SignalNoisePainter oldDelegate) =>
      intensity != oldDelegate.intensity || phase != oldDelegate.phase;
}
