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
import '../widgets/common.dart';

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
  String? _subscribingFeedUrl;
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
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null && results > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppConstants.danger.withValues(alpha: 0.07),
                    border: const Border(
                      left: BorderSide(color: AppConstants.danger, width: 2),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppConstants.danger),
                      ),
                    ),
                  ),
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
                          ? 'Try another phrase. Add feeds from Podcasts or Reader.'
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
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
      itemCount: _catalog.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 86, endIndent: 16),
      itemBuilder: (context, index) {
        final result = _catalog[index];
        return ListTile(
          leading: Artwork(url: result.artworkUrl?.toString(), size: 54),
          title: EpisodeTitle(
            title: result.name,
            explicit: result.explicit,
            maxLines: 2,
          ),
          subtitle: Text(
            [
              result.author,
              if (result.genre != null) result.genre!,
              if (result.episodeCount case final count?)
                '$count ${count == 1 ? 'episode' : 'episodes'}',
            ].where((part) => part.isNotEmpty).join(' · '),
            maxLines: 2,
          ),
          trailing: TextButton(
            onPressed: _subscribingFeedUrl == null
                ? () => _subscribe(result)
                : null,
            child: Text(
              _subscribingFeedUrl == result.feedUrl.toString()
                  ? 'Subscribing…'
                  : 'Subscribe',
            ),
          ),
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
      if (mounted && generation == _searchGeneration) {
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

  Future<void> _subscribe(PodcastSearchResult result) async {
    final feedUrl = result.feedUrl.toString();
    if (_subscribingFeedUrl != null) return;
    final router = GoRouter.of(context);
    setState(() {
      _subscribingFeedUrl = feedUrl;
    });
    try {
      final feed = await ref.read(feedRepositoryProvider).subscribe(feedUrl);
      if (mounted) router.push('/podcast/${feed.id}');
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted && _subscribingFeedUrl == feedUrl) {
        setState(() => _subscribingFeedUrl = null);
      }
    }
  }
}
