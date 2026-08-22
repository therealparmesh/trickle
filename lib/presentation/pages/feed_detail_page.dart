import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/content_filters.dart';
import '../../core/errors.dart';
import '../../core/feed_category.dart';
import '../../core/youtube_support.dart';
import '../../data/database/app_database.dart';
import '../../domain/feed_models.dart';
import '../subscription_actions.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';
import '../widgets/content_list_controls.dart';
import '../widgets/design_system.dart';

enum _FeedMenuAction { settings, markAllRead }

/// Detail surface shared by podcast and non-podcast feeds.
final class FeedDetailPage extends ConsumerStatefulWidget {
  const FeedDetailPage({required String this.feedId, super.key})
    : podcast = null;

  const FeedDetailPage.catalog({this.podcast, super.key}) : feedId = null;

  final String? feedId;
  final PodcastSearchResult? podcast;

  @override
  ConsumerState<FeedDetailPage> createState() => _FeedDetailPageState();
}

class _FeedDetailPageState extends ConsumerState<FeedDetailPage> {
  static const _pageSize = 100;
  late String? _feedId = widget.feedId;
  late PodcastSearchResult? _podcast = widget.podcast;
  Future<ParsedFeed>? _catalogPreview;
  ParsedFeed? _catalogPreviewSnapshot;
  Feed? _transitionFeed;
  int _limit = _pageSize;
  bool _subscribing = false;
  bool _unsubscribing = false;
  bool _refreshing = false;
  bool _forcePrivateResubscribe = false;
  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  ContentSort _sort = ContentSort.newest;
  EpisodeFeedFilter _episodeFilter = EpisodeFeedFilter.all;
  ArticleFeedFilter _articleFilter = ArticleFeedFilter.all;

