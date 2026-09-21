import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../data/database/app_database.dart';
import '../episode_actions.dart';
import '../playback_presentation.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import '../widgets/design_system.dart';
import '../widgets/episode_playback_button.dart';
import '../widgets/add_feed_dialog.dart';

final class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodes = ref.watch(recentEpisodesProvider);
    final articles = ref.watch(recentArticlesProvider);
    final newEpisodeCount = ref.watch(newEpisodeCountProvider).value;
    final unreadFeedItemCount = ref.watch(unreadArticleCountProvider).value;
    return Scaffold(
      body: AppBackdrop(
        child: RefreshIndicator(
          onRefresh: () => refreshAllFeeds(context, ref),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _HomeToolbar()),
              SliverToBoxAdapter(
                child: _SeeAll(
                  label: 'See all episodes',
                  onPressed: () => context.push('/podcasts'),
                ),
              ),
              episodes.when(
                data: (items) => items.isEmpty
                    ? SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.md,
                            AppSpacing.lg,
                            AppSpacing.xs,
                          ),
                          child: AppCard(
                            onTap: () => context.push('/podcast-search'),
                            child: const Row(
                              children: [
                                Icon(
                                  Icons.add_circle_outline_rounded,
                                  color: AppConstants.cyan,
                                ),
                                SizedBox(width: AppSpacing.md),
                                Expanded(
                                  child: Text(
                                    'Find a podcast to start listening',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                          ),
                        ),
                      )
                    : SliverToBoxAdapter(child: _RecentStrip(episodes: items)),
                loading: () => const SliverToBoxAdapter(
                  child: SizedBox(height: 176, child: LoadingView()),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: ErrorView(
                    friendlyError(error),
                    onRetry: () => ref.invalidate(recentEpisodesProvider),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SectionHeader('Library')),
              SliverToBoxAdapter(
                child: LibraryShortcutGrid(
                  children: [
                    LibraryShortcut(
                      icon: Icons.podcasts_rounded,
                      label: 'Podcasts',
                      badge: newEpisodeCount,
                      onTap: () => context.push('/podcasts?tab=podcasts'),
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
                      icon: Icons.add_circle_outline_rounded,
                      label: 'Add podcast',
                      onTap: () => context.push('/podcast-search'),
                    ),
                    LibraryShortcut(
                      icon: Icons.add_link_rounded,
                      label: 'Add podcast URL',
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => const AddFeedDialog.podcast(),
                      ),
                    ),
                    LibraryShortcut(
                      icon: Icons.dynamic_feed_outlined,
                      label: 'Feeds',
                      badge: unreadFeedItemCount,
                      color: AppConstants.magenta,
                      onTap: () => context.push('/reader?tab=feeds'),
                    ),
                    LibraryShortcut(
                      icon: Icons.bookmark_outline_rounded,
                      label: 'Saved articles',
                      color: AppConstants.magenta,
                      onTap: () => context.push('/saved?tab=articles'),
                    ),
                    LibraryShortcut(
                      icon: Icons.add_link_rounded,
                      label: 'Add feed',
                      color: AppConstants.magenta,
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => const AddFeedDialog(),
                      ),
                    ),
                    LibraryShortcut(
                      icon: Icons.video_call_outlined,
                      label: 'Add YouTube feed',
                      color: AppConstants.magenta,
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => const AddFeedDialog.youtube(),
                      ),
                    ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: _SeeAll(
                  label: 'See all feed items',
                  onPressed: () => context.push('/reader?filter=all'),
                ),
              ),
              articles.when(
                data: (items) => items.isEmpty
                    ? const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.xs,
                            AppSpacing.lg,
                            AppSpacing.sm,
                          ),
                          child: Text(
                            'No feed items yet.',
                            style: TextStyle(color: AppConstants.secondaryText),
                          ),
                        ),
                      )
                    : SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) =>
                            ArticleTile(items[index]),
                      ),
                loading: () => const SliverToBoxAdapter(
                  child: SizedBox(height: 100, child: LoadingView()),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: ErrorView(
                    friendlyError(error),
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
          AppSpacing.sm,
        ),
        child: SizedBox(
          height: 50,
          child: Row(
            children: [
              const ExcludeSemantics(child: TrickleMark(size: 34)),
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
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.2);
    final rowHeight = math.max(80.0, 48 * textScale + AppSpacing.xl);
    return SizedBox(
      height: rowHeight * 2 + AppSpacing.xl,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        scrollDirection: Axis.horizontal,
        itemCount: episodes.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: textScale > 1.5 ? 352 : 304,
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
        ),
        itemBuilder: (context, index) => _RecentEpisodeCard(episodes[index]),
      ),
    );
  }
}

final class _RecentEpisodeCard extends ConsumerWidget {
  const _RecentEpisodeCard(this.episode);

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
      if (feed?.title.isNotEmpty == true) feed!.title,
      relativeDate(episode.publishedAt),
      compactDuration(episode.durationMs),
    ]);
    return SignalPanel(
      accent: isCurrent
          ? AppConstants.acid
          : listeningState == EpisodeListeningState.played
          ? null
          : listeningState.color,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                excludeSemantics: true,
                onTap: () => context.push('/episode/${episode.id}'),
                onLongPress: () => _showActions(context, ref),
                label:
                    'Open episode ${episode.title}${episode.explicit ? ', explicit' : ''}. $status${metadata.isEmpty ? '' : '. $metadata'}',
                hint: 'Long press for playback options',
                child: InkWell(
                  onTap: () => context.push('/episode/${episode.id}'),
                  onLongPress: () => _showActions(context, ref),
                  child: Row(
                    children: [
                      EpisodeArtwork(episode: episode, size: 64, radius: 4),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              status,
                              maxLines: 1,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: isCurrent
                                        ? playbackPhase.color
                                        : listeningState.color,
                                    letterSpacing: 0.5,
                                  ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            EpisodeTitle(
                              title: episode.title,
                              explicit: episode.explicit,
                              maxLines: 2,
                              style: TextStyle(
                                color:
                                    listeningState ==
                                            EpisodeListeningState.played &&
                                        !isCurrent
                                    ? AppConstants.secondaryText
                                    : AppConstants.primaryText,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            EpisodePlaybackButton(episode: episode, progress: progress),
          ],
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<EpisodeAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Play'),
              onTap: () => Navigator.pop(context, EpisodeAction.playNow),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_play_rounded),
              title: const Text('Play next'),
              onTap: () => Navigator.pop(context, EpisodeAction.playNext),
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: const Text('Add to Up next'),
              onTap: () => Navigator.pop(context, EpisodeAction.addToUpNext),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    try {
      await performEpisodeAction(ref, episode, action);
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }
}

final class _SeeAll extends StatelessWidget {
  const _SeeAll({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          label: label,
          button: true,
          excludeSemantics: true,
          onTap: onPressed,
          child: TextButton(onPressed: onPressed, child: const Text('See all')),
        ),
      ),
    );
  }
}
