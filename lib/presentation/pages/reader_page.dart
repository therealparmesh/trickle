import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/content_filters.dart';
import '../../core/errors.dart';
import '../../core/feed_category.dart';
import '../../core/youtube_support.dart';
import '../../data/database/app_database.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import '../widgets/content_list_controls.dart';
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
  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  String _category = '';
  ContentSort _sort = ContentSort.newest;

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
    _searchDebounce?.cancel();
    _search.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const PageTitle('Feeds'),
        bottom: AdaptiveTabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Feed items'),
            Tab(text: 'Sources'),
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
    final categories = feedCategoryOptions(
      (ref.watch(readerFeedsProvider).value ?? const <Feed>[]).map(
        (feed) => feed.category,
      ),
    );
    final selectedCategory =
        categories.any(
          (category) => feedCategoryIdentity(category) == _category,
        )
        ? categories.firstWhere(
            (category) => feedCategoryIdentity(category) == _category,
          )
        : null;
    final filter = switch (_filter) {
      _ReaderFilter.unread => ArticleFeedFilter.unread,
      _ReaderFilter.all => ArticleFeedFilter.all,
      _ReaderFilter.starred => ArticleFeedFilter.saved,
    };
    final page = (
      feedId: null,
      category: selectedCategory,
      limit: _limit,
      sort: _sort,
      filter: filter,
      query: _query,
    );
    final articles = ref.watch(filteredArticlesProvider(page));
    final total =
        ref
            .watch(
              filteredArticleCountProvider((
                feedId: null,
                category: selectedCategory,
                filter: filter,
                query: _query,
              )),
            )
            .value ??
        0;
    return RefreshIndicator(
      onRefresh: () => refreshAllFeeds(context, ref),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (categories.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: AdaptiveDropdownField<String>(
                      label: 'Category',
                      initialValue: selectedCategory ?? '',
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('All feeds'),
                        ),
                        for (final category in categories)
                          DropdownMenuItem(
                            value: category,
                            child: Text(category),
                          ),
                      ],
                      onChanged: (value) => setState(() {
                        _category = feedCategoryIdentity(value) ?? '';
                        _limit = _pageSize;
                      }),
                    ),
                  ),
                ContentListControls<_ReaderFilter>(
                  searchController: _search,
                  searchHint: 'Search feed items…',
                  onSearchChanged: _scheduleSearch,
                  filter: _filter,
                  filterOptions: const [
                    AdaptiveFilterOption(_ReaderFilter.unread, 'Unread'),
                    AdaptiveFilterOption(_ReaderFilter.all, 'All'),
                    AdaptiveFilterOption(_ReaderFilter.starred, 'Saved'),
                  ],
                  onFilterChanged: (value) => setState(() {
                    _filter = value;
                    _limit = _pageSize;
                  }),
                  sort: _sort,
                  onSortChanged: (value) => setState(() {
                    _sort = value;
                    _limit = _pageSize;
                  }),
                  accent: AppConstants.magenta,
                ),
                if (_filter == _ReaderFilter.unread && total > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _markingAllRead
                            ? null
                            : () => _markAllRead(selectedCategory),
                        icon: _markingAllRead
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.done_all_rounded),
                        label: Text(
                          _markingAllRead
                              ? 'Marking read…'
                              : selectedCategory == null
                              ? 'Mark all read'
                              : 'Mark category read',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          articles.when(
            data: (items) => items.isEmpty
                ? SliverToBoxAdapter(
                    child: EmptyState(
                      icon: Icons.auto_stories_outlined,
                      title: _query.isNotEmpty
                          ? 'No matching feed items'
                          : switch (_filter) {
                              _ReaderFilter.unread => 'All caught up',
                              _ReaderFilter.all => 'No feed items yet',
                              _ReaderFilter.starred => 'No saved feed items',
                            },
                      message: _query.isNotEmpty
                          ? 'Try another search or filter.'
                          : selectedCategory == null
                          ? switch (_filter) {
                              _ReaderFilter.unread =>
                                'There are no unread feed items.',
                              _ReaderFilter.all =>
                                'Add a feed to see new items here.',
                              _ReaderFilter.starred =>
                                'Save a feed item to keep it here.',
                            }
                          : 'There are no matching items in $selectedCategory.',
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
                onRetry: () => ref.invalidate(filteredArticlesProvider(page)),
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

  Widget _feeds() {
    final feeds = ref.watch(readerFeedsProvider);
    final unreadCounts =
        ref.watch(unreadArticleCountsByFeedProvider).value ?? const {};
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
                        'Add a website, RSS feed, YouTube channel, playlist, or Nostr profile.',
                    action: 'Add feed',
                    onAction: () => showDialog<void>(
                      context: context,
                      builder: (_) => const AddFeedDialog(),
                    ),
                  ),
                ],
              )
            : _FeedList(items, unreadCounts: unreadCounts),
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          friendlyError(error),
          onRetry: () => ref.invalidate(feedsProvider),
        ),
      ),
    );
  }

  void _scheduleSearch(String value) {
    _searchDebounce?.cancel();
    setState(() {});
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (normalized == _query) return;
      setState(() {
        _query = normalized;
        _limit = _pageSize;
      });
    });
  }

  Future<void> _markAllRead(String? category) async {
    if (_markingAllRead) return;
    setState(() => _markingAllRead = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          category == null ? 'Mark everything read?' : 'Mark category read?',
        ),
        content: Text(
          category == null
              ? 'Every unread feed item will leave the Unread view.'
              : 'Every unread item in $category will leave the Unread view.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              category == null ? 'Mark all read' : 'Mark category read',
            ),
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
      await ref
          .read(feedRepositoryProvider)
          .markAllArticlesRead(category: category);
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
                subtitle: const Text(
                  'RSS, Atom, JSON Feed, website, or Nostr profile',
                ),
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

final class _FeedList extends ConsumerStatefulWidget {
  const _FeedList(this.feeds, {required this.unreadCounts});

  final List<Feed> feeds;
  final Map<String, int> unreadCounts;

  @override
  ConsumerState<_FeedList> createState() => _FeedListState();
}

final class _FeedListState extends ConsumerState<_FeedList> {
  String? _renamingCategory;

  @override
  Widget build(BuildContext context) {
    final groups = _feedGroups(widget.feeds);
    final showHeaders = groups.any((group) => group.category != null);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 12)),
        for (final group in groups) ...[
          if (showHeaders)
            SliverToBoxAdapter(
              child: SectionHeader(
                _categoryHeader(group),
                accent: AppConstants.magenta,
                compact: true,
                action: group.category != null && _renamingCategory == null
                    ? 'Rename'
                    : null,
                onAction: group.category != null && _renamingCategory == null
                    ? () => _rename(group.category!)
                    : null,
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverList.builder(
              itemCount: group.feeds.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _FeedRow(
                  group.feeds[index],
                  unreadCount: widget.unreadCounts[group.feeds[index].id] ?? 0,
                ),
              ),
            ),
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
      ],
    );
  }

  String _categoryHeader(_FeedGroup group) {
    final unread = group.feeds.fold<int>(
      0,
      (total, feed) => total + (widget.unreadCounts[feed.id] ?? 0),
    );
    final title = group.category ?? 'Uncategorized';
    return unread == 0 ? title : '$title · $unread unread';
  }

  Future<void> _rename(String currentName) async {
    if (_renamingCategory != null) return;
    final renamed = await showDialog<String>(
      context: context,
      builder: (_) => _RenameCategoryDialog(initialName: currentName),
    );
    if (!mounted || renamed == null || renamed == currentName) return;

    setState(() => _renamingCategory = feedCategoryIdentity(currentName));
    try {
      await ref
          .read(feedRepositoryProvider)
          .renameFeedCategory(currentName, renamed);
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _renamingCategory = null);
    }
  }
}

