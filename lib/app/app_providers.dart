import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/constants.dart';
import '../data/database/app_database.dart';
import '../data/network/safe_network_client.dart';
import '../data/repositories/article_repository.dart';
import '../data/repositories/feed_repository.dart';
import '../data/repositories/episode_extras_repository.dart';
import '../data/repositories/podcast_search_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/security/private_feed_store.dart';
import '../features/downloads/download_coordinator.dart';
import '../features/player/trickle_audio_handler.dart';
import '../services/backup_service.dart';
import '../services/notification_service.dart';
import '../services/opml_service.dart';
import '../services/sync_coordinator.dart';

Never _uninitialized(String name) =>
    throw StateError('$name was not initialized');

final databaseProvider = Provider<AppDatabase>(
  (ref) => _uninitialized('database'),
);
final networkProvider = Provider<SafeNetworkClient>(
  (ref) => _uninitialized('network'),
);
final feedRepositoryProvider = Provider<FeedRepository>(
  (ref) => _uninitialized('feedRepository'),
);
final podcastSearchProvider = Provider<PodcastSearchRepository>(
  (ref) => _uninitialized('podcastSearch'),
);
final articleRepositoryProvider = Provider<ArticleRepository>(
  (ref) => _uninitialized('articleRepository'),
);
final episodeExtrasProvider = Provider<EpisodeExtrasRepository>(
  (ref) => _uninitialized('episodeExtras'),
);
final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => _uninitialized('settingsRepository'),
);
final privateFeedStoreProvider = Provider<PrivateFeedStore>(
  (ref) => _uninitialized('privateFeedStore'),
);
final audioHandlerProvider = Provider<TrickleAudioHandler>(
  (ref) => _uninitialized('audioHandler'),
);
final downloadCoordinatorProvider = Provider<DownloadCoordinator>(
  (ref) => _uninitialized('downloadCoordinator'),
);
final backupServiceProvider = Provider<BackupService>(
  (ref) => _uninitialized('backupService'),
);
final notificationServiceProvider = Provider<NotificationService>(
  (ref) => _uninitialized('notificationService'),
);
final opmlServiceProvider = Provider<OpmlService>(
  (ref) => _uninitialized('opmlService'),
);
final syncCoordinatorProvider = Provider<SyncCoordinator>(
  (ref) => _uninitialized('syncCoordinator'),
);

final podcastFeedsProvider = StreamProvider<List<Feed>>(
  (ref) => ref.watch(databaseProvider).watchPodcastFeeds(),
);
final readerFeedsProvider = StreamProvider<List<Feed>>(
  (ref) => ref.watch(databaseProvider).watchReaderFeeds(),
);
final recentEpisodesProvider = StreamProvider<List<Episode>>(
  (ref) => ref.watch(databaseProvider).watchRecentEpisodes(),
);
final readerUnreadArticlesProvider = StreamProvider.autoDispose
    .family<List<Article>, int>(
      (ref, limit) =>
          ref.watch(databaseProvider).watchUnreadArticles(limit: limit),
    );
final readerAllArticlesProvider = StreamProvider.autoDispose
    .family<List<Article>, int>(
      (ref, limit) =>
          ref.watch(databaseProvider).watchAllArticles(limit: limit),
    );
final starredArticlesPageProvider = StreamProvider.autoDispose
    .family<List<Article>, int>(
      (ref, limit) =>
          ref.watch(databaseProvider).watchStarredArticles(limit: limit),
    );
final unreadArticleCountProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchUnreadArticleCount(),
);
final articleCountProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchArticleCount(),
);
final starredArticleCountProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchStarredArticleCount(),
);
final starredEpisodeCountProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchStarredEpisodeCount(),
);
final starredEpisodesPageProvider = StreamProvider.autoDispose
    .family<List<Episode>, int>(
      (ref, limit) =>
          ref.watch(databaseProvider).watchStarredEpisodes(limit: limit),
    );
final downloadsProvider = StreamProvider<List<MediaDownload>>(
  (ref) => ref.watch(databaseProvider).watchDownloads(),
);
final episodesForFeedProvider = StreamProvider.autoDispose
    .family<List<Episode>, ({String feedId, int limit})>(
      (ref, page) => ref
          .watch(databaseProvider)
          .watchEpisodesForFeed(page.feedId, limit: page.limit),
    );
