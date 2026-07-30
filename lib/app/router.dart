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
  Widget navigationScreen(Widget child) {
    return NavigationGlitch(
      routeObserver: shellNavigationObserver,
      child: child,
    );
  }

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
            builder: (_, _) => navigationScreen(const HomePage()),
          ),
          GoRoute(
            path: '/podcasts',
            builder: (_, _) => navigationScreen(const PodcastsPage()),
          ),
          GoRoute(
            path: '/reader',
            builder: (_, state) => navigationScreen(
              ReaderPage(
                initialFeeds: state.uri.queryParameters['tab'] == 'feeds',
                initialFilter: state.uri.queryParameters['filter'] ?? 'unread',
              ),
            ),
          ),
          GoRoute(
            path: '/library',
            builder: (_, _) => navigationScreen(const LibraryPage()),
          ),
          GoRoute(
            path: '/search',
            builder: (_, state) => navigationScreen(
              SearchPage(
                initialCatalog: state.uri.queryParameters['tab'] == 'podcasts',
              ),
            ),
          ),
          GoRoute(
            path: '/podcast/:id',
            builder: (_, state) => navigationScreen(
              FeedDetailPage(feedId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/podcast-preview',
            builder: (_, state) => navigationScreen(switch (state.extra) {
              final PodcastSearchResult podcast => FeedDetailPage.catalog(
                podcast: podcast,
              ),
              _ => const FeedDetailPage.catalog(),
            }),
          ),
          GoRoute(
            path: '/feed/:id',
            builder: (_, state) => navigationScreen(
              FeedDetailPage(feedId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/article/:id',
            builder: (_, state) => navigationScreen(
              ArticlePage(articleId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/episode/:id',
            builder: (_, state) => navigationScreen(
              EpisodePage(episodeId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/queue',
            builder: (_, _) => navigationScreen(const QueuePage()),
          ),
          GoRoute(
            path: '/downloads',
            builder: (_, _) => navigationScreen(const DownloadsPage()),
          ),
          GoRoute(
            path: '/saved',
            builder: (_, state) => navigationScreen(
              SavedPage(
                initialTab: state.uri.queryParameters['tab'] == 'articles'
                    ? 1
                    : 0,
              ),
            ),
          ),
          GoRoute(
            path: '/settings',
            builder: (_, _) => navigationScreen(const SettingsPage()),
          ),
        ],
      ),
      GoRoute(
        path: '/player',
        builder: (_, _) => NavigationGlitch(
          routeObserver: rootNavigationObserver,
          child: const PlayerPage(),
        ),
      ),
    ],
  );
}
