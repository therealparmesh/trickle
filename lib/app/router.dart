import 'package:go_router/go_router.dart';

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
import '../domain/feed_models.dart';

GoRouter createRouter() {
  return GoRouter(
    routes: [
      ShellRoute(
        builder: (_, _, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const HomePage()),
          GoRoute(path: '/podcasts', builder: (_, _) => const PodcastsPage()),
          GoRoute(
            path: '/reader',
            builder: (_, state) => ReaderPage(
              initialFeeds: state.uri.queryParameters['tab'] == 'feeds',
              initialFilter: state.uri.queryParameters['filter'] ?? 'unread',
            ),
          ),
          GoRoute(path: '/library', builder: (_, _) => const LibraryPage()),
          GoRoute(
            path: '/search',
            builder: (_, state) => SearchPage(
              initialCatalog: state.uri.queryParameters['tab'] == 'podcasts',
            ),
          ),
          GoRoute(
            path: '/podcast/:id',
            builder: (_, state) =>
                FeedDetailPage(feedId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/podcast-preview',
            builder: (_, state) => switch (state.extra) {
              final PodcastSearchResult podcast => FeedDetailPage.catalog(
                podcast: podcast,
              ),
              _ => const FeedDetailPage.catalog(),
            },
          ),
          GoRoute(
            path: '/feed/:id',
            builder: (_, state) =>
                FeedDetailPage(feedId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/article/:id',
            builder: (_, state) =>
                ArticlePage(articleId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/episode/:id',
            builder: (_, state) =>
                EpisodePage(episodeId: state.pathParameters['id']!),
          ),
          GoRoute(path: '/queue', builder: (_, _) => const QueuePage()),
          GoRoute(path: '/downloads', builder: (_, _) => const DownloadsPage()),
          GoRoute(
            path: '/saved',
            builder: (_, state) => SavedPage(
              initialTab: state.uri.queryParameters['tab'] == 'articles'
                  ? 1
                  : 0,
            ),
          ),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
        ],
      ),
      GoRoute(path: '/player', builder: (_, _) => const PlayerPage()),
    ],
  );
}
