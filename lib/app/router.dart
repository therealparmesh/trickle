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
import '../presentation/widgets/cyber_glitch.dart';

GoRouter createRouter() {
  return GoRouter(
    routes: [
      ShellRoute(
        builder: (_, _, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const HomePage()),
          GoRoute(
            path: '/podcasts',
            pageBuilder: (context, state) =>
                _signalPage(context, state, const PodcastsPage()),
          ),
          GoRoute(
            path: '/reader',
            pageBuilder: (context, state) => _signalPage(
              context,
              state,
              ReaderPage(
                initialFeeds: state.uri.queryParameters['tab'] == 'feeds',
                initialFilter: state.uri.queryParameters['filter'] ?? 'unread',
              ),
            ),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (context, state) =>
                _signalPage(context, state, const LibraryPage()),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) => _signalPage(
              context,
              state,
              SearchPage(
                initialCatalog: state.uri.queryParameters['tab'] == 'podcasts',
              ),
            ),
          ),
          GoRoute(
            path: '/podcast/:id',
            pageBuilder: (context, state) => _signalPage(
              context,
              state,
              FeedDetailPage(feedId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/podcast-preview',
            pageBuilder: (context, state) =>
                _signalPage(context, state, switch (state.extra) {
                  final PodcastSearchResult podcast => FeedDetailPage.catalog(
                    podcast: podcast,
                  ),
                  _ => const FeedDetailPage.catalog(),
                }),
          ),
          GoRoute(
            path: '/feed/:id',
            pageBuilder: (context, state) => _signalPage(
              context,
              state,
              FeedDetailPage(feedId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/article/:id',
            builder: (_, state) =>
                ArticlePage(articleId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/episode/:id',
            pageBuilder: (context, state) => _signalPage(
              context,
              state,
              EpisodePage(episodeId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/queue',
            pageBuilder: (context, state) =>
                _signalPage(context, state, const QueuePage()),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (context, state) =>
                _signalPage(context, state, const DownloadsPage()),
          ),
          GoRoute(
            path: '/saved',
            pageBuilder: (context, state) => _signalPage(
              context,
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
            pageBuilder: (context, state) =>
                _signalPage(context, state, const SettingsPage()),
          ),
        ],
      ),
      GoRoute(path: '/player', builder: (_, _) => const PlayerPage()),
    ],
  );
}

Page<void> _signalPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  final motionEnabled = CyberGlitchMotion.isEnabled(context);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: motionEnabled
        ? CyberGlitchMotion.routeDuration
        : Duration.zero,
    reverseTransitionDuration: motionEnabled
        ? CyberGlitchMotion.reverseRouteDuration
        : Duration.zero,
    transitionsBuilder: CyberGlitchMotion.routeTransition,
    child: child,
  );
}
