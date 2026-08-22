import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/constants.dart';
import '../core/content_filters.dart';
import '../data/database/app_database.dart';
import '../data/network/safe_network_client.dart';
import '../data/repositories/article_repository.dart';
import '../data/repositories/feed_repository.dart';
import '../data/repositories/nostr_repository.dart';
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
final nostrRepositoryProvider = Provider<NostrRepository>(
  (ref) => _uninitialized('nostrRepository'),
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

final feedsProvider = StreamProvider<List<Feed>>(
  (ref) => ref.watch(databaseProvider).watchFeeds(),
);
final podcastFeedsProvider = Provider<AsyncValue<List<Feed>>>(
  (ref) => ref
      .watch(feedsProvider)
      .whenData(
        (feeds) => feeds
            .where((feed) => feed.kind == FeedKind.podcast.index)
            .toList(growable: false),
      ),
);
final readerFeedsProvider = Provider<AsyncValue<List<Feed>>>(
  (ref) => ref
      .watch(feedsProvider)
      .whenData(
        (feeds) => feeds
            .where((feed) => feed.kind == FeedKind.reader.index)
            .toList(growable: false),
      ),
);
final _allFeedSnapshotsProvider = StreamProvider<List<Feed>>(
  (ref) => ref.watch(databaseProvider).watchAllFeeds(),
);
final _feedsByIdProvider = Provider<Map<String, Feed>>((ref) {
  final feeds = ref.watch(_allFeedSnapshotsProvider).value ?? const <Feed>[];
  return {for (final feed in feeds) feed.id: feed};
});
final feedSnapshotProvider = Provider.autoDispose.family<Feed?, String>(
  (ref, id) => ref.watch(_feedsByIdProvider.select((feeds) => feeds[id])),
);
final recentEpisodesProvider = StreamProvider<List<Episode>>(
  (ref) => ref.watch(databaseProvider).watchRecentEpisodes(),
);
final newEpisodesProvider = StreamProvider<List<Episode>>(
  (ref) => ref.watch(databaseProvider).watchNewEpisodes(),
);
final inProgressEpisodesProvider = StreamProvider<List<Episode>>(
  (ref) => ref.watch(databaseProvider).watchInProgressEpisodes(),
);
final readerUnreadArticlesProvider = StreamProvider.autoDispose
    .family<List<Article>, int>(
      (ref, limit) =>
          ref.watch(databaseProvider).watchUnreadArticles(limit: limit),
    );
final starredArticlesPageProvider = StreamProvider.autoDispose
    .family<List<Article>, int>(
      (ref, limit) =>
          ref.watch(databaseProvider).watchStarredArticles(limit: limit),
    );
final unreadArticleCountProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).watchUnreadArticleCount(),
);
final unreadArticleCountsByFeedProvider = StreamProvider<Map<String, int>>(
  (ref) => ref.watch(databaseProvider).watchUnreadArticleCountsByFeed(),
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
final downloadedEpisodesProvider = StreamProvider<Map<String, Episode>>(
  (ref) => ref
      .watch(databaseProvider)
      .watchDownloadedEpisodes()
      .map((episodes) => {for (final episode in episodes) episode.id: episode}),
);
final queuedEpisodesProvider = StreamProvider<Map<String, Episode>>(
  (ref) => ref
      .watch(databaseProvider)
      .watchQueuedEpisodes()
      .map((episodes) => {for (final episode in episodes) episode.id: episode}),
);
typedef EpisodeFeedQuery = ({
  String feedId,
  int limit,
  ContentSort sort,
  EpisodeFeedFilter filter,
  String query,
});
final filteredEpisodesForFeedProvider = StreamProvider.autoDispose
    .family<List<Episode>, EpisodeFeedQuery>(
      (ref, value) => ref
          .watch(databaseProvider)
          .watchFilteredEpisodesForFeed(
            feedId: value.feedId,
            limit: value.limit,
            sort: value.sort,
            filter: value.filter,
            query: value.query,
          ),
    );
typedef EpisodeFeedCountQuery = ({
  String feedId,
  EpisodeFeedFilter filter,
  String query,
});
final filteredEpisodeCountForFeedProvider = StreamProvider.autoDispose
    .family<int, EpisodeFeedCountQuery>(
      (ref, value) => ref
          .watch(databaseProvider)
          .watchFilteredEpisodeCountForFeed(
            feedId: value.feedId,
            filter: value.filter,
            query: value.query,
          ),
    );
typedef ArticleListQuery = ({
  String? feedId,
  String? category,
  int limit,
  ContentSort sort,
  ArticleFeedFilter filter,
  String query,
});
final filteredArticlesProvider = StreamProvider.autoDispose
    .family<List<Article>, ArticleListQuery>(
      (ref, value) => ref
          .watch(databaseProvider)
          .watchFilteredArticles(
            feedId: value.feedId,
            category: value.category,
            limit: value.limit,
            sort: value.sort,
            filter: value.filter,
            query: value.query,
          ),
    );
typedef ArticleListCountQuery = ({
  String? feedId,
  String? category,
  ArticleFeedFilter filter,
  String query,
});
final filteredArticleCountProvider = StreamProvider.autoDispose
    .family<int, ArticleListCountQuery>(
      (ref, value) => ref
          .watch(databaseProvider)
          .watchFilteredArticleCount(
            feedId: value.feedId,
            category: value.category,
            filter: value.filter,
            query: value.query,
          ),
    );
final feedProvider = StreamProvider.autoDispose.family<Feed?, String>(
  (ref, id) => ref.watch(databaseProvider).watchFeedById(id),
);
final privateFeedSecretProvider = FutureProvider.autoDispose
    .family<PrivateFeedSecret?, String>((ref, feedId) async {
      final feed = ref.watch(feedSnapshotProvider(feedId));
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
final playbackProgressesProvider =
    StreamProvider<Map<String, PlaybackProgressesData>>(
      (ref) => ref
          .watch(databaseProvider)
          .watchIncompletePlaybackProgresses()
          .map((items) => {for (final item in items) item.episodeId: item}),
    );
final episodeProgressSnapshotProvider = Provider.autoDispose
    .family<PlaybackProgressesData?, String>(
      (ref, id) => ref.watch(
        playbackProgressesProvider.select((items) => items.value?[id]),
      ),
    );
final articleProvider = StreamProvider.autoDispose.family<Article?, String>(
  (ref, id) => ref.watch(databaseProvider).watchArticleById(id),
);
final articleAttachmentsProvider = FutureProvider.autoDispose
    .family<List<ArticleAttachment>, String>((ref, id) {
      ref.watch(articleProvider(id));
      return ref.watch(databaseProvider).attachmentsForArticle(id);
    });
final articlePreviewImageProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, id) async {
      final repository = ref.watch(articleRepositoryProvider);
      final lease = repository.retainPreview(id);
      ref.onDispose(lease.cancel);
      return repository.previewImageById(id, lease: lease);
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
final transcriptProvider = FutureProvider.autoDispose
    .family<TranscriptDocument?, String>(
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
typedef PlaybackUiSnapshot = ({
  String? mediaId,
  bool playing,
  AudioProcessingState? processingState,
});

final playbackUiSnapshotProvider = Provider<PlaybackUiSnapshot>((ref) {
  final mediaId = ref.watch(
    currentMediaProvider.select((media) => media.value?.id),
  );
  final state = ref.watch(
    playbackStateProvider.select(
      (state) => (
        playing: state.value?.playing == true,
        processingState: state.value?.processingState,
      ),
    ),
  );
  return (
    mediaId: mediaId,
    playing: state.playing,
    processingState: state.processingState,
  );
});

typedef PlaybackItemUiSnapshot = ({
  bool isCurrent,
  bool playing,
  AudioProcessingState? processingState,
});

final playbackItemUiSnapshotProvider = Provider.autoDispose
    .family<PlaybackItemUiSnapshot, String>((ref, mediaId) {
      final playback = ref.watch(playbackUiSnapshotProvider);
      final isCurrent = playback.mediaId == mediaId;
      return (
        isCurrent: isCurrent,
        playing: isCurrent && playback.playing,
        processingState: isCurrent ? playback.processingState : null,
      );
    });
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
final readerTextScaleProvider = StreamProvider<int>(
  (ref) => ref.watch(settingsRepositoryProvider).watchReaderTextScale(),
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
