import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/database/app_database.dart';
import '../../domain/feed_models.dart';
import '../subscription_actions.dart';
import '../widgets/common.dart';

final _catalogSubscriptionProvider = Provider.autoDispose.family<Feed?, String>(
  (ref, identity) {
    final feeds = ref.watch(podcastFeedsProvider).value ?? const <Feed>[];
    for (final feed in feeds) {
      if (!feed.isPrivate && _feedUrlIdentity(feed.feedUrl) == identity) {
        return feed;
      }
    }
    return null;
  },
);

final class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({this.initialCatalog = false, super.key});
  final bool initialCatalog;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _query = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  String? _error;
  List<SearchHit> _local = const [];
  List<PodcastSearchResult> _catalog = const [];
  int _searchGeneration = 0;
  String _scheduledQuery = '';
  late int _scheduledTab;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialCatalog ? 1 : 0,
    )..addListener(_scheduleSearch);
    _scheduledTab = _tabs.index;
    _query.addListener(_scheduleSearch);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabs.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _tabs.index == 0 ? _local.length : _catalog.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        bottom: AdaptiveTabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Library'),
            Tab(text: 'Podcasts'),
          ],
        ),
      ),
      body: AppBackdrop(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: SearchBar(
                controller: _query,
                autoFocus: true,
                hintText: _tabs.index == 0
                    ? 'Episodes, articles, or feeds…'
                    : 'Podcast title or creator…',
                leading: const Icon(Icons.search_rounded),
                trailing: [
                  if (_query.text.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear search',
                      onPressed: _query.clear,
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
                onSubmitted: (_) {
                  _debounce?.cancel();
                  _runSearch();
                },
              ),
            ),
            if (_loading)
              const InlineLoadingView(
                label: 'Searching',
                padding: EdgeInsets.zero,
              ),
            if (_error != null && results > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: InlineErrorView(
                  _error!,
                  title: 'Couldn’t update results',
                  onRetry: _runSearch,
                ),
              ),
            Expanded(
              child: _query.text.trim().length < 2
                  ? const EmptyState(
                      icon: Icons.manage_search_rounded,
                      title: 'Enter at least two characters',
                      message:
                          'Local search stays on your device. Podcast discovery queries Apple.',
                    )
                  : _error != null && results == 0 && !_loading
                  ? ErrorView(_error!, onRetry: _runSearch)
                  : results == 0 && !_loading
                  ? EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'Nothing found',
                      message: _tabs.index == 0
                          ? 'Try another phrase or add a new feed.'
                          : 'Try a broader podcast title or creator.',
                    )
                  : TabBarView(
                      controller: _tabs,
                      children: [_localResults(), _catalogResults()],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localResults() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
      itemCount: _local.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 56, endIndent: 16),
      itemBuilder: (context, index) {
        final hit = _local[index];
        final icon = switch (hit.kind) {
          'episode' => Icons.podcasts_rounded,
          'article' => Icons.article_rounded,
          _ => Icons.rss_feed_rounded,
        };
        return ListTile(
          leading: Icon(icon, color: AppConstants.cyan),
          title: Text(hit.title),
          subtitle: Text(
            [
              hit.feedTitle,
              hit.excerpt,
            ].where((part) => part.isNotEmpty).join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => switch (hit.kind) {
            'episode' => context.push('/episode/${hit.entityId}'),
            'article' => context.push('/article/${hit.entityId}'),
            _ => context.push('/feed/${hit.entityId}'),
          },
        );
      },
    );
  }

  Widget _catalogResults() {
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
      itemCount: _catalog.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 86, endIndent: 16),
      itemBuilder: (context, index) {
        final result = _catalog[index];
        return _CatalogResultRow(
          key: ValueKey(result.feedUrl),
          result: result,
          largeText: largeText,
        );
      },
    );
  }

  void _scheduleSearch() {
    final query = _query.text.trim();
    final tab = _tabs.index;
    if (query == _scheduledQuery && tab == _scheduledTab) return;
    _scheduledQuery = query;
    _scheduledTab = tab;
    final canSearch = query.length >= 2;
    setState(() {
      _loading = canSearch;
      _error = null;
      if (tab == 0) {
        _local = const [];
      } else {
        _catalog = const [];
      }
    });
    _debounce?.cancel();
    final duration = tab == 0
        ? const Duration(milliseconds: 150)
        : const Duration(milliseconds: 450);
    _debounce = Timer(duration, _runSearch);
  }

  Future<void> _runSearch() async {
    final generation = ++_searchGeneration;
    final query = _query.text.trim();
    if (query.length < 2) {
      setState(() {
        _local = const [];
        _catalog = const [];
        _loading = false;
      });
      return;
    }
    final tab = _tabs.index;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (tab == 0) {
        final hits = await ref.read(databaseProvider).search(query);
        if (!mounted ||
            generation != _searchGeneration ||
            _query.text.trim() != query ||
            _tabs.index != tab) {
          return;
        }
        setState(() => _local = hits);
      } else {
        final region = PlatformDispatcher.instance.locale.countryCode ?? 'US';
        final results = await ref
            .read(podcastSearchProvider)
            .search(query, region);
        if (!mounted ||
            generation != _searchGeneration ||
            _query.text.trim() != query ||
            _tabs.index != tab) {
          return;
        }
        setState(() => _catalog = results);
      }
    } on Object catch (error) {
      if (mounted &&
          generation == _searchGeneration &&
          _query.text.trim() == query &&
          _tabs.index == tab) {
        setState(() => _error = friendlyError(error));
      }
    } finally {
      if (mounted &&
          generation == _searchGeneration &&
          _query.text.trim() == query &&
          _tabs.index == tab) {
        setState(() => _loading = false);
      }
    }
  }
}

