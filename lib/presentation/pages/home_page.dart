import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../data/database/app_database.dart';
import '../playback_presentation.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import '../widgets/design_system.dart';
import '../widgets/episode_playback_button.dart';
import '../widgets/episode_actions_button.dart';
import '../widgets/add_feed_dialog.dart';
import '../widgets/add_feed_sheet.dart';

final class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodes = ref.watch(recentEpisodesProvider);
    final articles = ref.watch(recentArticlesProvider);
    final newEpisodeCount = ref.watch(newEpisodeCountProvider).value;
    final unreadFeedItemCount = ref.watch(unreadArticleCountProvider).value;
    final hasPodcasts =
        ref.watch(podcastFeedsProvider).value?.isNotEmpty == true;
    final hasFeeds = ref.watch(readerFeedsProvider).value?.isNotEmpty == true;
    return Scaffold(
      body: AppBackdrop(
        child: RefreshIndicator(
          onRefresh: () => refreshAllFeeds(context, ref),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _HomeToolbar()),
              if (episodes.value?.isNotEmpty == true)
                SliverToBoxAdapter(
                  child: _SeeAll(
                    label: 'See all episodes',
                    onPressed: () => context.push('/podcasts'),
                  ),
                ),
              episodes.when(
                data: (items) => items.isEmpty
                    ? SliverToBoxAdapter(
                        child: _HomeEmptyCard(
                          message: hasPodcasts
                              ? 'No episodes yet. Check your podcasts for refresh errors.'
                              : 'Find a podcast to start listening',
                          color: AppConstants.cyan,
                          icon: hasPodcasts
                              ? Icons.podcasts_rounded
                              : Icons.add_circle_outline_rounded,
                          onTap: () => context.push(
                            hasPodcasts
                                ? '/podcasts?tab=podcasts'
                                : '/podcast-search',
                          ),
                        ),
                      )
                    : SliverToBoxAdapter(child: _RecentStrip(episodes: items)),
                loading: () => const SliverToBoxAdapter(
                  child: SizedBox(
                    height: 272,
                    child: LoadingView(label: 'Loading episodes'),
                  ),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: ErrorView(
                    friendlyError(error),
                    title: 'Couldn’t load episodes',
                    onRetry: () => ref.invalidate(recentEpisodesProvider),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SectionHeader(
                  'Library',
                  action: 'Add',
                  actionIcon: Icons.add_rounded,
                  actionSemanticLabel: 'Add to library',
                  onAction: () =>
                      showAddFeedSheet(context, includePodcasts: true),
                ),
              ),
              SliverToBoxAdapter(
                child: LibraryShortcutGrid(
                  children: [
                    LibraryShortcut(
                      icon: Icons.podcasts_rounded,
                      label: 'Podcasts',
                      badge: newEpisodeCount,
                      badgeNoun: 'new episode',
                      onTap: () => context.push('/podcasts?tab=podcasts'),
                    ),
                    LibraryShortcut(
                      icon: Icons.dynamic_feed_outlined,
                      label: 'Feeds',
                      badge: unreadFeedItemCount,
                      badgeNoun: 'unread item',
                      color: AppConstants.magenta,
                      onTap: () => context.push('/reader?tab=feeds'),
                    ),
                    LibraryShortcut(
                      icon: Icons.queue_music_rounded,
                      label: 'Up next',
                      onTap: () => context.push('/queue'),
                    ),
                    LibraryShortcut(
                      icon: Icons.arrow_downward_rounded,
                      label: 'Downloads',
                      onTap: () => context.push('/downloads'),
                    ),
                    LibraryShortcut(
                      icon: Icons.bookmark_outline_rounded,
                      label: 'Saved episodes',
                      onTap: () => context.push('/saved'),
                    ),
                    LibraryShortcut(
                      icon: Icons.bookmark_outline_rounded,
                      label: 'Saved articles',
                      color: AppConstants.magenta,
                      onTap: () => context.push('/saved?tab=articles'),
                    ),
                  ],
                ),
              ),
              if (articles.value?.isNotEmpty == true)
                SliverToBoxAdapter(
                  child: _SeeAll(
                    label: 'See all feed items',
                    onPressed: () => context.push('/reader?filter=all'),
                  ),
                ),
              articles.when(
                data: (items) => items.isEmpty
                    ? SliverToBoxAdapter(
                        child: _HomeEmptyCard(
                          message: hasFeeds
                              ? 'No feed items yet. Check your feeds for refresh errors.'
                              : 'Add a feed to start reading',
                          color: AppConstants.magenta,
                          icon: hasFeeds
                              ? Icons.dynamic_feed_outlined
                              : Icons.add_circle_outline_rounded,
                          onTap: () async {
                            if (hasFeeds) {
                              await context.push<void>('/reader?tab=feeds');
                            } else {
                              await showDialog<void>(
                                context: context,
                                builder: (_) => const AddFeedDialog(),
                              );
                            }
                          },
                        ),
                      )
                    : SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) =>
                            ArticleTile(items[index]),
                      ),
                loading: () => const SliverToBoxAdapter(
                  child: SizedBox(
                    height: 100,
                    child: LoadingView(label: 'Loading feed items'),
                  ),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: ErrorView(
                    friendlyError(error),
                    title: 'Couldn’t load feed items',
                    onRetry: () => ref.invalidate(recentArticlesProvider),
                  ),
                ),
              ),
              const SliverPadding(
                padding: EdgeInsets.only(bottom: AppSpacing.xl),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _HomeEmptyCard extends StatelessWidget {
  const _HomeEmptyCard({
    required this.message,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  final String message;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.lg,
      AppSpacing.lg,
      0,
    ),
    child: AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    ),
  );
}

final class _HomeToolbar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          0,
        ),
        child: SizedBox(
          height: AppSizes.control,
          child: Row(
            children: [
              const ExcludeSemantics(child: TrickleMark(size: 32)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 2,
                  child: Text(
                    'trickle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.titleLarge?.copyWith(letterSpacing: 0.5),
                  ),
                ),
              ),
              GlassIconButton(
                icon: Icons.search_rounded,
                tooltip: 'Search',
                onPressed: () => context.push('/search'),
              ),
              const SizedBox(width: AppSpacing.sm),
              GlassIconButton(
                icon: Icons.settings_outlined,
                tooltip: 'Settings',
                onPressed: () => context.push('/settings'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _RecentStrip extends StatelessWidget {
  const _RecentStrip({required this.episodes});

  final List<Episode> episodes;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final largeText = scaler.scale(1) > 1.5;
    final titleHeight = scaler.scale(14) * 1.25 * (largeText ? 4 : 2);
    final sourceHeight = scaler.scale(12) * 1.25 * (largeText ? 2 : 1);
    final metadataHeight = scaler.scale(12) * 1.25 * 2;
    final rowHeight =
        AppSpacing.lg +
        AppSpacing.sm +
        (largeText
            ? math.max(AppSizes.control, sourceHeight) +
                  AppSpacing.sm +
                  titleHeight
            : math.max(
                AppSizes.control,
                titleHeight + AppSpacing.xs + sourceHeight,
              )) +
        math.max(AppSizes.control, metadataHeight);
    final rows = largeText ? 1 : 2;
    return SizedBox(
      height: rowHeight * rows + (rows - 1) * AppSpacing.sm,
      child: LayoutBuilder(
        builder: (context, constraints) => GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          scrollDirection: Axis.horizontal,
          itemCount: episodes.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: rows,
            mainAxisExtent: largeText
                ? math
                      .max(240, constraints.maxWidth - AppSpacing.xxl)
                      .toDouble()
                : 336,
            mainAxisSpacing: AppSpacing.sm,
            crossAxisSpacing: AppSpacing.sm,
          ),
          itemBuilder: (context, index) => _RecentEpisodeCard(
            episodes[index],
            key: ValueKey(episodes[index].id),
          ),
        ),
      ),
    );
  }
}

final class _RecentEpisodeCard extends ConsumerWidget {
  const _RecentEpisodeCard(this.episode, {super.key});

  final Episode episode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackItemUiSnapshotProvider(episode.id));
    final progress = ref.watch(episodeProgressSnapshotProvider(episode.id));
    final listeningState = episodeListeningState(episode, progress);
    final feed = ref.watch(feedSnapshotProvider(episode.feedId));
    final isCurrent = playback.isCurrent;
    final playbackPhase = playbackUiPhaseFor(
      processingState: playback.processingState,
      playing: playback.playing,
    );
    final status = isCurrent ? playbackPhase.label : listeningState.label;
    final metadata = metadataLine([
      status,
      relativeDate(episode.publishedAt),
      compactDuration(episode.durationMs),
    ]);
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    final source = Text(
      feed?.title ?? '',
      maxLines: largeText ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: AppConstants.secondaryText),
    );
    final title = EpisodeTitle(
      title: episode.title,
      explicit: episode.explicit,
      maxLines: largeText ? 4 : 2,
      style: TextStyle(
        color: listeningState == EpisodeListeningState.played && !isCurrent
            ? AppConstants.secondaryText
            : AppConstants.primaryText,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
    );
    return SignalPanel(
      accent: isCurrent
          ? AppConstants.acid
          : listeningState == EpisodeListeningState.played
          ? null
          : listeningState.color,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Semantics(
                button: true,
                excludeSemantics: true,
                onTap: () => context.push('/episode/${episode.id}'),
                label:
                    'Open episode ${episode.title}${episode.explicit ? ', explicit' : ''}. ${feed?.title ?? ''}. $metadata',
                child: InkWell(
                  onTap: () => context.push('/episode/${episode.id}'),
                  child: largeText
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                EpisodeArtwork(
                                  episode: episode,
                                  size: AppSizes.control,
                                  radius: 4,
                                ),
                                const SizedBox(width: AppSpacing.md),
                                Expanded(child: source),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            title,
                          ],
                        )
                      : Row(
                          children: [
                            EpisodeArtwork(
                              episode: episode,
                              size: AppSizes.control,
                              radius: 4,
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  title,
                                  const SizedBox(height: AppSpacing.xs),
                                  source,
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    metadata,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isCurrent
                          ? playbackPhase.color
                          : listeningState.color,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                EpisodePlaybackButton(episode: episode, progress: progress),
                EpisodeActionsButton(
                  key: ValueKey(episode.id),
                  episode: episode,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _SeeAll extends StatelessWidget {
  const _SeeAll({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          label: label,
          button: true,
          excludeSemantics: true,
          onTap: onPressed,
          child: TextButton(onPressed: onPressed, child: Text(label)),
        ),
      ),
    );
  }
}
