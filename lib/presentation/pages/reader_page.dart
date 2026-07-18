import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/database/app_database.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import 'podcasts_page.dart';

enum _ReaderFilter { unread, all, starred }

final class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({
    this.initialFeeds = false,
    this.initialFilter = 'unread',
    super.key,
  });

  final bool initialFeeds;
  final String initialFilter;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage>
    with SingleTickerProviderStateMixin {
  static const _pageSize = 100;
  late final TabController _tabs;
  late _ReaderFilter _filter;
  int _limit = _pageSize;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialFeeds ? 1 : 0,
    );
    _filter = switch (widget.initialFilter) {
      'all' => _ReaderFilter.all,
      'starred' => _ReaderFilter.starred,
      _ => _ReaderFilter.unread,
    };
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
        title: const Text('Reader'),
        bottom: AdaptiveTabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Articles'),
            Tab(text: 'Feeds'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Add feed',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AddFeedDialog(),
            ),
            icon: const Icon(Icons.add_rounded),
          ),
          IconButton(
            tooltip: 'Search',
            onPressed: () => context.push('/search'),
            icon: const Icon(Icons.search_rounded),
          ),
        ],
      ),
      body: AppBackdrop(
        child: TabBarView(controller: _tabs, children: [_articles(), _feeds()]),
      ),
    );
  }

  Widget _articles() {
    final articles = switch (_filter) {
      _ReaderFilter.unread => ref.watch(readerUnreadArticlesProvider(_limit)),
      _ReaderFilter.all => ref.watch(readerAllArticlesProvider(_limit)),
      _ReaderFilter.starred => ref.watch(starredArticlesPageProvider(_limit)),
    };
    final total = switch (_filter) {
      _ReaderFilter.unread => ref.watch(unreadArticleCountProvider).value ?? 0,
      _ReaderFilter.all => ref.watch(articleCountProvider).value ?? 0,
      _ReaderFilter.starred =>
        ref.watch(starredArticleCountProvider).value ?? 0,
    };
    return RefreshIndicator(
      onRefresh: () => refreshAllFeeds(context, ref),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _filterControl(),
                  if (_filter == _ReaderFilter.unread && total > 0)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _markAllRead,
                        icon: const Icon(Icons.done_all_rounded),
                        label: const Text('Mark all read'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          articles.when(
            data: (items) => items.isEmpty
                ? SliverToBoxAdapter(
                    child: EmptyState(
                      icon: Icons.auto_stories_outlined,
                      title: switch (_filter) {
                        _ReaderFilter.unread => 'All caught up',
                        _ReaderFilter.all => 'No articles yet',
                        _ReaderFilter.starred => 'No saved articles',
                      },
                      message: switch (_filter) {
                        _ReaderFilter.unread => 'There are no unread articles.',
                        _ReaderFilter.all =>
                          'Add a reading feed to see articles here.',
                        _ReaderFilter.starred =>
                          'Save an article to keep it here.',
                      },
                    ),
                  )
                : SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) => ArticleTile(items[index]),
                  ),
            loading: () => const SliverToBoxAdapter(
              child: SizedBox(height: 220, child: LoadingView()),
            ),
            error: (error, _) => SliverToBoxAdapter(
              child: ErrorView(
                friendlyError(error),
                onRetry: _invalidateArticles,
              ),
            ),
          ),
          if (articles.value case final items? when items.length < total)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _limit += _pageSize),
                  icon: const Icon(Icons.expand_more_rounded),
                  label: Text('Load more · ${total - items.length} remaining'),
                ),
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }

  Widget _filterControl() {
    void select(_ReaderFilter value) => setState(() {
      _filter = value;
      _limit = _pageSize;
    });

    if (MediaQuery.textScalerOf(context).scale(1) > 1.8) {
      return AdaptiveDropdownFormField<_ReaderFilter>(
        label: 'Show',
        initialValue: _filter,
        items: const [
          DropdownMenuItem(value: _ReaderFilter.unread, child: Text('Unread')),
          DropdownMenuItem(
            value: _ReaderFilter.all,
            child: Text('All articles'),
          ),
          DropdownMenuItem(value: _ReaderFilter.starred, child: Text('Saved')),
        ],
        onChanged: (value) {
          if (value != null) select(value);
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: SegmentedButton<_ReaderFilter>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _ReaderFilter.unread, label: Text('Unread')),
              ButtonSegment(value: _ReaderFilter.all, label: Text('All')),
              ButtonSegment(value: _ReaderFilter.starred, label: Text('Saved')),
            ],
            selected: {_filter},
            onSelectionChanged: (value) => select(value.first),
          ),
        ),
      ),
    );
  }

  Widget _feeds() {
    final feeds = ref.watch(readerFeedsProvider);
    return RefreshIndicator(
      onRefresh: () => refreshAllFeeds(context, ref),
      child: feeds.when(
        data: (items) => items.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  EmptyState(
                    icon: Icons.rss_feed_rounded,
                    title: 'No reading feeds',
                    message: 'Add a news site, blog, RSS, Atom, or JSON Feed.',
                    action: 'Add feed',
                    onAction: () => showDialog<void>(
                      context: context,
                      builder: (_) => const AddFeedDialog(),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) => _FeedRow(items[index]),
              ),
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          friendlyError(error),
          onRetry: () => ref.invalidate(readerFeedsProvider),
        ),
      ),
    );
  }

  void _invalidateArticles() {
    switch (_filter) {
      case _ReaderFilter.unread:
        ref.invalidate(readerUnreadArticlesProvider(_limit));
      case _ReaderFilter.all:
        ref.invalidate(readerAllArticlesProvider(_limit));
      case _ReaderFilter.starred:
        ref.invalidate(starredArticlesPageProvider(_limit));
    }
  }

  Future<void> _markAllRead() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark all articles read?'),
        content: const Text(
          'Every unread article will move out of the Unread view.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mark all read'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(feedRepositoryProvider).markAllArticlesRead();
    } on Object catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    }
  }
}

final class _FeedRow extends StatelessWidget {
  const _FeedRow(this.feed);

  final Feed feed;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: () => context.push('/feed/${feed.id}'),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: FeedArtwork(
          feed: feed,
          size: 54,
          radius: 12,
          icon: Icons.article_outlined,
        ),
        title: Text(
          feed.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          feed.refreshError ?? feed.author ?? 'RSS subscription',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: feed.refreshError == null
                ? AppConstants.secondaryText
                : AppConstants.danger,
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}
