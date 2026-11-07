import 'package:flutter/material.dart';

import '../../core/constants.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../../core/errors.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import '../widgets/stable_sliver_list.dart';

final class SavedPage extends ConsumerStatefulWidget {
  const SavedPage({this.initialTab = 0, super.key});

  final int initialTab;

  @override
  ConsumerState<SavedPage> createState() => _SavedPageState();
}

final class _SavedPageState extends ConsumerState<SavedPage> {
  static const _pageSize = 100;
  int _episodeLimit = _pageSize;
  int _articleLimit = _pageSize;

  @override
  Widget build(BuildContext context) {
    final episodes = ref.watch(starredEpisodesPageProvider(_episodeLimit));
    final articles = ref.watch(starredArticlesPageProvider(_articleLimit));
    final episodeTotal = ref.watch(starredEpisodeCountProvider).value ?? 0;
    final articleTotal = ref.watch(starredArticleCountProvider).value ?? 0;
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab.clamp(0, 1),
      child: Scaffold(
        appBar: AppBar(
          title: const PageTitle('Saved'),
          bottom: const AdaptiveTabBar(
            tabs: [
              Tab(text: 'Episodes'),
              Tab(text: 'Articles'),
            ],
          ),
        ),
        body: AppBackdrop(
          child: TabBarView(
            children: [
              episodes.when(
                data: (items) => items.isEmpty
                    ? const EmptyState(
                        icon: Icons.bookmark_border_rounded,
                        title: 'No saved episodes',
                        message: 'Save an episode to keep it here.',
                      )
                    : CustomScrollView(
                        slivers: [
                          StableSliverList(
                            items: items,
                            itemId: (item) => item.id,
                            itemBuilder: (_, item) => EpisodeTile(item),
                          ),
                          if (items.length < episodeTotal)
                            SliverToBoxAdapter(
                              child: _loadMore(
                                remaining: episodeTotal - items.length,
                                onPressed: () =>
                                    setState(() => _episodeLimit += _pageSize),
                              ),
                            ),
                        ],
                      ),
                loading: () => const LoadingView(),
                error: (error, _) => ErrorView(
                  friendlyError(error),
                  onRetry: () => ref.invalidate(
                    starredEpisodesPageProvider(_episodeLimit),
                  ),
                ),
              ),
              articles.when(
                data: (items) => items.isEmpty
                    ? const EmptyState(
                        icon: Icons.bookmark_border_rounded,
                        title: 'No saved feed items',
                        message: 'Save a feed item to keep it here.',
                      )
                    : CustomScrollView(
                        slivers: [
                          StableSliverList(
                            items: items,
                            itemId: (item) => item.id,
                            itemBuilder: (_, item) => ArticleTile(item),
                          ),
                          if (items.length < articleTotal)
                            SliverToBoxAdapter(
                              child: _loadMore(
                                remaining: articleTotal - items.length,
                                onPressed: () =>
                                    setState(() => _articleLimit += _pageSize),
                              ),
                            ),
                        ],
                      ),
                loading: () => const LoadingView(),
                error: (error, _) => ErrorView(
                  friendlyError(error),
                  onRetry: () => ref.invalidate(
                    starredArticlesPageProvider(_articleLimit),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loadMore({required int remaining, required VoidCallback onPressed}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xl,
      ),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.expand_more_rounded),
        label: Text('Load more · $remaining remaining'),
      ),
    );
  }
}