final articlesForFeedProvider = StreamProvider.autoDispose
    .family<List<Article>, ({String feedId, int limit})>(
      (ref, page) => ref
          .watch(databaseProvider)
          .watchArticlesForFeed(page.feedId, limit: page.limit),
    );
final episodeCountForFeedProvider = StreamProvider.autoDispose
    .family<int, String>(
      (ref, feedId) =>
          ref.watch(databaseProvider).watchEpisodeCountForFeed(feedId),
    );
final articleCountForFeedProvider = StreamProvider.autoDispose
    .family<int, String>(
      (ref, feedId) =>
          ref.watch(databaseProvider).watchArticleCountForFeed(feedId),
    );
final feedProvider = StreamProvider.autoDispose.family<Feed?, String>(
  (ref, id) => ref.watch(databaseProvider).watchFeedById(id),
);
final privateFeedSecretProvider = FutureProvider.autoDispose
    .family<PrivateFeedSecret?, String>((ref, feedId) async {
      final feed = await ref.watch(databaseProvider).feedById(feedId);
      if (feed?.isPrivate != true) return null;
      return ref
          .watch(privateFeedStoreProvider)
          .read(feed?.credentialRef ?? '');
    });
final episodeProvider = StreamProvider.autoDispose.family<Episode?, String>(
  (ref, id) => ref.watch(databaseProvider).watchEpisodeById(id),
);
final episodeProgressProvider = StreamProvider.autoDispose
    .family<PlaybackProgressesData?, String>(
      (ref, id) =>
          ref.watch(databaseProvider).watchPlaybackProgressForEpisode(id),
    );
final articleProvider = StreamProvider.autoDispose.family<Article?, String>(
  (ref, id) => ref.watch(databaseProvider).watchArticleById(id),
);
final articlePreviewImageProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, id) async {
      final repository = ref.watch(articleRepositoryProvider);
      final lease = repository.retainPreview(id);
      ref.onDispose(lease.cancel);
      final article = await ref.watch(databaseProvider).articleById(id);
      if (article == null) return null;
      return repository.previewImage(article, lease: lease);
    });
final _downloadsByEpisodeProvider = Provider<Map<String, MediaDownload>>((ref) {
  final downloads =
      ref.watch(downloadsProvider).value ?? const <MediaDownload>[];
  return {for (final download in downloads) download.episodeId: download};
});
final downloadForEpisodeProvider = Provider.autoDispose
    .family<MediaDownload?, String>((ref, id) {
      return ref.watch(
        _downloadsByEpisodeProvider.select((downloads) => downloads[id]),
      );
    });
final chaptersProvider = FutureProvider.autoDispose
    .family<List<Chapter>, String>(
      (ref, id) => ref.watch(episodeExtrasProvider).chapters(id),
    );
final transcriptProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, id) => ref.watch(episodeExtrasProvider).transcript(id),
);
final episodeShowNotesProvider = FutureProvider.autoDispose
    .family<ExtractedArticle?, String>((ref, episodeId) async {
      final episode = await ref.watch(databaseProvider).episodeById(episodeId);
      final description = episode?.description?.trim();
      if (description == null || description.isEmpty) return null;
      final feed = await ref.watch(databaseProvider).feedById(episode!.feedId);
      String? baseUrl;
      if (feed?.isPrivate == true) {
        final secret = await ref
            .watch(privateFeedStoreProvider)
            .read(feed?.credentialRef ?? '');
        baseUrl = secret?.url.toString();
      } else {
        baseUrl = feed?.feedUrl;
      }
      return ref
          .watch(articleRepositoryProvider)
          .sanitizeContent(description, baseUrl);
    });
final bookmarksProvider = StreamProvider.autoDispose
    .family<List<Bookmark>, String>(
      (ref, id) => ref.watch(databaseProvider).watchBookmarksForEpisode(id),
    );

