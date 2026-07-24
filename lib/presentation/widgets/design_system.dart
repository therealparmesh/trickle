import 'package:flutter/material.dart';

import '../../core/constants.dart';

/// The clipped corner is trickle's primary piece of interface geometry.
///
/// It is intentionally used on controls and interactive surfaces only. Content
/// lists stay on the continuous page canvas so the interface does not become a
/// wall of outlined boxes.
final class CutCornerBorder extends OutlinedBorder {
  const CutCornerBorder({this.cut = 12, super.side = BorderSide.none});

  final double cut;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  ShapeBorder scale(double t) =>
      CutCornerBorder(cut: cut * t, side: side.scale(t));

  @override
  CutCornerBorder copyWith({BorderSide? side, double? cut}) =>
      CutCornerBorder(side: side ?? this.side, cut: cut ?? this.cut);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return _path(rect.deflate(side.width), (cut - side.width).clamp(0, cut));
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect, cut);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawPath(
      _path(rect.deflate(side.width / 2), cut),
      side.toPaint()..style = PaintingStyle.stroke,
    );
  }

  Path _path(Rect rect, double requestedCut) {
    final effectiveCut = requestedCut.clamp(
      0,
      (rect.shortestSide / 2).clamp(0, double.infinity),
    );
    return Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right - effectiveCut, rect.top)
      ..lineTo(rect.right, rect.top + effectiveCut)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left + effectiveCut, rect.bottom)
      ..lineTo(rect.left, rect.bottom - effectiveCut)
      ..close();
  }
}

final class SignalPanel extends StatelessWidget {
  const SignalPanel({
    required this.child,
    this.onTap,
    this.accent,
    this.color = AppConstants.surface,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? accent;
  final Color color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      children: [
        Padding(padding: padding, child: child),
        if (accent case final value?)
          Positioned(
            left: 0,
            top: 12,
            bottom: 12,
            child: IgnorePointer(
              child: ColoredBox(color: value, child: const SizedBox(width: 3)),
            ),
          ),
      ],
    );
    return Material(
      color: color,
      shape: const CutCornerBorder(cut: 14),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );
  }
}

final class SignalIcon extends StatelessWidget {
  const SignalIcon({
    required this.icon,
    this.color = AppConstants.cyan,
    this.size = 46,
    super.key,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Material(
        color: color.withValues(alpha: 0.12),
        shape: CutCornerBorder(cut: size * 0.2),
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, color: color, size: size * 0.48),
        ),
      ),
    );
  }
}

final class SignalMediaFrame extends StatelessWidget {
  const SignalMediaFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppConstants.surface,
      shape: const CutCornerBorder(cut: 16),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Padding(padding: const EdgeInsets.all(6), child: child),
          const Positioned(
            top: 0,
            right: 16,
            child: ColoredBox(
              color: AppConstants.cyan,
              child: SizedBox(width: 34, height: 3),
            ),
          ),
          const Positioned(
            left: 0,
            bottom: 16,
            child: ColoredBox(
              color: AppConstants.magenta,
              child: SizedBox(width: 3, height: 24),
            ),
          ),
        ],
      ),
    );
  }
}

final class SignalBackdropPainter extends CustomPainter {
  const SignalBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final cyan = Paint()
      ..color = AppConstants.cyan.withValues(alpha: 0.038)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final magenta = Paint()
      ..color = AppConstants.magenta.withValues(alpha: 0.026)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final width = size.width;
    canvas.drawPath(
      Path()
        ..moveTo(width * 0.46, 0)
        ..lineTo(width * 0.63, 38)
        ..lineTo(width, 38),
      cyan,
    );
    canvas.drawPath(
      Path()
        ..moveTo(width * 0.72, 0)
        ..lineTo(width * 0.84, 76)
        ..lineTo(width, 76),
      magenta,
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, 152)
        ..lineTo(width * 0.16, 152)
        ..lineTo(width * 0.24, 112),
      cyan,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
