import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/url_identity.dart';
import '../../data/database/app_database.dart';

void showErrorSnackBar(BuildContext context, Object error) {
  showMessageSnackBar(context, friendlyError(error));
}

void showMessageSnackBar(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<void> refreshAllFeeds(
  BuildContext context,
  WidgetRef ref, {
  bool announceSuccess = false,
  void Function(int completed, int total)? onProgress,
}) async {
  try {
    final result = await ref
        .read(syncCoordinatorProvider)
        .refresh(onProgress: onProgress);
    if (!context.mounted) return;
    if (result.failedFeeds > 0) {
      final count = result.failedFeeds;
      showMessageSnackBar(
        context,
        'Refresh finished with $count failed feed${count == 1 ? '' : 's'}',
      );
    } else if (announceSuccess) {
      showMessageSnackBar(context, 'Feeds refreshed');
    }
  } on Object catch (error) {
    if (context.mounted) showErrorSnackBar(context, error);
  }
}

final class HorizontalShortcutStrip extends StatelessWidget {
  const HorizontalShortcutStrip({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.textScalerOf(context).scale(1) > 1.5) {
      return LayoutBuilder(
        builder: (context, constraints) {
          const horizontalPadding = 10.0;
          final itemWidth = (constraints.maxWidth - horizontalPadding * 2) / 2;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: Wrap(
              runSpacing: 4,
              children: [
                for (final child in children)
                  SizedBox(width: itemWidth, child: child),
              ],
            ),
          );
        },
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: children),
    );
  }
}

final class EpisodeTitle extends StatelessWidget {
  const EpisodeTitle({
    required this.title,
    required this.explicit,
    this.maxLines = 2,
    this.textAlign = TextAlign.start,
    this.style,
    super.key,
  });

  final String title;
  final bool explicit;
  final int? maxLines;
  final TextAlign textAlign;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final textScaler = MediaQuery.textScalerOf(context);
    final lineHeight =
        textScaler.scale(effectiveStyle.fontSize ?? 14) *
        (effectiveStyle.height ?? 1.2);
    final badgeTop = ((lineHeight - 13) / 2).clamp(0.0, double.infinity);
    return Semantics(
      label: explicit ? '$title, explicit' : title,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: textAlign == TextAlign.center
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: Text(
              title,
              maxLines: maxLines,
              overflow: maxLines == null
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              textAlign: textAlign,
              style: style,
            ),
          ),
          if (explicit)
            Padding(
              padding: EdgeInsets.only(left: 5, top: badgeTop),
              child: const _ExplicitBadge(),
            ),
        ],
      ),
    );
  }
}

final class _ExplicitBadge extends StatelessWidget {
  const _ExplicitBadge();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 13,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: AppConstants.secondaryText, width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Center(
          child: MediaQuery.withNoTextScaling(
            child: Text(
              'E',
              textHeightBehavior: const TextHeightBehavior(
                applyHeightToFirstAscent: false,
                applyHeightToLastDescent: false,
              ),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppConstants.secondaryText,
                fontSize: 8,
                height: 1,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class TrickleMark extends StatelessWidget {
  const TrickleMark({this.size = 92, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'trickle',
      child: SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: _TrickleMarkPainter()),
      ),
    );
  }
}

final class _TrickleMarkPainter extends CustomPainter {
  const _TrickleMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1024, size.height / 1024);
    canvas
      ..translate(512, 512)
      ..scale(1.35)
      ..translate(-512, -512);

    final headphoneBand = Paint()
      ..color = AppConstants.magenta
      ..style = PaintingStyle.stroke
      ..strokeWidth = 46
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(286, 570)
        ..cubicTo(286, 380, 386, 278, 512, 278)
        ..cubicTo(638, 278, 738, 380, 738, 570),
      headphoneBand,
    );

    final droplet = Path()
      ..moveTo(512, 168)
      ..cubicTo(512, 168, 310, 410, 310, 582)
      ..cubicTo(310, 720, 400, 818, 512, 818)
      ..cubicTo(624, 818, 714, 720, 714, 582)
      ..cubicTo(714, 410, 512, 168, 512, 168)
      ..close();
    canvas.drawPath(droplet, Paint()..color = AppConstants.surface);
    canvas.drawPath(
      droplet,
      Paint()
        ..color = AppConstants.cyan
        ..style = PaintingStyle.stroke
        ..strokeWidth = 38
        ..strokeJoin = StrokeJoin.round,
    );