final playbackStateProvider = StreamProvider<PlaybackState>(
  (ref) => ref.watch(audioHandlerProvider).playbackState,
);
final currentMediaProvider = StreamProvider<MediaItem?>(
  (ref) => ref.watch(audioHandlerProvider).mediaItem,
);
final queueProvider = StreamProvider<List<MediaItem>>(
  (ref) => ref.watch(audioHandlerProvider).queue,
);
final playbackPositionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(audioHandlerProvider).positionStream,
);
final playbackDurationProvider = StreamProvider<Duration>(
  (ref) => ref.watch(audioHandlerProvider).durationStream,
);
final sleepTimerStatusProvider = StreamProvider<SleepTimerStatus>(
  (ref) => ref.watch(audioHandlerProvider).sleepTimerStatusStream,
);

final speedProvider = StreamProvider<int>(
  (ref) => ref.watch(settingsRepositoryProvider).watchSpeed(),
);
final autoDeleteProvider = StreamProvider<AutoDeletePolicy>(
  (ref) => ref.watch(settingsRepositoryProvider).watchAutoDelete(),
);
final refreshIntervalProvider = StreamProvider<RefreshInterval>(
  (ref) => ref.watch(settingsRepositoryProvider).watchRefreshInterval(),
);
final remoteImagesProvider = StreamProvider<bool>(
  (ref) => ref.watch(settingsRepositoryProvider).watchRemoteImages(),
);
final _connectivityProvider =
    StreamProvider.autoDispose<List<ConnectivityResult>>(
      (ref) => Connectivity().onConnectivityChanged,
    );
typedef SafeImageRequest = ({String url, Map<String, String> headers});

final safeImageFileProvider = FutureProvider.autoDispose
    .family<String?, SafeImageRequest>((ref, request) async {
      // Fresh files render from cache. Expired files refresh through the safe
      // client and remain available as an offline fallback. Cache keys include
      // an auth fingerprint so private artwork cannot bleed across credentials.
      ref.watch(_connectivityProvider);
      final network = ref.watch(networkProvider);
      final headerEntries =
          [
            for (final entry in request.headers.entries)
              (key: entry.key.toLowerCase(), value: entry.value),
          ]..sort((left, right) {
            final keyOrder = left.key.compareTo(right.key);
            return keyOrder != 0 ? keyOrder : left.value.compareTo(right.value);
          });
      final fingerprint = sha256.convert(
        utf8.encode(
          '${request.url}\n${headerEntries.map((entry) => '${entry.key}:${entry.value}').join('\n')}',
        ),
      );
      final cacheKey = 'trickle-safe-image-$fingerprint';
      final cache = DefaultCacheManager();
      String? stalePath;
      try {
        final cached = await cache.getFileFromCache(cacheKey);
        if (cached != null && await cached.file.exists()) {
          if (cached.validTill.isAfter(DateTime.now())) {
            return cached.file.path;
          }
          stalePath = cached.file.path;
        }
      } on Object {
        // Cache failures fall through to a controlled fetch.
      }
      final uri = Uri.tryParse(request.url);
      if (uri == null) return null;
      try {
        final document = await network.get(
          uri,
          headers: request.headers,
          maxBytes: AppConstants.imageLimitBytes,
          totalTimeout: AppConstants.contentRequestTimeout,
        );
        if (document.bytes.isEmpty) return stalePath;
        final contentType = document
            .header('content-type')
            ?.split(';')
            .first
            .trim()
            .toLowerCase();
        if (contentType != null && !contentType.startsWith('image/')) {
          return stalePath;
        }
        final extension = switch (contentType) {
          'image/jpeg' => 'jpg',
          'image/png' => 'png',
          'image/gif' => 'gif',
          'image/webp' => 'webp',
          'image/avif' => 'avif',
          _ => 'img',
        };
        final file = await cache.putFile(
          cacheKey,
          document.bytes,
          key: cacheKey,
          eTag: document.header('etag'),
          maxAge: const Duration(days: 30),
          fileExtension: extension,
        );
        return file.path;
      } on Object {
        if (stalePath != null && await File(stalePath).exists()) {
          return stalePath;
        }
        rethrow;
      }
    });
final packageInfoProvider = FutureProvider<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
);
