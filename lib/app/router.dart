import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/feed_models.dart';
import '../presentation/app_shell.dart';
import '../presentation/pages/article_page.dart';
import '../presentation/pages/downloads_page.dart';
import '../presentation/pages/episode_page.dart';
import '../presentation/pages/home_page.dart';
import '../presentation/pages/player_page.dart';
import '../presentation/pages/feed_detail_page.dart';
import '../presentation/pages/podcasts_page.dart';
import '../presentation/pages/queue_page.dart';
import '../presentation/pages/reader_page.dart';
import '../presentation/pages/saved_page.dart';
import '../presentation/pages/search_page.dart';
import '../presentation/pages/settings_page.dart';
import '../presentation/widgets/navigation_glitch.dart';

GoRouter createRouter({
  GlobalKey<NavigatorState>? navigatorKey,
  Random? random,
}) {
  final navigationRandom = random ?? Random();
  Page<void> navigationPage(GoRouterState state, Widget child) {
    return MaterialPage<void>(
      key: state.pageKey,
      allowSnapshotting: false,
      child: NavigationGlitch(random: navigationRandom, child: child),
    );
  }

  return GoRouter(
    navigatorKey: navigatorKey,
    routes: [
      ShellRoute(
        builder: (context, _, child) => NavigationGlitchScope(
          route: ModalRoute.of(context),
          isCurrent: ModalRoute.isCurrentOf(context) != false,
          child: AppShell(child: child),
        ),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (_, state) => navigationPage(state, const HomePage()),
          ),
          GoRoute(
            path: '/podcasts',
            pageBuilder: (_, state) => navigationPage(
              state,
              PodcastsPage(
                initialPodcasts: state.uri.queryParameters['tab'] == 'podcasts',
              ),
            ),
          ),
          GoRoute(
            path: '/reader',
            pageBuilder: (_, state) => navigationPage(
              state,
              ReaderPage(
                initialFeeds: state.uri.queryParameters['tab'] == 'feeds',
                initialFilter: state.uri.queryParameters['filter'] ?? 'unread',
              ),
            ),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (_, state) =>
                navigationPage(state, const SearchPage()),
          ),
          GoRoute(
            path: '/podcast-search',
            pageBuilder: (_, state) =>
                navigationPage(state, const SearchPage.catalog()),
          ),
          GoRoute(
            path: '/podcast-preview',
            pageBuilder: (_, state) =>
                navigationPage(state, switch (state.extra) {
                  final PodcastSearchResult podcast => FeedDetailPage.catalog(
                    podcast: podcast,
                  ),
                  _ => const FeedDetailPage.catalog(),
                }),
          ),
          GoRoute(
            path: '/feed/:id',
            pageBuilder: (_, state) => navigationPage(
              state,
              FeedDetailPage(feedId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/article/:id',
            pageBuilder: (_, state) => navigationPage(
              state,
              ArticlePage(articleId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/episode/:id',
            pageBuilder: (_, state) => navigationPage(
              state,
              EpisodePage(episodeId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/queue',
            pageBuilder: (_, state) => navigationPage(state, const QueuePage()),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (_, state) =>
                navigationPage(state, const DownloadsPage()),
          ),
          GoRoute(
            path: '/saved',
            pageBuilder: (_, state) => navigationPage(
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
            pageBuilder: (_, state) =>
                navigationPage(state, const SettingsPage()),
          ),
        ],
      ),
      GoRoute(
        path: '/player',
        pageBuilder: (_, state) => navigationPage(state, const PlayerPage()),
      ),
    ],
  );
}