  @override
  void initState() {
    super.initState();
    _catalogPreview = _loadCatalogPreview();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<ParsedFeed>? _loadCatalogPreview() {
    final podcast = _podcast;
    if (_feedId != null || podcast == null) return null;
    return ref
        .read(feedRepositoryProvider)
        .loadPodcastPreview(podcast.feedUrl.toString())
        .then((preview) {
          _catalogPreviewSnapshot = preview;
          return preview;
        });
  }

  @override
  Widget build(BuildContext context) {
    final feedId = _feedId;
    if (feedId == null) {
      return _catalogPodcast(context, subscribedFeed: _transitionFeed);
    }
    final feed = ref.watch(feedProvider(feedId));
    if (feed.isLoading && _transitionFeed != null && _catalogPreview != null) {
      return _catalogPodcast(context, subscribedFeed: _transitionFeed);
    }
    final kind = feed.value == null
        ? null
        : FeedKind.values[feed.value!.kind.clamp(
            0,
            FeedKind.values.length - 1,
          )];
    final youtubeKind = youtubeFeedKind(
      Uri.tryParse(feed.value?.feedUrl ?? ''),
    );
    final canShowEpisodes = kind == FeedKind.podcast;
    final canShowArticles = kind == FeedKind.reader;
    final episodeQuery = (
      feedId: feedId,
      limit: _limit,
      sort: _sort,
      filter: _episodeFilter,
      query: _query,
    );
    final articleQuery = (
      feedId: feedId,
      category: null,
      limit: _limit,
      sort: _sort,
      filter: _articleFilter,
      query: _query,
    );
    final AsyncValue<List<Episode>> episodes = canShowEpisodes
        ? ref.watch(filteredEpisodesForFeedProvider(episodeQuery))
        : const AsyncData([]);
    final AsyncValue<List<Article>> articles = canShowArticles
        ? ref.watch(filteredArticlesProvider(articleQuery))
        : const AsyncData([]);
    final episodeTotal = canShowEpisodes
        ? ref
                  .watch(
                    filteredEpisodeCountForFeedProvider((
                      feedId: feedId,
                      filter: _episodeFilter,
                      query: _query,
                    )),
                  )
                  .value ??
              0
        : 0;
    final articleTotal = canShowArticles
        ? ref
                  .watch(
                    filteredArticleCountProvider((
                      feedId: feedId,
                      category: null,
                      filter: _articleFilter,
                      query: _query,
                    )),
                  )
                  .value ??
              0
        : 0;
    return Scaffold(
      appBar: AppBar(
        title: PageTitle(
          MediaQuery.textScalerOf(context).scale(1) > 1.8
              ? switch (kind) {
                  FeedKind.podcast => 'Podcast',
                  FeedKind.reader => 'Feed',
                  null => 'Subscription',
                }
              : feed.value?.title ?? 'Subscription',
        ),
        actions: [
          if (feed.value?.subscribed == true)
            PopupMenuButton<_FeedMenuAction>(
              tooltip: 'Subscription actions',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (action) => _runFeedMenuAction(feed.value!, action),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _FeedMenuAction.settings,
                  child: Text(
                    kind == FeedKind.podcast
                        ? 'Podcast settings'
                        : 'Feed settings',
                  ),
                ),
                if (kind == FeedKind.reader)
                  const PopupMenuItem(
                    value: _FeedMenuAction.markAllRead,
                    child: Text('Mark this feed read'),
                  ),
              ],
            ),
        ],
      ),
      body: AppBackdrop(
        child: feed.when(
          data: (value) {
            if (value == null) {
              return const EmptyState(
                icon: Icons.rss_feed_rounded,
                title: 'Subscription unavailable',
                message: 'This subscription is no longer on this device.',
              );
            }
            return RefreshIndicator(
              onRefresh: value.subscribed ? () => _refresh(value) : () async {},
              notificationPredicate: (_) => value.subscribed,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: _FeedHero(
                      feed: value,
                      refreshing: _refreshing,
                      onRefresh: value.subscribed
                          ? () => _refresh(value)
                          : null,
                      subscriptionControl: MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 2,
                        child: _SubscriptionControl(
                          feedTitle: value.title,
                          subscribed: value.subscribed,
                          busy: _unsubscribing || _subscribing,
                          onPressed: value.subscribed
                              ? () => _unsubscribe(value)
                              : () => _resubscribe(value),
                        ),
                      ),
                    ),
                  ),
                  if (canShowEpisodes) ...[
                    const SliverToBoxAdapter(child: SectionHeader('Episodes')),
                    SliverToBoxAdapter(child: _episodeControls()),
                    episodes.when(
                      data: (items) => items.isEmpty
                          ? SliverToBoxAdapter(
                              child: _filteredEmptyState(
                                noun: 'episodes',
                                allEmptyMessage:
                                    'Refresh this podcast to check for episodes.',
                              ),
                            )
                          : SliverList.builder(
                              itemCount: items.length,
                              itemBuilder: (_, index) =>
                                  EpisodeTile(items[index], showSource: false),
                            ),
                      loading: () => const SliverToBoxAdapter(
                        child: SizedBox(height: 180, child: LoadingView()),
                      ),
                      error: (error, _) => SliverToBoxAdapter(
                        child: ErrorView(
                          friendlyError(error),
                          onRetry: () => ref.invalidate(
                            filteredEpisodesForFeedProvider(episodeQuery),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (canShowArticles) ...[
                    SliverToBoxAdapter(
                      child: SectionHeader(
                        value.protocol == FeedProtocol.nostr.index
                            ? 'Posts'
                            : youtubeKind == null
                            ? 'Articles'
                            : 'Videos',
                      ),
                    ),
                    SliverToBoxAdapter(child: _articleControls()),
                    articles.when(
                      data: (items) => items.isEmpty
                          ? SliverToBoxAdapter(
                              child: _filteredEmptyState(
                                noun: youtubeKind == null
                                    ? 'feed items'
                                    : 'videos',
                                allEmptyMessage:
                                    'Pull down to refresh this feed.',
                              ),
                            )
                          : SliverList.builder(
                              itemCount: items.length,
                              itemBuilder: (_, index) =>
                                  ArticleTile(items[index], showSource: false),
                            ),
                      loading: () => const SliverToBoxAdapter(
                        child: SizedBox(height: 120, child: LoadingView()),
                      ),
                      error: (error, _) => SliverToBoxAdapter(
                        child: ErrorView(
                          friendlyError(error),
                          onRetry: () => ref.invalidate(
                            filteredArticlesProvider(articleQuery),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if ((canShowEpisodes &&
                          (episodes.value?.length ?? 0) < episodeTotal) ||
                      (canShowArticles &&
                          (articles.value?.length ?? 0) < articleTotal))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: OutlinedButton.icon(
                          onPressed: () => setState(() => _limit += _pageSize),
                          icon: const Icon(Icons.expand_more_rounded),
                          label: Text(
                            canShowEpisodes
                                ? 'Load more episodes'
                                : 'Load more feed items',
                          ),
                        ),
                      ),
                    ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
                ],
              ),
            );
          },
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(
            friendlyError(error),
            onRetry: () => ref.invalidate(feedProvider(feedId)),
          ),
        ),
      ),
    );
  }

  Widget _episodeControls() {
    return ContentListControls<EpisodeFeedFilter>(
      searchController: _search,
      searchHint: 'Search episodes…',
      onSearchChanged: _scheduleSearch,
      filter: _episodeFilter,
      filterOptions: const [
        AdaptiveFilterOption(EpisodeFeedFilter.all, 'All'),
        AdaptiveFilterOption(EpisodeFeedFilter.unplayed, 'Unplayed'),
        AdaptiveFilterOption(EpisodeFeedFilter.inProgress, 'In Progress'),
        AdaptiveFilterOption(EpisodeFeedFilter.saved, 'Saved'),
        AdaptiveFilterOption(EpisodeFeedFilter.downloaded, 'Downloaded'),
      ],
      onFilterChanged: (value) => setState(() {
        _episodeFilter = value;
        _limit = _pageSize;
      }),
      sort: _sort,
      onSortChanged: _setSort,
    );
  }

  Widget _articleControls() {
    return ContentListControls<ArticleFeedFilter>(
      searchController: _search,
      searchHint: 'Search this feed…',
      onSearchChanged: _scheduleSearch,
      filter: _articleFilter,
      filterOptions: const [
        AdaptiveFilterOption(ArticleFeedFilter.all, 'All'),
        AdaptiveFilterOption(ArticleFeedFilter.unread, 'Unread'),
        AdaptiveFilterOption(ArticleFeedFilter.saved, 'Saved'),
      ],
      onFilterChanged: (value) => setState(() {
        _articleFilter = value;
        _limit = _pageSize;
      }),
      sort: _sort,
      onSortChanged: _setSort,
      accent: AppConstants.magenta,
    );
  }

  Widget _filteredEmptyState({
    required String noun,
    required String allEmptyMessage,
  }) {
    final filtered =
        _query.isNotEmpty ||
        _episodeFilter != EpisodeFeedFilter.all ||
        _articleFilter != ArticleFeedFilter.all;
    return EmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: filtered ? 'No matching $noun' : 'No $noun yet',
      message: filtered ? 'Try another search or filter.' : allEmptyMessage,
      compact: true,
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

  void _setSort(ContentSort value) {
    if (value == _sort) return;
    setState(() {
      _sort = value;
      _limit = _pageSize;
    });
  }

  Future<void> _runFeedMenuAction(Feed feed, _FeedMenuAction action) async {
    if (action == _FeedMenuAction.markAllRead) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Mark this feed read?'),
          content: Text(
            'Every unread item from ${feed.title} will leave the Unread view.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Mark read'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await ref
            .read(feedRepositoryProvider)
            .markAllArticlesRead(feedId: feed.id);
        if (mounted) showMessageSnackBar(context, '${feed.title} marked read');
      } on Object catch (error) {
        if (mounted) showErrorSnackBar(context, error);
      }
      return;
    }
    final deleted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FeedSettingsSheet(feed: feed),
    );
    if (deleted != true || !mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  Future<void> _unsubscribe(Feed feed) async {
    if (_unsubscribing) return;
    final confirmed = await confirmUnsubscribe(context, feed);
    if (!confirmed || !mounted) return;
    setState(() => _unsubscribing = true);
    try {
      final kind =
          FeedKind.values[feed.kind.clamp(0, FeedKind.values.length - 1)];
      final episodes = kind == FeedKind.podcast
          ? await ref
                .read(databaseProvider)
                .episodesForFeed(feed.id, limit: _limit)
          : const <Episode>[];
      final secret = feed.isPrivate && feed.credentialRef != null
          ? await ref.read(privateFeedStoreProvider).read(feed.credentialRef!)
          : null;
      final address = secret?.url ?? Uri.tryParse(feed.feedUrl);
      final podcast = kind == FeedKind.podcast && address != null
          ? PodcastSearchResult(
              name: feed.title,
              author: feed.author ?? '',
              feedUrl: address,
              artworkUrl: feed.imageUrl == null
                  ? null
                  : Uri.tryParse(feed.imageUrl!),
              genre: null,
              episodeCount: null,
              explicit: false,
            )
          : null;
      final retainedPreview = podcast == null
          ? null
          : _storedPodcastPreview(feed, episodes);
      await removeSubscription(ref, feed);
      if (!mounted) return;
      final retained = await ref.read(databaseProvider).feedById(feed.id);
      if (!mounted) return;
      if (retained != null) {
        showMessageSnackBar(context, 'Unsubscribed from ${feed.title}');
      } else if (podcast != null) {
        setState(() {
          _podcast = podcast;
          _catalogPreviewSnapshot = retainedPreview;
          _catalogPreview = Future.value(retainedPreview!);
          _feedId = null;
          _forcePrivateResubscribe = feed.isPrivate;
          _transitionFeed = null;
          _unsubscribing = false;
        });
      } else if (context.canPop()) {
        context.pop();
      } else {
        context.go('/');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _feedId = feed.id;
          _transitionFeed = null;
        });
        showErrorSnackBar(context, error);
      }
    } finally {
      if (mounted) setState(() => _unsubscribing = false);
    }
  }

  Future<void> _resubscribe(Feed feed) async {
    if (_subscribing) return;
    setState(() => _subscribing = true);
    try {
      await ref.read(feedRepositoryProvider).resubscribe(feed);
      if (mounted) showMessageSnackBar(context, 'Subscribed to ${feed.title}');
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _subscribing = false);
    }
  }

  Widget _catalogPodcast(BuildContext context, {Feed? subscribedFeed}) {
    final podcast = _podcast;
    if (podcast == null) {
      return Scaffold(
        appBar: AppBar(title: const PageTitle('Podcast')),
        body: const AppBackdrop(
          child: EmptyState(
            icon: Icons.podcasts_rounded,
            title: 'Podcast unavailable',
            message: 'Return to search and choose this podcast again.',
          ),
        ),
      );
    }
    final control = _SubscriptionControl(
      feedTitle: podcast.name,
      subscribed: subscribedFeed != null,
      busy: _subscribing || _unsubscribing,
      onPressed: subscribedFeed == null
          ? _subscribe
          : () => _unsubscribe(subscribedFeed),
    );
    return Scaffold(
      appBar: AppBar(
        title: PageTitle(
          MediaQuery.textScalerOf(context).scale(1) > 1.8
              ? 'Podcast'
              : podcast.name,
        ),
      ),
      body: AppBackdrop(
        child: FutureBuilder<ParsedFeed>(
          future: _catalogPreview,
          initialData: _catalogPreviewSnapshot,
          builder: (context, snapshot) {
            final details = snapshot.data;
            final episodes = details?.episodes ?? const <ParsedEpisode>[];
            final visibleCount = episodes.length < _limit
                ? episodes.length
                : _limit;
            final loading =
                snapshot.connectionState != ConnectionState.done &&
                details == null;
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _FeedHero(
                    feed: _previewFeed(podcast, details),
                    refreshing: false,
                    subscriptionControl: MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 2,
                      child: control,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SectionHeader('Episodes')),
                if (loading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: InlineLoadingView(
                        label: 'Loading podcast details',
                      ),
                    ),
                  )
                else if (snapshot.hasError)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: InlineErrorView(
                        friendlyError(snapshot.error!),
                        title: 'Couldn’t load podcast details',
                        onRetry: _retryCatalogPreview,
                      ),
                    ),
                  )
                else if (episodes.isEmpty)
                  const SliverToBoxAdapter(
                    child: SizedBox(
                      height: 190,
                      child: EmptyState(
                        icon: Icons.podcasts_rounded,
                        title: 'No episodes yet',
                        message: 'This podcast has not published any episodes.',
                        compact: true,
                      ),
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: visibleCount,
                    itemBuilder: (_, index) => PodcastPreviewEpisodeTile(
                      episode: episodes[index],
                      fallbackArtworkUrl:
                          details?.imageUrl ?? podcast.artworkUrl,
                      onPlay: () => _playPreviewEpisode(
                        podcast,
                        details!,
                        episodes[index],
                      ),
                    ),
                  ),
                if (visibleCount < episodes.length)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() => _limit += _pageSize),
                        icon: const Icon(Icons.expand_more_rounded),
                        label: const Text('Load older episodes'),
                      ),
                    ),
                  ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _playPreviewEpisode(
    PodcastSearchResult podcast,
    ParsedFeed details,
    ParsedEpisode parsedEpisode,
  ) async {
    try {
      final episode = await ref
          .read(feedRepositoryProvider)
          .cachePodcastPreviewEpisode(
            podcast: podcast,
            details: details,
            episode: parsedEpisode,
          );
      await ref.read(audioHandlerProvider).playEpisode(episode.id);
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    }
  }

  void _retryCatalogPreview() {
    setState(() {
      _limit = _pageSize;
      _catalogPreviewSnapshot = null;
      _catalogPreview = _loadCatalogPreview();
    });
  }

  Future<void> _subscribe() async {
    final podcast = _podcast;
    if (_subscribing || podcast == null) return;
    setState(() => _subscribing = true);
    try {
      final feed = await ref
          .read(feedRepositoryProvider)
          .subscribe(
            podcast.feedUrl.toString(),
            forcePrivate: _forcePrivateResubscribe,
            expectedKind: FeedKind.podcast,
          );
      if (!mounted) return;
      setState(() {
        _feedId = feed.id;
        _transitionFeed = feed;
        _forcePrivateResubscribe = false;
        _subscribing = false;
      });
      showMessageSnackBar(context, 'Subscribed to ${feed.title}');
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _subscribing = false);
    }
  }

  Future<void> _refresh(Feed feed) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final result = await ref.read(syncCoordinatorProvider).refreshFeed(feed);
      if (result.failedFeeds > 0 && mounted) {
        showMessageSnackBar(
          context,
          'Couldn’t refresh this feed. Check the error below.',
        );
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }
}

final class _FeedHero extends StatelessWidget {
  const _FeedHero({
    required this.feed,
    required this.refreshing,
    this.onRefresh,
    this.subscriptionControl,
  });