    final cupFill = Paint()..color = AppConstants.background;
    final cupStroke = Paint()
      ..color = AppConstants.magenta
      ..style = PaintingStyle.stroke
      ..strokeWidth = 34;
    for (final rect in const [
      Rect.fromLTWH(244, 520, 112, 202),
      Rect.fromLTWH(668, 520, 112, 202),
    ]) {
      final cup = RRect.fromRectAndRadius(rect, const Radius.circular(42));
      canvas.drawRRect(cup, cupFill);
      canvas.drawRRect(cup, cupStroke);
    }

    final cyanDetail = Paint()
      ..color = AppConstants.cyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(326, 570), const Offset(326, 672), cyanDetail);
    canvas.drawLine(const Offset(698, 570), const Offset(698, 672), cyanDetail);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

final class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          color: AppConstants.surface.withValues(alpha: 0.94),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: AppConstants.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 48,
              child: Icon(icon, size: 23, color: AppConstants.primaryText),
            ),
          ),
        ),
      ),
    );
  }
}

final class PlaybackSpeedSelector extends StatelessWidget {
  const PlaybackSpeedSelector({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    if (textScale > 1.5) {
      return LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 6.0;
          final width = (constraints.maxWidth - spacing) / 2;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final value in AppConstants.allowedSpeeds)
                SizedBox(
                  width: width,
                  child: _SpeedCell(
                    value: value,
                    selected: selected == value,
                    onTap: () => onSelected(value),
                  ),
                ),
            ],
          );
        },
      );
    }
    return Row(
      children: [
        for (var index = 0; index < AppConstants.allowedSpeeds.length; index++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: index == AppConstants.allowedSpeeds.length - 1 ? 0 : 6,
              ),
              child: _SpeedCell(
                value: AppConstants.allowedSpeeds[index],
                selected: selected == AppConstants.allowedSpeeds[index],
                onTap: () => onSelected(AppConstants.allowedSpeeds[index]),
              ),
            ),
          ),
      ],
    );
  }
}

final class AdaptiveDropdownField<T> extends StatelessWidget {
  const AdaptiveDropdownField({
    required this.label,
    required this.initialValue,
    required this.items,
    required this.onChanged,
    this.helperText,
    super.key,
  });

  final String label;
  final String? helperText;
  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final separateLabel = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    final field = InputDecorator(
      decoration: InputDecoration(
        labelText: separateLabel ? null : label,
        helperText: separateLabel ? null : helperText,
      ),
      isEmpty: initialValue == null,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: initialValue,
          isDense: true,
          isExpanded: true,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
    if (!separateLabel) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label),
        const SizedBox(height: 8),
        field,
        if (helperText case final helper?) ...[
          const SizedBox(height: 6),
          Text(
            helper,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppConstants.secondaryText),
          ),
        ],
      ],
    );
  }
}

final class _SpeedCell extends StatelessWidget {
  const _SpeedCell({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${speedLabel(value)} playback speed',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected
            ? AppConstants.cyan.withValues(alpha: 0.18)
            : AppConstants.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? AppConstants.cyan : AppConstants.hairline,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Center(
              child: Text(
                speedLabel(value),
                maxLines: 1,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: selected
                      ? AppConstants.cyan
                      : AppConstants.secondaryText,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {this.action, this.onAction, super.key})
    : assert(
        (action == null) == (onAction == null),
        'action and onAction must either both be set or both be null',
      );

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final stackAction =
        action != null && MediaQuery.textScalerOf(context).scale(1) > 1.8;
    final titleWidget = Text(
      title,
      style: Theme.of(context).textTheme.titleLarge,
    );
    final actionWidget = action == null
        ? null
        : TextButton(onPressed: onAction, child: Text(action!));
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 24, 10, 9),
        child: stackAction
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  titleWidget,
                  const SizedBox(height: 4),
                  Align(alignment: Alignment.centerRight, child: actionWidget),
                ],
              )
            : Row(
                children: [
                  Expanded(child: titleWidget),
                  ?actionWidget,
                ],
              ),
      ),
    );
  }
}

final class AdaptiveTabBar extends StatelessWidget
    implements PreferredSizeWidget {
  const AdaptiveTabBar({required this.tabs, this.controller, super.key});

  final List<Widget> tabs;
  final TabController? controller;

  @override
  Size get preferredSize => const Size.fromHeight(kTextTabBarHeight);

  @override
  Widget build(BuildContext context) {
    final scrollable = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    return TabBar(
      controller: controller,
      isScrollable: scrollable,
      tabAlignment: scrollable ? TabAlignment.start : TabAlignment.fill,
      tabs: tabs,
    );
  }
}

final class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppConstants.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