final class _CatalogResultRow extends ConsumerStatefulWidget {
  const _CatalogResultRow({
    required this.result,
    required this.largeText,
    super.key,
  });

  final PodcastSearchResult result;
  final bool largeText;

  @override
  ConsumerState<_CatalogResultRow> createState() => _CatalogResultRowState();
}

class _CatalogResultRowState extends ConsumerState<_CatalogResultRow> {
  bool _busy = false;
  Feed? _optimisticFeed;
  String? _removedFeedId;

  @override
  Widget build(BuildContext context) {
    final identity = _feedUrlIdentity(widget.result.feedUrl.toString());
    final provider = _catalogSubscriptionProvider(identity);
    ref.listen(provider, (_, feed) {
      if (!mounted) return;
      final confirmedSubscription =
          _optimisticFeed != null && _optimisticFeed!.id == feed?.id;
      final confirmedRemoval = _removedFeedId != null && feed == null;
      if (confirmedSubscription || confirmedRemoval) {
        setState(() {
          if (confirmedSubscription) _optimisticFeed = null;
          if (confirmedRemoval) _removedFeedId = null;
        });
      }
    });
    final storedFeed = ref.watch(provider);
    final feed = storedFeed?.id == _removedFeedId
        ? null
        : storedFeed ?? _optimisticFeed;
    final title = EpisodeTitle(
      title: widget.result.name,
      explicit: widget.result.explicit,
      maxLines: widget.largeText ? 4 : 2,
    );
    final subtitle = Text(
      [
        widget.result.author,
        if (widget.result.genre != null) widget.result.genre!,
        if (widget.result.episodeCount case final count?)
          '$count ${count == 1 ? 'episode' : 'episodes'}',
      ].where((part) => part.isNotEmpty).join(' · '),
      maxLines: widget.largeText ? 3 : 2,
      overflow: TextOverflow.ellipsis,
    );
    final action = _CatalogSubscriptionButton(
      podcastName: widget.result.name,
      subscribed: feed != null,
      busy: _busy,
      largeText: widget.largeText,
      onPressed: () => _toggleSubscription(feed),
    );
    if (widget.largeText) {
      return Semantics(
        button: true,
        label: 'Open ${widget.result.name}',
        onTap: _busy ? null : () => _open(feed),
        child: InkWell(
          onTap: _busy ? null : () => _open(feed),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Artwork(
                      url: widget.result.artworkUrl?.toString(),
                      size: 54,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [title, const SizedBox(height: 4), subtitle],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: action),
              ],
            ),
          ),
        ),
      );
    }
    return ListTile(
      leading: Artwork(url: widget.result.artworkUrl?.toString(), size: 54),
      title: title,
      subtitle: subtitle,
      trailing: action,
      onTap: _busy ? null : () => _open(feed),
    );
  }

  void _open(Feed? feed) {
    if (feed != null) {
      context.push('/podcast/${feed.id}');
    } else {
      context.push('/podcast-preview', extra: widget.result);
    }
  }

  Future<void> _toggleSubscription(Feed? feed) async {
    if (_busy) return;
    setState(() => _busy = true);
    if (feed != null) {
      final confirmed = await confirmUnsubscribe(context, feed);
      if (!confirmed || !mounted) {
        if (mounted) setState(() => _busy = false);
        return;
      }
    }
    try {
      if (feed == null) {
        final subscribed = await ref
            .read(feedRepositoryProvider)
            .subscribe(widget.result.feedUrl.toString());
        if (!mounted) return;
        final provider = _catalogSubscriptionProvider(
          _feedUrlIdentity(widget.result.feedUrl.toString()),
        );
        setState(() {
          _optimisticFeed = ref.read(provider)?.id == subscribed.id
              ? null
              : subscribed;
        });
        showMessageSnackBar(context, 'Subscribed to ${widget.result.name}');
      } else {
        await removeSubscription(ref, feed);
        if (!mounted) return;
        final provider = _catalogSubscriptionProvider(
          _feedUrlIdentity(widget.result.feedUrl.toString()),
        );
        setState(() {
          _optimisticFeed = null;
          _removedFeedId = ref.read(provider) == null ? null : feed.id;
        });
        showMessageSnackBar(context, 'Unsubscribed from ${widget.result.name}');
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

final class _CatalogSubscriptionButton extends StatelessWidget {
  const _CatalogSubscriptionButton({
    required this.podcastName,
    required this.subscribed,
    required this.busy,
    required this.largeText,
    required this.onPressed,
  });

  final String podcastName;
  final bool subscribed;
  final bool busy;
  final bool largeText;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = subscribed ? 'Unsubscribe' : 'Subscribe';
    final button = SizedBox(
      width: largeText ? 224 : 108,
      height: largeText ? 64 : 48,
      child: TextButton(onPressed: busy ? null : onPressed, child: Text(label)),
    );
    return Semantics(
      button: true,
      enabled: !busy,
      liveRegion: true,
      label: busy
          ? '${subscribed ? 'Unsubscribing from' : 'Subscribing to'} $podcastName'
          : '$label $podcastName',
      excludeSemantics: true,
      child: largeText
          ? MediaQuery.withClampedTextScaling(maxScaleFactor: 2, child: button)
          : button,
    );
  }
}

String _feedUrlIdentity(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty) return value.trim();
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase() == 'http'
            ? 'https'
            : uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
      )
      .removeFragment()
      .toString();
}
