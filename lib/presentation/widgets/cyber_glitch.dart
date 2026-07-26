import 'package:flutter/material.dart';

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
      child: Transform.scale(
        scale: 0.985 + settled * 0.015,
        child: Transform.translate(
          offset: Offset(offset, 0),
          child: Opacity(opacity: 0.38 + settled * 0.62, child: child),
        ),
      ),
    );
  }
}