final class LibraryShortcut extends StatelessWidget {
  const LibraryShortcut({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = AppConstants.cyan,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 3.2).toDouble();
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          width: (86 + (textScale - 1) * 63).clamp(86.0, 224.0),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.16),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color.withValues(alpha: 0.16),
                          border: Border.all(
                            color: color.withValues(alpha: 0.6),
                          ),
                        ),
                        child: Icon(icon, color: color, size: 28),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class Artwork extends ConsumerWidget {
  const Artwork({
    this.url,
    this.headers = const {},
    this.size = 56,
    this.aspectRatio = 1,
    this.radius = 9,
    this.icon = Icons.graphic_eq_rounded,
    super.key,
  }) : assert(aspectRatio > 0);

  final String? url;
  final Map<String, String> headers;
  final double size;
  final double aspectRatio;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remoteImages = ref.watch(remoteImagesProvider).value ?? false;
    final normalizedUrl = url?.trim();
    final localPath = remoteImages && normalizedUrl?.isNotEmpty == true
        ? ref
              .watch(
                safeImageFileProvider((url: normalizedUrl!, headers: headers)),
              )
              .value
        : null;
    final height = size / aspectRatio;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final pixelWidth = (size * pixelRatio).round();
    final pixelHeight = (height * pixelRatio).round();
    final decodeSize = pixelWidth > pixelHeight ? pixelWidth : pixelHeight;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: size,
          height: height,
          child: localPath == null
              ? _placeholder()
              : Image(
                  key: ValueKey(localPath),
                  image: ResizeImage(
                    FileImage(File(localPath)),
                    width: decodeSize,
                    height: decodeSize,
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => _placeholder(),
                ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return ColoredBox(
      color: AppConstants.elevated,
      child: Icon(
        icon,
        color: AppConstants.cyan,
        size: (size / aspectRatio.clamp(1, double.infinity)) * 0.4,
      ),
    );
  }
}

final class EpisodeArtwork extends ConsumerWidget {
  const EpisodeArtwork({
    required this.episode,
    this.size = 56,
    this.radius = 9,
    super.key,
  });

  final Episode episode;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(feedProvider(episode.feedId))
        .when(
          data: (feed) {
            if (feed == null) {
              return Artwork(url: null, size: size, radius: radius);
            }
            final episodeUrl = episode.imageUrl?.trim();
            final feedUrl = feed.imageUrl?.trim();
            final url = episodeUrl?.isNotEmpty == true
                ? episodeUrl
                : (feedUrl?.isNotEmpty == true ? feedUrl : null);
            if (!feed.isPrivate || url == null) {
              return Artwork(url: url, size: size, radius: radius);
            }
            return ref
                .watch(privateFeedSecretProvider(feed.id))
                .when(
                  data: (secret) {
                    if (secret == null) {
                      return Artwork(url: null, size: size, radius: radius);
                    }
                    final imageUri = Uri.tryParse(url);
                    final headers =
                        imageUri != null && sameOrigin(imageUri, secret.url)
                        ? secret.headers
                        : const <String, String>{};
                    return Artwork(
                      url: url,
                      headers: headers,
                      size: size,
                      radius: radius,
                    );
                  },
                  loading: () => Artwork(url: null, size: size, radius: radius),
                  error: (_, _) =>
                      Artwork(url: null, size: size, radius: radius),
                );
          },
          loading: () => Artwork(url: null, size: size, radius: radius),
          error: (_, _) => Artwork(url: null, size: size, radius: radius),
        );
  }
}

final class EpisodeArtworkById extends ConsumerWidget {
  const EpisodeArtworkById({
    required this.episodeId,
    this.fallbackUrl,
    this.size = 56,
    this.radius = 9,
    super.key,
  });

  final String episodeId;
  final String? fallbackUrl;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(episodeProvider(episodeId))
        .when(
          data: (episode) => episode == null
              ? Artwork(url: fallbackUrl, size: size, radius: radius)
              : EpisodeArtwork(episode: episode, size: size, radius: radius),
          loading: () => Artwork(url: null, size: size, radius: radius),
          error: (_, _) => Artwork(url: null, size: size, radius: radius),
        );
  }
}

final class ArticleArtwork extends ConsumerWidget {
  const ArticleArtwork({
    required this.article,
    this.size = 56,
    this.aspectRatio = 1,
    this.radius = 9,
    super.key,
  }) : assert(aspectRatio > 0);

