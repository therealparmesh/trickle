import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/database/app_database.dart';
import '../episode_actions.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import '../widgets/episode_playback_button.dart';

final class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodes = ref.watch(recentEpisodesProvider);
    final podcastFeeds = ref.watch(podcastFeedsProvider);
    final articles = ref.watch(readerUnreadArticlesProvider(5));
    final readerFeeds = ref.watch(readerFeedsProvider);
    final queueCount = ref.watch(queueProvider).value?.length ?? 0;
    final downloadCount = ref.watch(completedDownloadCountProvider).value ?? 0;
    final savedAudioCount = ref.watch(starredEpisodeCountProvider).value ?? 0;
    final savedReadCount = ref.watch(starredArticleCountProvider).value ?? 0;
    final unreadCount = ref.watch(unreadArticleCountProvider).value ?? 0;
    return Scaffold(
      body: AppBackdrop(
        child: RefreshIndicator(
          onRefresh: () => ref.read(syncCoordinatorProvider).refresh(),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _HomeToolbar()),
              episodes.when(
                data: (items) => items.isEmpty
                    ? SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
                          child: AppCard(
                            onTap: () => context.push('/search?tab=podcasts'),
                            child: const Row(
                              children: [
                                Icon(
                                  Icons.add_circle_outline_rounded,
                                  color: AppConstants.cyan,
                                ),
                                SizedBox(width: 12),
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
                    : SliverToBoxAdapter(
                        child: _RecentStrip(episodes: items.take(8).toList()),
                      ),
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
              const SliverToBoxAdapter(child: SectionHeader('Listen')),
              SliverToBoxAdapter(
                child: HorizontalShortcutStrip(
                  children: [
                    LibraryShortcut(
                      icon: Icons.queue_music_rounded,
                      label: 'Up Next',
                      badge: queueCount,
                      onTap: () => context.push('/queue'),
                    ),
                    LibraryShortcut(
                      icon: Icons.arrow_downward_rounded,
                      label: 'Downloads',
                      badge: downloadCount,
                      onTap: () => context.push('/downloads'),
                    ),
                    LibraryShortcut(
                      icon: Icons.bookmark_outline_rounded,
                      label: 'Saved',
                      badge: savedAudioCount,
                      onTap: () => context.push('/saved'),
                    ),
                    LibraryShortcut(
                      icon: Icons.grid_view_rounded,
                      label: 'Library',
                      onTap: () => context.push('/library'),
                    ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: SectionHeader(
                  'Podcasts',
                  action: 'See all',
                  onAction: () => context.push('/podcasts'),
                ),
              ),
              podcastFeeds.when(
                data: (items) => items.isEmpty
                    ? const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(18, 4, 18, 10),
                          child: Text(
                            'No podcast subscriptions yet.',
                            style: TextStyle(color: AppConstants.secondaryText),
                          ),
                        ),
                      )
                    : SliverList.builder(
                        itemCount: items.take(5).length,
                        itemBuilder: (context, index) =>
                            PodcastTile(items[index]),
                      ),
                loading: () => const SliverToBoxAdapter(
                  child: SizedBox(height: 120, child: LoadingView()),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: ErrorView(
                    friendlyError(error),
                    onRetry: () => ref.invalidate(podcastFeedsProvider),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SectionHeader('Reading')),
              SliverToBoxAdapter(
                child: HorizontalShortcutStrip(
                  children: [
                    LibraryShortcut(
                      icon: Icons.mark_email_unread_outlined,
                      label: 'Unread',
                      badge: unreadCount,
                      color: AppConstants.magenta,
                      onTap: () => context.push('/reader?filter=unread'),
                    ),
                    LibraryShortcut(
                      icon: Icons.rss_feed_rounded,
                      label: 'Feeds',
                      badge: readerFeeds.value?.length ?? 0,
                      color: AppConstants.magenta,
                      onTap: () => context.push('/reader?tab=feeds'),
                    ),
                    LibraryShortcut(
                      icon: Icons.bookmark_outline_rounded,
                      label: 'Saved',
                      badge: savedReadCount,
                      color: AppConstants.magenta,
                      onTap: () => context.push('/saved?tab=articles'),
                    ),
                    LibraryShortcut(
                      icon: Icons.article_outlined,
                      label: 'Reader',
                      color: AppConstants.magenta,
                      onTap: () => context.push('/reader?filter=all'),
                    ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: SectionHeader(
                  'Unread Articles',
                  action: 'See all',
                  onAction: () => context.push('/reader'),
                ),
              ),
              articles.when(
                data: (items) => items.isEmpty
                    ? const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(18, 4, 18, 10),
                          child: Text(
                            'No unread articles.',
                            style: TextStyle(color: AppConstants.secondaryText),
                          ),
                        ),
                      )
                    : SliverList.builder(
                        itemCount: items.take(5).length,
                        itemBuilder: (context, index) =>
                            ArticleTile(items[index]),
                      ),
                loading: () => const SliverToBoxAdapter(
                  child: SizedBox(height: 100, child: LoadingView()),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: ErrorView(
                    friendlyError(error),
                    onRetry: () =>
                        ref.invalidate(readerUnreadArticlesProvider(5)),
                  ),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
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
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: SizedBox(
          height: 48,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const TrickleMark(size: 34),
              Align(
                alignment: Alignment.centerLeft,
                child: GlassIconButton(
                  icon: Icons.settings_outlined,
                  tooltip: 'Settings',
                  onPressed: () => context.push('/settings'),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: GlassIconButton(
                  icon: Icons.search_rounded,
                  tooltip: 'Search',
                  onPressed: () => context.push('/search'),
                ),
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
    final rowHeight = 78 + (textScale - 1) * 34;
    final rows = textScale >= 2 ? 1 : 2;
    return SizedBox(
      height: rowHeight * rows + 26,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        scrollDirection: Axis.horizontal,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: rows,
          mainAxisExtent: 284,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: episodes.length,
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
    final current = ref.watch(currentMediaProvider).value;
    final playing = ref.watch(playbackStateProvider).value?.playing == true;
    final isCurrent = current?.id == episode.id;
    final status = isCurrent
        ? (playing ? 'playing' : 'paused')
        : (episode.played ? 'played' : 'new');
    return Material(
      color: AppConstants.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              excludeSemantics: true,
              onTap: () => context.push('/episode/${episode.id}'),
              onLongPress: () => _showActions(context, ref),
              label:
                  'Open episode ${episode.title}${episode.explicit ? ', explicit' : ''}. $status',
              hint: 'Long press for more actions',
              child: InkWell(
                onTap: () => context.push('/episode/${episode.id}'),
                onLongPress: () => _showActions(context, ref),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    children: [
                      EpisodeArtwork(episode: episode, size: 58, radius: 9),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            EpisodeTitle(
                              title: episode.title,
                              explicit: episode.explicit,
                              maxLines: 2,
                              style: TextStyle(
                                color: episode.played && !isCurrent
                                    ? AppConstants.secondaryText
                                    : AppConstants.primaryText,
                                fontWeight: FontWeight.w700,
                                height: 1.15,
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
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: EpisodePlaybackButton(episode: episode),
          ),
        ],
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
              title: const Text('Add to Up Next'),
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
