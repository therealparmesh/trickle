import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/feed_models.dart';
import '../presentation/app_shell.dart';
import '../presentation/pages/article_page.dart';
import '../presentation/pages/downloads_page.dart';
import '../presentation/pages/episode_page.dart';
import '../presentation/pages/home_page.dart';
import '../presentation/pages/library_page.dart';
import '../presentation/pages/player_page.dart';
import '../presentation/pages/feed_detail_page.dart';
import '../presentation/pages/podcasts_page.dart';
import '../presentation/pages/queue_page.dart';
import '../presentation/pages/reader_page.dart';
import '../presentation/pages/saved_page.dart';
import '../presentation/pages/search_page.dart';
import '../presentation/pages/settings_page.dart';
import '../presentation/widgets/navigation_glitch.dart';

GoRouter createRouter() {
  final rootNavigationObserver = RouteObserver<ModalRoute<dynamic>>();
  final shellNavigationObserver = RouteObserver<ModalRoute<dynamic>>();
  Page<void> navigationPage(
    GoRouterState state,
    Widget child, {
    required RouteObserver<ModalRoute<dynamic>> observer,
  }) {
    return NoTransitionPage<void>(
      key: state.pageKey,
      child: NavigationGlitch(routeObserver: observer, child: child),
    );
  }

  Page<void> shellPage(GoRouterState state, Widget child) =>
      navigationPage(state, child, observer: shellNavigationObserver);

  return GoRouter(
    observers: [rootNavigationObserver],
    routes: [
      ShellRoute(
        notifyRootObserver: false,
        observers: [shellNavigationObserver],
        builder: (_, _, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (_, state) => shellPage(state, const HomePage()),
          ),
          GoRoute(
            path: '/podcasts',
            pageBuilder: (_, state) => shellPage(state, const PodcastsPage()),
          ),
          GoRoute(
            path: '/reader',
            pageBuilder: (_, state) => shellPage(
              state,
              ReaderPage(
                initialFeeds: state.uri.queryParameters['tab'] == 'feeds',
                initialFilter: state.uri.queryParameters['filter'] ?? 'unread',
              ),
            ),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (_, state) => shellPage(state, const LibraryPage()),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (_, state) => shellPage(
              state,
              SearchPage(
                initialCatalog: state.uri.queryParameters['tab'] == 'podcasts',
              ),
            ),
          ),
          GoRoute(
            path: '/podcast/:id',
            pageBuilder: (_, state) => shellPage(
              state,
              FeedDetailPage(feedId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/podcast-preview',
            pageBuilder: (_, state) => shellPage(state, switch (state.extra) {
              final PodcastSearchResult podcast => FeedDetailPage.catalog(
                podcast: podcast,
              ),
              _ => const FeedDetailPage.catalog(),
            }),
          ),
          GoRoute(
            path: '/feed/:id',
            pageBuilder: (_, state) => shellPage(
              state,
              FeedDetailPage(feedId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/article/:id',
            pageBuilder: (_, state) => shellPage(
              state,
              ArticlePage(articleId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/episode/:id',
            pageBuilder: (_, state) => shellPage(
              state,
              EpisodePage(episodeId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/queue',
            pageBuilder: (_, state) => shellPage(state, const QueuePage()),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (_, state) => shellPage(state, const DownloadsPage()),
          ),
          GoRoute(
            path: '/saved',
            pageBuilder: (_, state) => shellPage(
              state,
              SavedPage(
                initialTab: state.uri.queryParameters['tab'] == 'articles'
                    ? 1
                    : 0,
              ),
            ),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (_, state) => shellPage(state, const SettingsPage()),
          ),
        ],
      ),
      GoRoute(
        path: '/player',
        pageBuilder: (_, state) => navigationPage(
          state,
          const PlayerPage(),
          observer: rootNavigationObserver,
        ),
      ),
    ],
  );
}
