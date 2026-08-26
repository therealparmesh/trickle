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
import '../widgets/feed_category_field.dart';
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
  late int _tabIndex;
  late _ReaderFilter _filter;
  int _limit = _pageSize;
  bool _markingAllRead = false;
  bool _organizingFeeds = false;
  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  String _category = '';
  ContentSort _sort = ContentSort.newest;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialFeeds ? 1 : 0;
    _tabs = TabController(length: 2, vsync: this, initialIndex: _tabIndex)
      ..addListener(_onTabChanged);
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
    _tabs.removeListener(_onTabChanged);
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
          if (_tabIndex == 1)
            IconButton(
              tooltip: 'Organize feeds',
              onPressed: _organizingFeeds ? null : _organizeFeeds,
              icon: _organizingFeeds
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.drive_file_move_outline),
            ),
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
    final readerFeeds = ref.watch(readerFeedsProvider).value ?? const <Feed>[];
    final unreadByFeed =
        ref.watch(unreadArticleCountsByFeedProvider).value ?? const {};
    final categories = feedCategoryOptions(
      readerFeeds.map((feed) => feed.category),
    );
    final unreadByCategory = _categoryUnreadCounts(readerFeeds, unreadByFeed);
    final allUnread = readerFeeds.fold<int>(
      0,
      (total, feed) => total + (unreadByFeed[feed.id] ?? 0),
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
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    child: AdaptiveDropdownField<String>(
                      label: 'Category',
                      initialValue: selectedCategory ?? '',
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(_unreadLabel('All feeds', allUnread)),
                        ),
                        for (final category in categories)
                          DropdownMenuItem(
                            value: category,
                            child: Text(
                              _unreadLabel(
                                category,
                                unreadByCategory[feedCategoryIdentity(
                                      category,
                                    )] ??
                                    0,
                              ),
                            ),
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

  void _onTabChanged() {
    if (_tabs.index == _tabIndex) return;
    setState(() => _tabIndex = _tabs.index);
  }

  Future<void> _organizeFeeds() async {
    if (_organizingFeeds) return;
    final feeds = ref.read(readerFeedsProvider).value ?? const <Feed>[];
    if (feeds.isEmpty) return;
    final move = await showModalBottomSheet<_FeedCategoryMove>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OrganizeFeedsSheet(feeds: feeds),
    );
    if (!mounted || move == null) return;
    setState(() => _organizingFeeds = true);
    try {
      final moved = await ref
          .read(feedRepositoryProvider)
          .updateFeedCategories(move.feedIds, move.category);
      if (!mounted) return;
      final destination = move.category ?? 'Uncategorized';
      showMessageSnackBar(
        context,
        moved == 0
            ? 'Selected feeds are already in $destination'
            : 'Moved $moved ${moved == 1 ? 'feed' : 'feeds'} to $destination',
      );
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _organizingFeeds = false);
    }
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

    final currentIdentity = feedCategoryIdentity(currentName);
    final targetIdentity = feedCategoryIdentity(renamed);
    String? existingTarget;
    if (targetIdentity != currentIdentity) {
      for (final category in feedCategoryOptions(
        widget.feeds.map((feed) => feed.category),
      )) {
        if (feedCategoryIdentity(category) == targetIdentity) {
          existingTarget = category;
          break;
        }
      }
    }
    final sourceCount = widget.feeds
        .where((feed) => feedCategoryIdentity(feed.category) == currentIdentity)
        .length;
    final destination = existingTarget ?? renamed;
    if (existingTarget != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Merge categories?'),
          content: Text(
            '$existingTarget already exists. Move $sourceCount '
            '${sourceCount == 1 ? 'feed' : 'feeds'} from $currentName into it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Merge'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }

    setState(() => _renamingCategory = feedCategoryIdentity(currentName));
    try {
      final changed = await ref
          .read(feedRepositoryProvider)
          .renameFeedCategory(currentName, destination);
      if (mounted && changed > 0) {
        showMessageSnackBar(
          context,
          existingTarget == null
              ? 'Renamed $currentName to $destination'
              : 'Merged $changed ${changed == 1 ? 'feed' : 'feeds'} into $destination',
        );
      }
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

Map<String, int> _categoryUnreadCounts(
  List<Feed> feeds,
  Map<String, int> unreadByFeed,
) {
  final result = <String, int>{};
  for (final feed in feeds) {
    final identity = feedCategoryIdentity(feed.category);
    if (identity == null) continue;
    result.update(
      identity,
      (count) => count + (unreadByFeed[feed.id] ?? 0),
      ifAbsent: () => unreadByFeed[feed.id] ?? 0,
    );
  }
  return result;
}

String _unreadLabel(String label, int unread) =>
    unread == 0 ? label : '$label · $unread unread';

typedef _FeedCategoryMove = ({Set<String> feedIds, String? category});

final class _OrganizeFeedsSheet extends StatefulWidget {
  const _OrganizeFeedsSheet({required this.feeds});

  final List<Feed> feeds;

  @override
  State<_OrganizeFeedsSheet> createState() => _OrganizeFeedsSheetState();
}

final class _OrganizeFeedsSheetState extends State<_OrganizeFeedsSheet> {
  final Set<String> _selected = {};
  final TextEditingController _category = TextEditingController();
  final FocusNode _categoryFocus = FocusNode();

  @override
  void dispose() {
    _category.dispose();
    _categoryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = feedCategoryOptions(
      widget.feeds.map((feed) => feed.category),
    );
    final allSelected = _selected.length == widget.feeds.length;
    return SafeArea(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: FractionallySizedBox(
          heightFactor: 0.9,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Organize feeds',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (allSelected) {
                        _selected.clear();
                      } else {
                        _selected.addAll(widget.feeds.map((feed) => feed.id));
                      }
                    }),
                    child: Text(allSelected ? 'Deselect all' : 'Select all'),
                  ),
                ],
              ),
              Text(
                '${_selected.length} selected',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppConstants.secondaryText,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: widget.feeds.length,
                  itemBuilder: (context, index) {
                    final feed = widget.feeds[index];
                    final selected = _selected.contains(feed.id);
                    return CheckboxListTile(
                      value: selected,
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _selected.add(feed.id);
                        } else {
                          _selected.remove(feed.id);
                        }
                      }),
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: AppConstants.magenta,
                      title: Text(
                        feed.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        normalizeFeedCategory(feed.category) ?? 'Uncategorized',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              FeedCategoryField(
                controller: _category,
                focusNode: _categoryFocus,
                options: options,
                helperText: 'Choose a category or clear it for Uncategorized.',
              ),
              const SizedBox(height: 12),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.pop(context, (
                            feedIds: Set.unmodifiable(_selected),
                            category: normalizeFeedCategory(_category.text),
                          )),
                    child: const Text('Move'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
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
