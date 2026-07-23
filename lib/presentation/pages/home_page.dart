import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../data/database/app_database.dart';
import '../episode_actions.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import '../widgets/design_system.dart';
import '../widgets/episode_playback_button.dart';
import 'podcasts_page.dart';

final class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodes = ref.watch(recentEpisodesProvider);
    final podcastFeeds = ref.watch(podcastFeedsProvider);
    final articles = ref.watch(readerUnreadArticlesProvider(5));
    final queueCount = ref.watch(queueProvider).value?.length;
    final unreadCount = ref.watch(unreadArticleCountProvider).value;
    return Scaffold(
      body: AppBackdrop(
        child: RefreshIndicator(
          onRefresh: () => refreshAllFeeds(context, ref),
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
              SliverToBoxAdapter(
                child: _CommandDeck(
                  title: 'Listen',
                  commands: [
                    CommandTile(
                      icon: Icons.queue_music_rounded,
                      label: 'Up Next',
                      detail: 'Your play order',
                      badge: queueCount == 0 ? null : queueCount,
                      onTap: () => context.push('/queue'),
                    ),
                    CommandTile(
                      icon: Icons.arrow_downward_rounded,
                      label: 'Downloads',
                      detail: 'Available offline',
                      onTap: () => context.push('/downloads'),
                    ),
                    CommandTile(
                      icon: Icons.bookmark_outline_rounded,
                      label: 'Saved episodes',
                      detail: 'Keep for later',
                      onTap: () => context.push('/saved'),
                    ),
                    CommandTile(
                      icon: Icons.grid_view_rounded,
                      label: 'Library',
                      detail: 'Listening tools',
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
              SliverToBoxAdapter(
                child: _CommandDeck(
                  title: 'Feeds',
                  accent: AppConstants.magenta,
                  commands: [
                    CommandTile(
                      icon: Icons.dynamic_feed_outlined,
                      label: 'Sources',
                      detail: 'Web and video feeds',
                      badge: unreadCount == 0 ? null : unreadCount,
                      color: AppConstants.magenta,
                      onTap: () => context.push('/reader?tab=feeds'),
                    ),
                    CommandTile(
                      icon: Icons.bookmark_outline_rounded,
                      label: 'Saved articles',
                      detail: 'Your reading list',
                      color: AppConstants.magenta,
                      onTap: () => context.push('/saved?tab=articles'),
                    ),
                    CommandTile(
                      icon: Icons.add_link_rounded,
                      label: 'Add feed',
                      detail: 'RSS, Atom, or website',
                      color: AppConstants.magenta,
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => const AddFeedDialog(),
                      ),
                    ),
                    CommandTile(
                      icon: Icons.video_call_outlined,
                      label: 'Add YouTube feed',
                      detail: 'Channel or playlist',
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
                child: SectionHeader(
                  'Unread',
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
                            'No unread feed items.',
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
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 9),
        child: SizedBox(
          height: 50,
          child: Row(
            children: [
              const ExcludeSemantics(child: TrickleMark(size: 34)),
              const SizedBox(width: 10),
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
              const SizedBox(width: 8),
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
    return SizedBox(
      height: 118 + (textScale - 1) * 32,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        scrollDirection: Axis.horizontal,
        itemCount: episodes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 9),
        itemBuilder: (context, index) => SizedBox(
          width: textScale > 1.5 ? 336 : 302,
          child: _RecentEpisodeCard(episodes[index]),
        ),
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
    final feed = ref.watch(feedProvider(episode.feedId)).value;
    final isCurrent = current?.id == episode.id;
    final status = isCurrent
        ? (playing ? 'playing' : 'paused')
        : (episode.played ? 'played' : 'new');
    final detail = [
      if (feed?.title.isNotEmpty == true) feed!.title,
      relativeDate(episode.publishedAt),
      compactDuration(episode.durationMs),
    ].join(' · ');
    return SignalPanel(
      accent: isCurrent
          ? AppConstants.acid
          : episode.played
          ? null
          : AppConstants.magenta,
      padding: EdgeInsets.zero,
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
                  padding: const EdgeInsets.fromLTRB(8, 8, 2, 8),
                  child: Row(
                    children: [
                      EpisodeArtwork(episode: episode, size: 76, radius: 5),
                      const SizedBox(width: 11),
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
                            const SizedBox(height: 5),
                            Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: isCurrent
                                        ? AppConstants.acid
                                        : AppConstants.secondaryText,
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
            padding: const EdgeInsets.only(right: 5),
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

final class _CommandDeck extends StatelessWidget {
  const _CommandDeck({
    required this.title,
    required this.commands,
    this.accent = AppConstants.cyan,
  });

  final String title;
  final List<Widget> commands;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final singleColumn = MediaQuery.textScalerOf(context).scale(1) > 1.55;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
            child: Row(
              children: [
                Container(width: 18, height: 3, color: accent),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final width = singleColumn
                  ? constraints.maxWidth
                  : (constraints.maxWidth - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final command in commands)
                    SizedBox(width: width, child: command),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
