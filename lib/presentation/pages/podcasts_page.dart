import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/content_filters.dart';
import '../../core/errors.dart';
import '../widgets/add_feed_dialog.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';

final class PodcastsPage extends ConsumerStatefulWidget {
  const PodcastsPage({this.initialPodcasts = false, super.key});

  final bool initialPodcasts;

  @override
  ConsumerState<PodcastsPage> createState() => _PodcastsPageState();
}

class _PodcastsPageState extends ConsumerState<PodcastsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  static const _pageSize = 100;
  int _limit = _pageSize;
  PodcastEpisodeFilter _filter = PodcastEpisodeFilter.all;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialPodcasts ? 1 : 0,
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const PageTitle('Podcasts'),
        bottom: AdaptiveTabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Episodes'),
            Tab(text: 'Podcasts'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Add podcast URL',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AddFeedDialog.podcast(),
            ),
            icon: const Icon(Icons.add_link_rounded),
          ),
          IconButton(
            tooltip: 'Add podcast',
            onPressed: () => context.push('/podcast-search'),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: AppBackdrop(
        child: TabBarView(
          controller: _tabs,
          children: [_episodes(), _podcasts()],
        ),
      ),
    );
  }

  Widget _podcasts() {
    final feeds = ref.watch(podcastFeedsProvider);
    return RefreshIndicator(
      onRefresh: () => refreshAllFeeds(context, ref),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverPadding(padding: EdgeInsets.only(top: 8)),
          feeds.when(
            data: (items) => items.isEmpty
                ? SliverToBoxAdapter(
                    child: EmptyState(
                      icon: Icons.podcasts_rounded,
                      title: 'No podcasts',
                      message: 'Find a podcast or add its RSS URL.',
                      action: 'Add podcast',
                      onAction: () => context.push('/podcast-search'),
                    ),
                  )
                : SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) => PodcastTile(items[index]),
                  ),
            loading: () => const SliverToBoxAdapter(
              child: SizedBox(height: 220, child: LoadingView()),
            ),
            error: (error, _) => SliverToBoxAdapter(
              child: ErrorView(
                friendlyError(error),
                onRetry: () => ref.invalidate(feedsProvider),
              ),
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }

  Widget _episodes() {
    final provider = podcastEpisodesProvider((
      filter: _filter,
      limit: _limit + 1,
    ));
    final episodes = ref.watch(provider);
    return RefreshIndicator(
      onRefresh: () => refreshAllFeeds(context, ref),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: AdaptiveFilterControl<PodcastEpisodeFilter>(
                value: _filter,
                options: const [
                  AdaptiveFilterOption(PodcastEpisodeFilter.newEpisodes, 'New'),
                  AdaptiveFilterOption(
                    PodcastEpisodeFilter.inProgress,
                    'In Progress',
                  ),
                  AdaptiveFilterOption(PodcastEpisodeFilter.all, 'All'),
                ],
                onChanged: (value) => setState(() {
                  _filter = value;
                  _limit = _pageSize;
                }),
              ),
            ),
          ),
          episodes.when(
            data: (items) => items.isEmpty
                ? SliverToBoxAdapter(
                    child: EmptyState(
                      icon: Icons.multitrack_audio_rounded,
                      title: switch (_filter) {
                        PodcastEpisodeFilter.newEpisodes => 'No new episodes',
                        PodcastEpisodeFilter.inProgress =>
                          'Nothing in progress',
                        PodcastEpisodeFilter.all => 'No episodes yet',
                      },
                      message: switch (_filter) {
                        PodcastEpisodeFilter.newEpisodes => 'You’re caught up.',
                        PodcastEpisodeFilter.inProgress =>
                          'Start an episode to continue it here.',
                        PodcastEpisodeFilter.all =>
                          'Add a podcast to start listening.',
                      },
                      action: _filter == PodcastEpisodeFilter.all
                          ? 'Add podcast'
                          : null,
                      onAction: _filter == PodcastEpisodeFilter.all
                          ? () => context.push('/podcast-search')
                          : null,
                    ),
                  )
                : SliverList.builder(
                    itemCount: items.length > _limit ? _limit : items.length,
                    itemBuilder: (context, index) => EpisodeTile(items[index]),
                  ),
            loading: () => const SliverToBoxAdapter(
              child: SizedBox(height: 180, child: LoadingView()),
            ),
            error: (error, _) => SliverToBoxAdapter(
              child: ErrorView(
                friendlyError(error),
                onRetry: () => ref.invalidate(provider),
              ),
            ),
          ),
          if ((episodes.value?.length ?? 0) > _limit)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: TextButton.icon(
                  onPressed: () => setState(() => _limit += _pageSize),
                  icon: const Icon(Icons.expand_more_rounded),
                  label: const Text('Load more'),
                ),
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }
}