final class _RenameCategoryDialog extends StatefulWidget {
  const _RenameCategoryDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameCategoryDialog> createState() => _RenameCategoryDialogState();
}

final class _RenameCategoryDialogState extends State<_RenameCategoryDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  bool get _canRename {
    final normalized = normalizeFeedCategory(_controller.text);
    return normalized != null && normalized != widget.initialName;
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename category'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: maxFeedCategoryLength,
      textCapitalization: TextCapitalization.words,
      decoration: const InputDecoration(
        labelText: 'Category name',
        helperText: 'Updates every feed in this category.',
      ),
      onSubmitted: _canRename ? _finish : null,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _canRename ? () => _finish(_controller.text) : null,
        child: const Text('Rename'),
      ),
    ],
  );

  void _onChanged() => setState(() {});

  void _finish(String value) {
    final normalized = normalizeFeedCategory(value);
    if (normalized != null) Navigator.pop(context, normalized);
  }
}

final class _FeedGroup {
  const _FeedGroup(this.category, this.feeds);

  final String? category;
  final List<Feed> feeds;
}

List<_FeedGroup> _feedGroups(List<Feed> feeds) {
  final categorized = <String, _FeedGroup>{};
  final uncategorized = <Feed>[];
  for (final feed in feeds) {
    final category = normalizeFeedCategory(feed.category);
    final identity = feedCategoryIdentity(category);
    if (category == null || identity == null) {
      uncategorized.add(feed);
      continue;
    }
    categorized
        .putIfAbsent(identity, () => _FeedGroup(category, []))
        .feeds
        .add(feed);
  }
  final groups = categorized.values.toList(growable: true)
    ..sort(
      (left, right) =>
          left.category!.toLowerCase().compareTo(right.category!.toLowerCase()),
    );
  if (uncategorized.isNotEmpty) groups.add(_FeedGroup(null, uncategorized));
  return groups;
}

final class _FeedRow extends StatelessWidget {
  const _FeedRow(this.feed, {required this.unreadCount});

  final Feed feed;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    final youtubeKind = youtubeFeedKind(Uri.tryParse(feed.feedUrl));
    final isNostr = feed.protocol == FeedProtocol.nostr.index;
    final author = feed.author?.trim();
    final kindLabel =
        feed.refreshError ??
        (isNostr
            ? 'Nostr profile'
            : youtubeKind != null
            ? switch (youtubeKind) {
                YouTubeFeedKind.channel => 'YouTube channel',
                YouTubeFeedKind.playlist => 'YouTube playlist',
              }
            : author?.isNotEmpty == true &&
                  author!.toLowerCase() != feed.title.trim().toLowerCase()
            ? author
            : 'RSS feed');
    final subtitle = feed.refreshError != null || unreadCount == 0
        ? kindLabel
        : '$unreadCount unread · $kindLabel';
    return AppCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        onTap: () => context.push('/feed/${feed.id}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: FeedArtwork(
          feed: feed,
          size: 54,
          radius: 12,
          icon: isNostr
              ? Icons.person_outline_rounded
              : youtubeKind == null
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