  final Feed feed;
  final bool refreshing;
  final VoidCallback? onRefresh;
  final Widget? subscriptionControl;

  @override
  Widget build(BuildContext context) {
    final stackIdentity = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    final youtubeKind = youtubeFeedKind(Uri.tryParse(feed.feedUrl));
    final artworkIcon = feed.protocol == FeedProtocol.nostr.index
        ? Icons.person_outline_rounded
        : youtubeKind == null
        ? Icons.rss_feed_rounded
        : Icons.ondemand_video_rounded;
    final kind =
        FeedKind.values[feed.kind.clamp(0, FeedKind.values.length - 1)];
    final accent = kind == FeedKind.podcast
        ? AppConstants.cyan
        : AppConstants.magenta;
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: SignalPanel(
          accent: accent,
          color: AppConstants.surface.withValues(alpha: 0.88),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (stackIdentity) ...[
                FeedArtwork(feed: feed, size: 88, radius: 8, icon: artworkIcon),
                if (subscriptionControl != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: subscriptionControl,
                  ),
                ],
                const SizedBox(height: 14),
                _FeedIdentity(feed: feed),
                const SizedBox(height: 14),
                _FeedDescription(feed: feed),
              ] else if (constraints.maxWidth < 460) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FeedArtwork(
                      feed: feed,
                      size: 88,
                      radius: 8,
                      icon: artworkIcon,
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: _FeedIdentity(feed: feed)),
                  ],
                ),
                const SizedBox(height: 14),
                _FeedDescription(feed: feed),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FeedArtwork(
                      feed: feed,
                      size: 124,
                      radius: 10,
                      icon: artworkIcon,
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FeedIdentity(feed: feed),
                          const SizedBox(height: 12),
                          _FeedDescription(feed: feed),
                        ],
                      ),
                    ),
                  ],
                ),
              if (!stackIdentity && subscriptionControl != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: subscriptionControl,
                ),
              ],
              if (refreshing) ...[
                const SizedBox(height: 14),
                const InlineLoadingView(label: 'Refreshing feed'),
              ] else if (feed.subscribed && feed.refreshError != null) ...[
                const SizedBox(height: 14),
                InlineErrorView(
                  feed.refreshError!,
                  title: 'Couldn’t refresh feed',
                  onRetry: onRefresh,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Feed _previewFeed(PodcastSearchResult podcast, ParsedFeed? details) {
  final timestamp = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final parsedTitle = details?.title.trim();
  final parsedAuthor = details?.author?.trim();
  return Feed(
    id: 'catalog-preview',
    title: parsedTitle?.isNotEmpty == true ? parsedTitle! : podcast.name,
    description: details?.description?.trim().isNotEmpty == true
        ? details!.description!.trim()
        : podcast.genre,
    feedUrl: podcast.feedUrl.toString(),
    imageUrl: (details?.imageUrl ?? podcast.artworkUrl)?.toString(),
    author: parsedAuthor?.isNotEmpty == true ? parsedAuthor : podcast.author,
    kind: FeedKind.podcast.index,
    protocol: FeedProtocol.syndication.index,
    subscribed: false,
    isPrivate: false,
    autoDownload: false,
    autoDownloadLimit: 3,
    notifications: false,
    introSkipMs: 0,
    outroSkipMs: 0,
    autoQueue: false,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

ParsedFeed _storedPodcastPreview(Feed feed, List<Episode> episodes) {
  return ParsedFeed(
    title: feed.title,
    description: feed.description,
    siteUrl: null,
    imageUrl: feed.imageUrl == null ? null : Uri.tryParse(feed.imageUrl!),
    author: feed.author,
    kind: FeedKind.podcast,
    episodes: [
      for (final episode in episodes)
        ParsedEpisode(
          guid: episode.guid,
          title: episode.title,
          description: episode.description,
          enclosureUrl: Uri.parse(episode.enclosureUrl),
          mimeType: episode.mimeType,
          imageUrl: episode.imageUrl == null
              ? null
              : Uri.tryParse(episode.imageUrl!),
          publishedAt: episode.publishedAt,
          duration: episode.durationMs == null
              ? null
              : Duration(milliseconds: episode.durationMs!),
          fileSize: episode.fileSize,
          explicit: episode.explicit,
          chaptersUrl: episode.chaptersUrl == null
              ? null
              : Uri.tryParse(episode.chaptersUrl!),
          transcripts: const [],
        ),
    ],
    articles: const [],
  );
}

final class _FeedIdentity extends StatelessWidget {
  const _FeedIdentity({required this.feed});

  final Feed feed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 2.4,
            child: Text(
              feed.title,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
        if (feed.author?.isNotEmpty == true &&
            feed.author!.trim().toLowerCase() !=
                feed.title.trim().toLowerCase()) ...[
          const SizedBox(height: 7),
          Text(
            feed.author!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppConstants.cyan,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

final class _SubscriptionControl extends StatelessWidget {
  const _SubscriptionControl({
    required this.feedTitle,
    required this.busy,
    required this.onPressed,
    this.subscribed = true,
  });

  final String feedTitle;
  final bool subscribed;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = busy ? AppConstants.secondaryText : AppConstants.cyan;
    final label = subscribed ? 'Subscribed' : 'Subscribe';
    return Semantics(
      button: true,
      enabled: !busy,
      label: busy
          ? '${subscribed ? 'Unsubscribing from' : 'Subscribing to'} $feedTitle'
          : subscribed
          ? 'Subscribed to $feedTitle. Unsubscribe'
          : 'Subscribe to $feedTitle',
      excludeSemantics: true,
      onTap: busy ? null : onPressed,
      child: Tooltip(
        message: busy
            ? subscribed
                  ? 'Unsubscribing'
                  : 'Subscribing'
            : subscribed
            ? 'Unsubscribe'
            : label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: busy ? null : onPressed,
            customBorder: const CutCornerBorder(cut: 7),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: DecoratedBox(
                key: const ValueKey('subscription-pill'),
                decoration: ShapeDecoration(
                  color: color.withValues(alpha: 0.06),
                  shape: CutCornerBorder(
                    cut: 7,
                    side: BorderSide(color: color.withValues(alpha: 0.4)),
                  ),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 28),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (busy)
                          SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: color,
                            ),
                          )
                        else
                          Icon(
                            subscribed
                                ? Icons.check_rounded
                                : Icons.add_rounded,
                            size: 14,
                          ),
                        const SizedBox(width: 5),
                        Text(
                          label,
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: color),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _FeedDescription extends StatelessWidget {
  const _FeedDescription({required this.feed});

  final Feed feed;

  @override
  Widget build(BuildContext context) {
    final youtubeKind = youtubeFeedKind(Uri.tryParse(feed.feedUrl));
    return Text(
      feed.description?.trim().isNotEmpty == true
          ? feed.description!
          : feed.protocol == FeedProtocol.nostr.index
          ? 'Nostr profile'
          : switch ((
              FeedKind.values[feed.kind.clamp(0, FeedKind.values.length - 1)],
              youtubeKind,
            )) {
              (FeedKind.reader, YouTubeFeedKind.channel) => 'YouTube channel',
              (FeedKind.reader, YouTubeFeedKind.playlist) => 'YouTube playlist',
              (FeedKind.reader, null) => 'RSS feed',
              (FeedKind.podcast, _) => 'Podcast',
            },
      maxLines: 5,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: AppConstants.secondaryText, height: 1.45),
    );
  }
}

final class FeedSettingsSheet extends ConsumerStatefulWidget {
  const FeedSettingsSheet({required this.feed, super.key});

  final Feed feed;

  @override
  ConsumerState<FeedSettingsSheet> createState() => _FeedSettingsSheetState();
}

enum _FeedSettingsOperation { notifications, save, privateAccess, unsubscribe }

class _FeedSettingsSheetState extends ConsumerState<FeedSettingsSheet> {
  late bool _autoDownload = widget.feed.autoDownload;
  late bool _notifications = widget.feed.notifications;
  late bool _autoQueue = widget.feed.autoQueue;
  late int _limit = widget.feed.autoDownloadLimit;
  late final TextEditingController _intro = TextEditingController(
    text: '${widget.feed.introSkipMs ~/ 1000}',
  );
  late final TextEditingController _outro = TextEditingController(
    text: '${widget.feed.outroSkipMs ~/ 1000}',
  );
  late final TextEditingController _category = TextEditingController(
    text: widget.feed.category ?? '',
  );
  final FocusNode _categoryFocus = FocusNode();
  _FeedSettingsOperation? _operation;

  bool get _busy => _operation != null;

  FeedKind get _kind =>
      FeedKind.values[widget.feed.kind.clamp(0, FeedKind.values.length - 1)];

  bool get _isReader => _kind == FeedKind.reader;

  bool get _isYouTube =>
      youtubeFeedKind(Uri.tryParse(widget.feed.feedUrl)) != null;

  @override
  void dispose() {
    _intro.dispose();
    _outro.dispose();
    _category.dispose();
    _categoryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categoryOptions = _isReader
        ? feedCategoryOptions(
            (ref.watch(readerFeedsProvider).value ?? const <Feed>[]).map(
              (feed) => feed.category,
            ),
          )
        : const <String>[];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(switch (_kind) {
                FeedKind.reader => 'Feed settings',
                FeedKind.podcast => 'Podcast settings',
              }, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              if (_isReader) ...[
                _categoryField(context, categoryOptions),
                const SizedBox(height: 4),
              ],
              if (!_isReader) ...[
                AdaptiveSwitchTile(
                  value: _autoDownload,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _autoDownload = value),
                  title: 'Automatically download new episodes',
                  subtitle: 'Wi-Fi only; stored by trickle.',
                ),
                if (_autoDownload)
                  AdaptiveDropdownField<int>(
                    initialValue: _limit,
                    label: 'Maximum new episodes per refresh',
                    items: [1, 2, 3, 5, 10]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              '$value ${value == 1 ? 'episode' : 'episodes'}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _limit = value ?? 3),
                  ),
                AdaptiveSwitchTile(
                  value: _autoQueue,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _autoQueue = value),
                  title: 'Add new episodes to Up Next',
                ),
              ],
              AdaptiveSwitchTile(
                value: _notifications,
                onChanged: _busy ? null : _setNotifications,
                secondary: SizedBox.square(
                  dimension: 24,
                  child: _operation == _FeedSettingsOperation.notifications
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : const Icon(Icons.notifications_outlined),
                ),
                title: switch (_kind) {
                  FeedKind.reader when _isYouTube => 'New video notifications',
                  FeedKind.reader
                      when widget.feed.protocol == FeedProtocol.nostr.index =>
                    'New post notifications',
                  FeedKind.reader => 'New feed item notifications',
                  FeedKind.podcast => 'New episode notifications',
                },
                subtitle:
                    'Alerts depend on iOS or Android background scheduling.',
              ),
              if (!_isReader) ...[
                const SizedBox(height: 10),
                Column(
                  children: [
                    TextField(
                      enabled: !_busy,
                      controller: _intro,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Skip intro (seconds)',
                        helperText: '0–600',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      enabled: !_busy,
                      controller: _outro,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Skip outro (seconds)',
                        helperText: '0–600',
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              if (widget.feed.isPrivate)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _updatePrivateAccess,
                  icon: const Icon(Icons.key_rounded),
                  label: Text(
                    _operation == _FeedSettingsOperation.privateAccess
                        ? 'Updating access…'
                        : 'Update private access',
                  ),
                ),
              if (widget.feed.isPrivate) const SizedBox(height: 10),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(
                  _operation == _FeedSettingsOperation.save
                      ? 'Saving…'
                      : 'Save settings',
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: AppConstants.danger,
                ),
                onPressed: _busy ? null : _unsubscribe,
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(
                  _operation == _FeedSettingsOperation.unsubscribe
                      ? 'Unsubscribing…'
                      : 'Unsubscribe',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _categoryField(BuildContext context, List<String> options) {
    const helper = 'Optional. Choose a category or enter a new one.';
    final initialCategory = feedCategoryIdentity(widget.feed.category);
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    final field = LayoutBuilder(
      builder: (context, constraints) => RawAutocomplete<String>(
        textEditingController: _category,
        focusNode: _categoryFocus,
        optionsBuilder: (value) {
          if (_busy) return const Iterable<String>.empty();
          final query = value.text.trim().toLowerCase();
          if (query.isEmpty ||
              feedCategoryIdentity(value.text) == initialCategory) {
            return options;
          }
          return options.where(
            (category) => category.toLowerCase().contains(query),
          );
        },
        onSelected: (category) {
          _category.value = TextEditingValue(
            text: category,
            selection: TextSelection.collapsed(offset: category.length),
          );
        },
        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) =>
            TextField(
              enabled: !_busy,
              controller: controller,
              focusNode: focusNode,
              inputFormatters: [
                LengthLimitingTextInputFormatter(maxFeedCategoryLength),
              ],
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: largeText ? null : 'Category',
                helperText: largeText ? null : helper,
                suffixIcon: options.isEmpty
                    ? null
                    : const Icon(Icons.arrow_drop_down_rounded),
              ),
              onSubmitted: (_) => onFieldSubmitted(),
            ),
        optionsViewBuilder: (context, onSelected, matches) {
          final categories = matches.toList(growable: false);
          final highlighted = AutocompleteHighlightedOption.of(context);
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              color: AppConstants.elevated,
              elevation: 8,
              shape: const CutCornerBorder(
                cut: 10,
                side: BorderSide(color: AppConstants.hairline),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth,
                  maxHeight: 240,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    return InkWell(
                      onTap: () => onSelected(category),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: ColoredBox(
                          color: index == highlighted
                              ? AppConstants.cyan.withValues(alpha: 0.1)
                              : Colors.transparent,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(category),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
    if (!largeText) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Category'),
        const SizedBox(height: 8),
        field,
        const SizedBox(height: 6),
        Text(
          helper,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppConstants.secondaryText),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_busy) return;
    final intro = int.tryParse(_intro.text.trim().isEmpty ? '0' : _intro.text);
    final outro = int.tryParse(_outro.text.trim().isEmpty ? '0' : _outro.text);
    if (intro == null || outro == null || intro > 600 || outro > 600) {
      showMessageSnackBar(
        context,
        'Skip times must be between 0 and 10 minutes (600 seconds).',
      );
      return;
    }
    setState(() => _operation = _FeedSettingsOperation.save);
    try {
      await ref
          .read(feedRepositoryProvider)
          .updateFeedSettings(
            widget.feed.id,
            autoDownload: _autoDownload,
            autoDownloadLimit: _limit,
            notifications: _notifications,
            introSkipMs: intro * 1000,
            outroSkipMs: outro * 1000,
            autoQueue: _autoQueue,
            category: _isReader ? _category.text : null,
          );
      if (!mounted) return;
      setState(() => _operation = null);
      Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      _finishOperation(_FeedSettingsOperation.save);
    }
  }

  Future<void> _setNotifications(bool value) async {
    if (_busy) return;
    if (!value) {
      setState(() => _notifications = false);
      return;
    }
    setState(() => _operation = _FeedSettingsOperation.notifications);
    try {
      final enabled = await ref
          .read(notificationServiceProvider)
          .requestPermission();
      if (!mounted) return;
      setState(() => _notifications = enabled);
      if (!enabled) {
        showMessageSnackBar(context, 'Notifications remain disabled');
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _notifications = false);
      showErrorSnackBar(context, error);
    } finally {
      _finishOperation(_FeedSettingsOperation.notifications);
    }
  }

  Future<void> _updatePrivateAccess() async {
    if (_busy) return;
    setState(() => _operation = _FeedSettingsOperation.privateAccess);
    try {
      final secret = await ref.read(
        privateFeedSecretProvider(widget.feed.id).future,
      );
      if (!mounted) return;
      final replacement = await showDialog<_PrivateAccessInput>(
        context: context,
        builder: (_) =>
            _PrivateAccessDialog(initialUrl: secret?.url.toString() ?? ''),
      );
      if (replacement == null || !mounted) return;
      await ref
          .read(feedRepositoryProvider)
          .updatePrivateAccess(
            widget.feed.id,
            replacement.url,
            username: replacement.username,
            password: replacement.password,
            bearerToken: replacement.bearer,
          );
      ref.invalidate(privateFeedSecretProvider(widget.feed.id));
      if (!mounted) return;
      showMessageSnackBar(context, 'Private access updated');
    } on Object catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      _finishOperation(_FeedSettingsOperation.privateAccess);
    }
  }

  Future<void> _unsubscribe() async {
    if (_busy) return;
    setState(() => _operation = _FeedSettingsOperation.unsubscribe);
    if (!await confirmUnsubscribe(context, widget.feed) || !mounted) {
      _finishOperation(_FeedSettingsOperation.unsubscribe);
      return;
    }
    try {
      await removeSubscription(ref, widget.feed);
      if (!mounted) return;
      setState(() => _operation = null);
      Navigator.pop(context, true);
    } on Object catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      _finishOperation(_FeedSettingsOperation.unsubscribe);
    }
  }

  void _finishOperation(_FeedSettingsOperation operation) {
    if (mounted && _operation == operation) {
      setState(() => _operation = null);
    }
  }
}

typedef _PrivateAccessInput = ({
  String url,
  String username,
  String password,
  String bearer,
});

final class _PrivateAccessDialog extends StatefulWidget {
  const _PrivateAccessDialog({required this.initialUrl});

  final String initialUrl;

  @override
  State<_PrivateAccessDialog> createState() => _PrivateAccessDialogState();
}

class _PrivateAccessDialogState extends State<_PrivateAccessDialog> {
  late final TextEditingController _url = TextEditingController(
    text: widget.initialUrl,
  );
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _bearer = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _bearer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Update private access'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Private feed URL',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'For a URL token, leave the fields below blank. For Basic or Bearer authentication, enter the replacement credentials.',
                style: TextStyle(
                  color: AppConstants.secondaryText,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Username (Basic auth)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'OR',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppConstants.secondaryText,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              TextField(
                controller: _bearer,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Bearer token'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                InlineErrorView(
                  _error!,
                  title: 'Couldn’t update private access',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Verify and update'),
        ),
      ],
    );
  }

  void _submit() {
    final rawUrl = _url.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    final bearer = _bearer.text.trim();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      setState(() => _error = 'Enter a valid HTTP or HTTPS feed URL.');
      return;
    }
    if (username.isNotEmpty != password.isNotEmpty) {
      setState(
        () => _error = 'Basic authentication needs a username and password.',
      );
      return;
    }
    if (username.isNotEmpty && bearer.isNotEmpty) {
      setState(
        () => _error = 'Use Basic authentication or a bearer token, not both.',
      );
      return;
    }
    Navigator.pop(context, (
      url: rawUrl,
      username: username,
      password: password,
      bearer: bearer,
    ));
  }
}
