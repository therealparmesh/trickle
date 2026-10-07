import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/url_identity.dart';
import '../../data/security/private_feed_store.dart';
import 'design_system.dart';

final class ArticleImage extends ConsumerWidget {
  const ArticleImage({
    required this.source,
    required this.allowed,
    this.alt,
    this.declaredWidth,
    this.declaredHeight,
    this.secret,
    super.key,
  });

  final String source;
  final bool allowed;
  final String? alt;
  final double? declaredWidth;
  final double? declaredHeight;
  final PrivateFeedSecret? secret;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!allowed) return const SizedBox.shrink();
    final enabled = ref.watch(remoteImagesProvider).value ?? false;
    final uri = Uri.tryParse(source);
    final headers =
        secret != null && uri != null && sameOrigin(uri, secret!.url)
        ? secret!.headers
        : const <String, String>{};
    final imageState = enabled && uri != null
        ? ref.watch(safeImageFileProvider((url: source, headers: headers)))
        : null;
    if (imageState == null) return const SizedBox.shrink();
    final localPath = imageState.value;
    final image = localPath == null
        ? _placeholder(context, loading: imageState.isLoading, keyed: true)
        : LayoutBuilder(
            builder: (context, constraints) {
              final logicalWidth = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width;
              final pixelWidth =
                  (logicalWidth * MediaQuery.devicePixelRatioOf(context))
                      .round()
                      .clamp(1, 2048)
                      .toInt();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: ClipPath(
                  clipper: ShapeBorderClipper(
                    shape: const CutCornerBorder(cut: AppCuts.small),
                  ),
                  child: Image.file(
                    File(localPath),
                    key: ValueKey('article-image:$source'),
                    cacheWidth: pixelWidth,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        _placeholder(context, loading: false, padded: false),
                  ),
                ),
              );
            },
          );
    if (alt?.isNotEmpty == true) {
      return Semantics(
        image: true,
        label: alt,
        child: ExcludeSemantics(child: image),
      );
    }
    return ExcludeSemantics(child: image);
  }

  Widget _placeholder(
    BuildContext context, {
    required bool loading,
    bool padded = true,
    bool keyed = false,
  }) {
    final placeholder = LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final width = declaredWidth == null
            ? availableWidth
            : math.min(declaredWidth!, availableWidth);
        final aspectRatio = declaredWidth != null && declaredHeight != null
            ? (declaredWidth! / declaredHeight!).clamp(0.2, 5.0)
            : null;
        final rawHeight = aspectRatio == null
            ? math.min(declaredHeight ?? 96, 240).toDouble()
            : width / aspectRatio;
        final height = math.min(rawHeight, 480.0);
        final shortestSide = math.min(width, height);
        Widget status;
        if (shortestSide < 24) {
          status = const SizedBox.shrink();
        } else if (loading) {
          status = SizedBox.square(
            dimension: math.min(22, shortestSide * 0.5),
            child: const CircularProgressIndicator(strokeWidth: 2),
          );
        } else if (shortestSide < 64) {
          status = Icon(
            Icons.broken_image_outlined,
            size: math.min(22, shortestSide * 0.55),
            color: AppConstants.secondaryText,
          );
        } else {
          status = const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                color: AppConstants.secondaryText,
              ),
              SizedBox(height: AppSpacing.xs),
              Text(
                'Image unavailable',
                style: TextStyle(
                  color: AppConstants.secondaryText,
                  fontSize: 12,
                ),
              ),
            ],
          );
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: ClipPath(
            clipper: ShapeBorderClipper(
              shape: const CutCornerBorder(cut: AppCuts.small),
            ),
            child: SizedBox(
              key: keyed ? ValueKey('article-image:$source') : null,
              width: width,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppConstants.elevated,
                  border: Border.all(color: AppConstants.hairline),
                ),
                child: Center(child: status),
              ),
            ),
          ),
        );
      },
    );
    return padded
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: placeholder,
          )
        : placeholder;
  }
}
