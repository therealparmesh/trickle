import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/youtube_support.dart';
import '../../data/database/app_database.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import 'podcasts_page.dart';

enum _ReaderFilter { unread, all, starred }

enum _AddSourceType { feed, youtube }

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
  bool _markingAllRead = false;

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
        title: const PageTitle('Reader'),
        bottom: AdaptiveTabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Articles'),
            Tab(text: 'Feeds'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Add source',
            onPressed: _showAddSourceSheet,
            icon: const Icon(Icons.add_rounded),
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
                        onPressed: _markingAllRead ? null : _markAllRead,
                        icon: _markingAllRead
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.done_all_rounded),
                        label: Text(
                          _markingAllRead ? 'Marking read…' : 'Mark all read',
                        ),
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
                        _ReaderFilter.all => 'No feed items yet',
                        _ReaderFilter.starred => 'No saved articles or videos',
                      },
                      message: switch (_filter) {
                        _ReaderFilter.unread =>
                          'There are no unread feed items.',
                        _ReaderFilter.all =>
                          'Add a feed to see articles and videos here.',
                        _ReaderFilter.starred =>
                          'Save an article or video to keep it here.',
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
      return AdaptiveDropdownField<_ReaderFilter>(
        label: 'Show',
        initialValue: _filter,
        items: const [
          DropdownMenuItem(value: _ReaderFilter.unread, child: Text('Unread')),
          DropdownMenuItem(value: _ReaderFilter.all, child: Text('All')),
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
                    title: 'No feeds yet',
                    message:
                        'Add a website, RSS feed, YouTube channel, or playlist.',
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
    if (_markingAllRead) return;
    setState(() => _markingAllRead = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark everything read?'),
        content: const Text(
          'Every unread article and unwatched video will leave the Unread view.',
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
    if (!mounted) return;
    if (confirmed != true) {
      setState(() => _markingAllRead = false);
      return;
    }
    try {
      await ref.read(feedRepositoryProvider).markAllArticlesRead();
    } on Object catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _markingAllRead = false);
    }
  }

  Future<void> _showAddSourceSheet() async {
    final type = await showModalBottomSheet<_AddSourceType>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add_link_rounded),
                title: const Text('Add feed'),
                subtitle: const Text('RSS, Atom, JSON Feed, or a website'),
                onTap: () => Navigator.pop(context, _AddSourceType.feed),
              ),
              ListTile(
                leading: const Icon(Icons.video_call_outlined),
                title: const Text('Add YouTube feed'),
                subtitle: const Text('Public channel or playlist'),
                onTap: () => Navigator.pop(context, _AddSourceType.youtube),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || type == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => type == _AddSourceType.youtube
          ? const AddFeedDialog.youtube()
          : const AddFeedDialog(),
    );
  }
}

final class _FeedRow extends StatelessWidget {
  const _FeedRow(this.feed);

  final Feed feed;

  @override
  Widget build(BuildContext context) {
    final youtubeKind = youtubeFeedKind(Uri.tryParse(feed.feedUrl));
    final author = feed.author?.trim();
    final subtitle =
        feed.refreshError ??
        (youtubeKind != null
            ? switch (youtubeKind) {
                YouTubeFeedKind.channel => 'YouTube channel',
                YouTubeFeedKind.playlist => 'YouTube playlist',
              }
            : author?.isNotEmpty == true &&
                  author!.toLowerCase() != feed.title.trim().toLowerCase()
            ? author
            : 'RSS feed');
    return AppCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        onTap: () => context.push('/feed/${feed.id}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: FeedArtwork(
          feed: feed,
          size: 54,
          radius: 12,
          icon: youtubeKind == null
              ? Icons.article_outlined
              : Icons.ondemand_video_rounded,
        ),
        title: Text(
          feed.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          subtitle,
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