  final Article article;
  final double size;
  final double aspectRatio;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remoteImages = ref.watch(remoteImagesProvider).value ?? false;
    final articleUrl = article.imageUrl?.trim();
    final hasArticleUrl = articleUrl?.isNotEmpty == true;
    final preview = remoteImages && !hasArticleUrl
        ? ref.watch(articlePreviewImageProvider(article.id)).value
        : null;
    Widget placeholder() => Artwork(
      url: null,
      size: size,
      aspectRatio: aspectRatio,
      radius: radius,
      icon: Icons.article_outlined,
    );
    return ref
        .watch(feedProvider(article.feedId))
        .when(
          data: (feed) {
            if (feed == null) return placeholder();
            final feedUrl = feed.imageUrl?.trim();
            final url = hasArticleUrl
                ? articleUrl
                : (preview?.trim().isNotEmpty == true
                      ? preview!.trim()
                      : (feedUrl?.isNotEmpty == true ? feedUrl : null));
            if (!feed.isPrivate || url == null) {
              return Artwork(
                url: url,
                size: size,
                aspectRatio: aspectRatio,
                radius: radius,
                icon: Icons.article_outlined,
              );
            }
            return ref
                .watch(privateFeedSecretProvider(feed.id))
                .when(
                  data: (secret) {
                    if (secret == null) return placeholder();
                    final imageUri = Uri.tryParse(url);
                    final headers =
                        imageUri != null && sameOrigin(imageUri, secret.url)
                        ? secret.headers
                        : const <String, String>{};
                    return Artwork(
                      url: url,
                      headers: headers,
                      size: size,
                      aspectRatio: aspectRatio,
                      radius: radius,
                      icon: Icons.article_outlined,
                    );
                  },
                  loading: placeholder,
                  error: (_, _) => placeholder(),
                );
          },
          loading: placeholder,
          error: (_, _) => placeholder(),
        );
  }
}

final class FeedArtwork extends ConsumerWidget {
  const FeedArtwork({
    required this.feed,
    this.size = 56,
    this.radius = 9,
    this.icon = Icons.rss_feed_rounded,
    super.key,
  });

  final Feed feed;
  final double size;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = feed.imageUrl?.trim();
    if (!feed.isPrivate || url?.isNotEmpty != true) {
      return Artwork(url: url, size: size, radius: radius, icon: icon);
    }
    final secret = ref.watch(privateFeedSecretProvider(feed.id));
    return secret.when(
      loading: () => Artwork(size: size, radius: radius, icon: icon),
      error: (_, _) => Artwork(size: size, radius: radius, icon: icon),
      data: (value) {
        final imageUri = Uri.tryParse(url!);
        final headers =
            value != null && imageUri != null && sameOrigin(imageUri, value.url)
            ? value.headers
            : const <String, String>{};
        return Artwork(
          url: url,
          headers: headers,
          size: size,
          radius: radius,
          icon: icon,
        );
      },
    );
  }
}

final class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.onAction,
    this.compact = false,
    this.iconColor = AppConstants.cyan,
    super.key,
  }) : assert(
         (action == null) == (onAction == null),
         'action and onAction must either both be set or both be null',
       );

  final IconData icon;
  final String title;
  final String message;
  final String? action;
  final VoidCallback? onAction;
  final bool compact;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 30,
            vertical: compact ? 20 : 42,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Icon(icon, size: compact ? 31 : 38, color: iconColor),
                ),
                SizedBox(height: compact ? 10 : 15),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppConstants.secondaryText),
                ),
                if (action != null) ...[
                  const SizedBox(height: 18),
                  FilledButton(onPressed: onAction, child: Text(action!)),
                ],
              ],
            ),
          ),
        );
        if (!constraints.hasBoundedHeight) {
          return Center(child: content);
        }
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

final class LoadingView extends StatelessWidget {
  const LoadingView({this.label = 'Loading', super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: ExcludeSemantics(
      child: Center(
        child: SizedBox.square(
          dimension: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    ),
  );
}

final class ErrorView extends StatelessWidget {
  const ErrorView(
    this.message, {
    this.title = 'Couldn’t load',
    this.onRetry,
    super.key,
  });

  final String message;
  final String title;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.warning_amber_rounded,
    iconColor: AppConstants.danger,
    title: title,
    message: message,
    action: onRetry == null ? null : 'Try again',
    onAction: onRetry,
  );
}

final class InlineLoadingView extends StatelessWidget {
  const InlineLoadingView({
    this.label = 'Loading',
    this.padding = const EdgeInsets.symmetric(vertical: 18),
    super.key,
  });

  final String label;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: ExcludeSemantics(
      child: Padding(
        padding: padding,
        child: const LinearProgressIndicator(minHeight: 2),
      ),
    ),
  );
}

final class InlineErrorView extends StatelessWidget {
  const InlineErrorView(
    this.message, {
    required this.title,
    this.onRetry,
    super.key,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: AppConstants.danger,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        message,
                        style: const TextStyle(
                          color: AppConstants.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (onRetry != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class AppBackdrop extends StatelessWidget {
  const AppBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D131B), AppConstants.background],
          stops: [0, 0.3],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth > 840
              ? 840.0
              : constraints.maxWidth;
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              height: constraints.maxHeight,
              child: child,
            ),
          );
        },
      ),
    );
  }
}
