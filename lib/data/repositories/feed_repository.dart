import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/feed_category.dart';
import '../../core/feed_identity.dart';
import '../../core/formatters.dart';
import '../../core/url_identity.dart';
import '../../core/youtube_support.dart';
import '../../domain/feed_models.dart';
import '../database/app_database.dart';
import '../network/safe_network_client.dart';
import '../parsing/feed_parser.dart';
import '../security/private_feed_store.dart';
import 'nostr_repository.dart';

// Drift stores these timestamps with second precision. Advancing by one full
// stored unit makes concurrent refresh revisions comparable and deterministic.
const _feedRevisionStep = Duration(seconds: 1);
const _maxDiscoveredFeedCandidates = 5;
const _privateAccessChanged = FeedParseException(
  'Private access changed while this request was running. Try again.',
);

final class RefreshAllResult {
  const RefreshAllResult({required this.failedFeeds});

  final int failedFeeds;
}

final class FeedRepository {
  FeedRepository({
    required AppDatabase database,
    required SafeNetworkClient network,
    required PrivateFeedStore privateFeeds,
    NostrRepository? nostr,
  }) : _database = database,
       _network = network,
       _privateFeeds = privateFeeds,
       _nostr = nostr ?? NostrRepository(database: database, network: network);

  final AppDatabase _database;
  final SafeNetworkClient _network;
  final PrivateFeedStore _privateFeeds;
  final NostrRepository _nostr;
  final Uuid _uuid = const Uuid();
  final Map<String, Future<List<String>>> _feedDeletions = {};
  final Map<(String, DateTime), Future<bool>> _refreshes = {};
  final Map<String, Future<void>> _subscriptionWrites = {};
  Future<Map<String, Feed>>? _privateFeedsByIdentity;

  /// Loads and parses a podcast without creating or changing a subscription.
  Future<PodcastPreview> loadPodcastPreview(
    String rawAddress, {
    Duration totalTimeout = AppConstants.feedRefreshTimeout,
  }) async {
    final initial = _network.normalizeHttps(Uri.parse(rawAddress.trim()));
    final resolved = await _resolveFeedDocument(
      initial,
      const <String, String>{},
      totalTimeout,
      kind: FeedKind.podcast,
    );
    final feed = resolved.prepared.feed;
    if (!resolved.prepared.hasPodcastContent) {
      throw const FeedParseException('That address is not a podcast feed.');
    }
    final movedTo = resolved.document.permanentRedirectTarget;
    final url =
        movedTo != null &&
            await _feedByAddress(resolved.refreshUrl, const {}) == null
        ? movedTo
        : resolved.refreshUrl;
    return (feedUrl: url, feed: feed);
  }

  Future<Feed> subscribe(
    String rawAddress, {
    String? username,
    String? password,
    String? bearerToken,
    bool forcePrivate = false,
    FeedKind? expectedKind,
    String? category,
    Duration totalTimeout = AppConstants.feedRefreshTimeout,
  }) async {
    final initial = _network.normalizeHttps(Uri.parse(rawAddress.trim()));
    final headers = _authenticationHeaders(
      username: username,
      password: password,
      bearerToken: bearerToken,
    );
    // Query parameters frequently contain signed-feed credentials. Callers
    // can force the same treatment for credentials embedded in an opaque path.
    final requestedPrivate =
        forcePrivate ||
        headers.isNotEmpty ||
        feedUrlMayContainCredentials(initial);
    final resolved = await _resolveFeedDocument(
      initial,
      headers,
      totalTimeout,
      kind: expectedKind,
    );
    if (expectedKind == FeedKind.podcast &&
        !resolved.prepared.hasPodcastContent) {
      throw const FeedParseException('That address is not a podcast feed.');
    }
    final document = resolved.document;
    final redirectTarget = requestedPrivate
        ? null
        : document.permanentRedirectTarget;
    final identity = _subscriptionIdentity(
      redirectTarget ?? resolved.refreshUrl,
      resolved.refreshHeaders,
    );
    return _serializeSubscription(identity, () async {
      var storedUrl = feedUrlIdentity(
        (redirectTarget ?? resolved.refreshUrl).toString(),
      );
      final atDestination = redirectTarget == null
          ? null
          : await _database.feedByUrl(storedUrl);
      final existing =
          (await _feedByAddress(
            resolved.refreshUrl,
            resolved.refreshHeaders,
          )) ??
          atDestination;
      // Older backups could leave portable token URLs outside secure storage.
      final isPrivate =
          requestedPrivate ||
          existing?.isPrivate == true ||
          feedUrlMayContainCredentials(resolved.refreshUrl);
      var credentialRef = existing?.credentialRef;
      final needsCredential = isPrivate && credentialRef == null;
      if (needsCredential) {
        credentialRef = await _privateFeeds.save(
          PrivateFeedSecret(
            url: resolved.refreshUrl,
            headers: resolved.refreshHeaders,
          ),
        );
      }
      if (isPrivate) storedUrl = 'private://$credentialRef';

      final feedId = existing?.id ?? _uuid.v4();
      try {
        final existingKind = existing == null
            ? null
            : FeedKind.values[existing.kind];
        if (expectedKind != null &&
            existingKind != null &&
            expectedKind != existingKind) {
          throw FeedParseException(
            existingKind == FeedKind.podcast
                ? 'This address is already added as a podcast.'
                : 'This address is already added as a feed.',
          );
        }
        final prepared =
            existingKind != null && existingKind != resolved.prepared.feed.kind
            ? await _prepare(document, kind: existingKind)
            : resolved.prepared;
        await _storeParsedFeed(
          feedId: feedId,
          storedUrl: storedUrl,
          prepared: prepared,
          isPrivate: isPrivate,
          credentialRef: credentialRef,
          document: document,
          requestUrl: resolved.refreshUrl,
          requireExisting: existing != null,
          expectedRevision: isPrivate ? existing?.updatedAt : null,
          initialCategory: normalizeFeedCategory(category),
        );
      } on Object catch (error, stackTrace) {
        if (needsCredential && credentialRef != null) {
          await _deleteCredential(credentialRef);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      final storedFeed = await _database.feedById(feedId);
      if (storedFeed == null) throw const _FeedNoLongerExists();
      if (needsCredential && storedFeed.credentialRef == credentialRef) {
        (await _privateFeedIndex())[identity] = storedFeed;
      }
      return storedFeed;
    });
  }

  Future<Episode> cachePodcastPreviewEpisode({
    required PodcastSearchResult podcast,
    required PodcastPreview preview,
    required ParsedEpisode episode,
  }) => _serializeSubscription(
    _subscriptionIdentity(preview.feedUrl, const {}),
    () async {
      final matched = await _feedByAddress(preview.feedUrl, const {});
      String? newCredential;
      try {
        return await _database.transaction(() async {
          final details = preview.feed;
          final storedUrl = feedUrlIdentity(preview.feedUrl.toString());
          final existingFeed = matched == null
              ? await _database.feedByUrl(storedUrl)
              : await _database.feedById(matched.id);
          if (matched != null &&
              (existingFeed == null ||
                  existingFeed.credentialRef != matched.credentialRef)) {
            throw const _FeedNoLongerExists();
          }
          if (existingFeed != null &&
              _feedDeletions.containsKey(existingFeed.id)) {
            throw const _FeedNoLongerExists();
          }
          if (existingFeed != null &&
              existingFeed.kind != FeedKind.podcast.index) {
            throw const FeedParseException(
              'This address is already added as a feed.',
            );
          }
          final private =
              existingFeed?.isPrivate ??
              (feedUrlMayContainCredentials(preview.feedUrl) ||
                  feedUrlMayContainCredentials(podcast.feedUrl));
          final feedId = existingFeed?.id ?? _uuid.v4();
          final episodeId = stableContentId(feedId, _episodeIdentity(episode));
          final existingEpisode =
              await (_database.select(_database.episodes)
                    ..where(
                      (row) =>
                          row.id.equals(episodeId) |
                          row.refreshId.equals(episodeId),
                    )
                    ..orderBy([(row) => OrderingTerm.asc(row.refreshId)])
                    ..limit(1))
                  .getSingleOrNull();
          if (existingEpisode != null) return existingEpisode;
          final oldId = private ? _legacyEpisodeId(feedId, episode) : null;
          if (oldId != null) {
            final old = await _database.episodeById(oldId);
            final previousUrl = old == null
                ? null
                : await _privateFeeds.readMediaUrl(oldId);
            if (old != null &&
                _matchesLegacyEpisode(old, previousUrl, episode)) {
              return old;
            }
          }
          final now = DateTime.now().toUtc();
          if (existingFeed == null) {
            if (private) {
              newCredential = await _privateFeeds.save(
                PrivateFeedSecret(url: Uri.parse(storedUrl), headers: const {}),
              );
            }
            await _database
                .into(_database.feeds)
                .insert(
                  FeedsCompanion.insert(
                    id: feedId,
                    title: details.title,
                    description: Value(details.description),
                    feedUrl: private ? 'private://$newCredential' : storedUrl,
                    siteUrl: Value(details.siteUrl?.toString()),
                    imageUrl: Value(
                      (details.imageUrl ?? podcast.artworkUrl)?.toString(),
                    ),
                    author: Value(details.author ?? podcast.author),
                    category: const Value(null),
                    kind: Value(FeedKind.podcast.index),
                    protocol: Value(FeedProtocol.syndication.index),
                    subscribed: const Value(false),
                    isPrivate: Value(private),
                    credentialRef: Value(newCredential),
                    createdAt: now,
                    updatedAt: now,
                  ),
                );
          }
          final cached = await _database
              .into(_database.episodes)
              .insertReturning(
                EpisodesCompanion.insert(
                  id: episodeId,
                  feedId: feedId,
                  guid: Value(episode.guid),
                  title: episode.title,
                  description: Value(episode.description),
                  enclosureUrl: private
                      ? 'private-media://$episodeId'
                      : episode.enclosureUrl.toString(),
                  mimeType: Value(episode.mimeType),
                  imageUrl: Value(
                    (episode.imageUrl ?? details.imageUrl ?? podcast.artworkUrl)
                        ?.toString(),
                  ),
                  chaptersUrl: Value(episode.chaptersUrl?.toString()),
                  publishedAt: Value(episode.publishedAt),
                  discoveredAt: now,
                  durationMs: Value(episode.duration?.inMilliseconds),
                  fileSize: Value(episode.fileSize),
                  explicit: Value(episode.explicit),
                  automationApplied: const Value(true),
                ),
              );
          if (private) {
            await _writePrivateMedia(feedId, {episodeId: episode.enclosureUrl});
          }
          return cached;
        });
      } on Object {
        if (newCredential case final ref?) await _deleteCredential(ref);
        rethrow;
      } finally {
        if (newCredential != null) invalidatePrivateFeedIndex();
      }
    },
  );

  Future<void> updatePrivateAccess(
    String feedId,
    String rawAddress, {
    String? username,
    String? password,
    String? bearerToken,
    Duration totalTimeout = AppConstants.feedRefreshTimeout,
  }) async {
    final feed = await _database.feedById(feedId);
    if (feed == null || !feed.isPrivate || feed.credentialRef == null) {
      throw const FormatException('This is not a private subscription.');
    }
    final initial = _network.normalizeHttps(Uri.parse(rawAddress.trim()));
    final headers = _authenticationHeaders(
      username: username,
      password: password,
      bearerToken: bearerToken,
    );
    final resolved = await _resolveFeedDocument(
      initial,
      headers,
      totalTimeout,
      kind: FeedKind.values[feed.kind],
    );
    final identity = _subscriptionIdentity(
      resolved.refreshUrl,
      resolved.refreshHeaders,
    );
    return _serializeSubscription(identity, () async {
      final duplicate = await _feedByAddress(
        resolved.refreshUrl,
        resolved.refreshHeaders,
      );
      if (duplicate != null && duplicate.id != feed.id) {
        throw const FeedParseException('This feed is already in your library.');
      }
      final current = await _database.feedById(feed.id);
      if (current == null ||
          !current.subscribed ||
          _feedDeletions.containsKey(feed.id)) {
        throw const _FeedNoLongerExists();
      }
      if (current.credentialRef != feed.credentialRef) {
        throw _privateAccessChanged;
      }
      final secret = PrivateFeedSecret(
        url: resolved.refreshUrl,
        headers: resolved.refreshHeaders,
      );
      // Keep the old credential live until the database switches to the new one.
      final credentialRef = await _privateFeeds.save(secret);
      try {
        await _storeParsedFeed(
          feedId: feed.id,
          storedUrl: 'private://$credentialRef',
          prepared: resolved.prepared,
          isPrivate: true,
          credentialRef: credentialRef,
          document: resolved.document,
          requestUrl: resolved.refreshUrl,
          requireExisting: true,
          requireSubscribed: true,
          expectedCredentialRef: feed.credentialRef,
        );
      } on Object catch (error, stackTrace) {
        await _deleteCredential(credentialRef);
        Error.throwWithStackTrace(error, stackTrace);
      }
      invalidatePrivateFeedIndex();
      await _deleteCredential(feed.credentialRef!);
    });
  }

  Future<bool> refreshFeed(
    Feed requestedFeed, {
    Duration totalTimeout = AppConstants.feedRefreshTimeout,
  }) async {
    final feed = await _database.feedById(requestedFeed.id);
    if (feed == null || !feed.subscribed) return false;
    if (feed.protocol == FeedProtocol.nostr.index) {
      return _nostr.refresh(feed, totalTimeout: totalTimeout);
    }
    final key = (feed.id, feed.updatedAt);
    final active = _refreshes[key];
    if (active != null) return active;
    final refresh = _refreshFeed(feed, totalTimeout: totalTimeout);
    _refreshes[key] = refresh;
    try {
      return await refresh;
    } finally {
      final _ = _refreshes.remove(key);
    }
  }

  Future<bool> _refreshFeed(Feed feed, {required Duration totalTimeout}) async {
    final previousRevision = feed.updatedAt;
    final stopwatch = Stopwatch()..start();
    try {
      Uri url;
      Map<String, String> headers = {};
      if (feed.isPrivate) {
        final secret = await _privateFeeds
            .read(feed.credentialRef ?? '')
            .timeout(totalTimeout);
        if (secret == null) {
          throw const FeedParseException(
            'Private feed credentials are missing.',
          );
        }
        url = secret.url;
        headers = Map<String, String>.of(secret.headers);
      } else {
        url = Uri.parse(feed.feedUrl);
      }
      if (feed.etag != null) headers['If-None-Match'] = feed.etag!;
      if (feed.lastModified != null) {
        headers['If-Modified-Since'] = feed.lastModified!;
      }
      final remaining = totalTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw const NetworkException('The request timed out.');
      }
      final document = await _network.get(
        url,
        headers: headers,
        maxBytes: AppConstants.feedLimitBytes,
        totalTimeout: remaining,
      );
      if (document.statusCode == 304) {
        final now = DateTime.now().toUtc();
        final updated =
            await (_database.update(_database.feeds)..where(
                  (row) =>
                      row.id.equals(feed.id) &
                      row.subscribed.equals(true) &
                      row.updatedAt.equals(previousRevision),
                ))
                .write(
                  FeedsCompanion(
                    lastRefresh: Value(now),
                    refreshError: const Value(null),
                    updatedAt: Value(_nextFeedRevision(now, feed.updatedAt)),
                  ),
                );
        return updated > 0 ||
            (await _database.feedById(feed.id))?.subscribed == true;
      }
      final prepared = await _prepare(
        document,
        kind: FeedKind.values[feed.kind],
      );
      final movedTo = feed.isPrivate ? null : document.permanentRedirectTarget;
      await _storeParsedFeed(
        feedId: feed.id,
        storedUrl: movedTo == null
            ? feed.feedUrl
            : feedUrlIdentity(movedTo.toString()),
        prepared: prepared,
        isPrivate: feed.isPrivate,
        credentialRef: feed.credentialRef,
        document: document,
        requestUrl: url,
        requireExisting: true,
        requireSubscribed: true,
        expectedRevision: previousRevision,
      );
      return true;
    } on _StaleFeedRefresh {
      // A newer refresh or settings write already won. Its state is the result
      // callers should observe, so the obsolete response is a successful no-op.
      return true;
    } on Object catch (error) {
      await _recordRefreshError(
        feed.id,
        error is TimeoutException
            ? 'The request timed out.'
            : friendlyError(error),
        previousRevision: previousRevision,
      );
      return false;
    }
  }

  Future<RefreshAllResult> refreshAll({
    Duration? budget,
    DateTime? dueAt,
    Duration? minimumAge,
    int maxConcurrent = 4,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (maxConcurrent < 1 || maxConcurrent > 4) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent');
    }
    if ((dueAt == null) != (minimumAge == null) ||
        (minimumAge != null && minimumAge <= Duration.zero)) {
      throw ArgumentError('dueAt and a positive minimumAge must be combined.');
    }
    final stopwatch = Stopwatch()..start();
    final query = _database.select(_database.feeds)
      ..where((row) => row.subscribed.equals(true));
    if (dueAt != null) {
      final refreshBefore = dueAt.subtract(minimumAge!);
      query.where(
        (row) =>
            row.lastRefresh.isNull() |
            row.lastRefresh.isSmallerOrEqualValue(refreshBefore) |
            row.lastRefresh.isBiggerThanValue(dueAt),
      );
    }
    query.orderBy([
      (row) => OrderingTerm.asc(row.lastRefresh),
      (row) => OrderingTerm.asc(row.id),
    ]);
    final feeds = await query.get();
    var next = 0;
    var completed = 0;
    var failed = 0;
    onProgress?.call(0, feeds.length);
    Future<void> worker() async {
      while (next < feeds.length) {
        final remaining = budget == null ? null : budget - stopwatch.elapsed;
        if (remaining != null && remaining <= Duration.zero) return;
        final feed = feeds[next++];
        final timeout =
            remaining == null || remaining > AppConstants.feedRefreshTimeout
            ? AppConstants.feedRefreshTimeout
            : remaining;
        try {
          if (!await refreshFeed(feed, totalTimeout: timeout)) failed++;
        } on Object {
          // A feed's storage or refresh failure must not stop the other feeds.
          failed++;
        }
        onProgress?.call(++completed, feeds.length);
      }
    }

    await Future.wait(
      List.generate(maxConcurrent.clamp(0, feeds.length), (_) => worker()),
    );
    return RefreshAllResult(failedFeeds: failed);
  }

  Future<List<String>> deleteFeed(String feedId) async {
    final activeDeletion = _feedDeletions[feedId];
    if (activeDeletion != null) return activeDeletion;
    final deletion = _deleteOrRetainFeed(feedId);
    _feedDeletions[feedId] = deletion;
    try {
      return await deletion;
    } finally {
      unawaited(_feedDeletions.remove(feedId));
    }
  }

  Future<List<String>> _deleteOrRetainFeed(String feedId) async {
    var removedEpisodeIds = const <String>[];
    var isPrivate = false;
    String? deletedCredential;
    await _database.transaction(() async {
      final feed = await _database.feedById(feedId);
      if (feed == null) return;
      isPrivate = feed.isPrivate;
      final episodes = _database.episodes;
      final articles = _database.articles;
      final feedEpisodes = episodes.feedId.equals(feedId);
      final feedArticles = articles.feedId.equals(feedId);
      final removableEpisodes =
          feedEpisodes & _database.episodeHasLibraryState(episodes).not();
      final episodeIds = _database.selectOnly(episodes)
        ..addColumns([episodes.id]);
      removedEpisodeIds = await (episodeIds..where(removableEpisodes))
          .map((row) => row.read(episodes.id)!)
          .get();
      await _database.customStatement(
        "DELETE FROM search_documents WHERE (kind = 'feed' AND entity_id = ?) "
        "OR (kind = 'article' AND entity_id IN "
        '(SELECT id FROM articles WHERE feed_id = ? AND starred = 0))',
        [feedId, feedId],
      );
      if (removedEpisodeIds.isNotEmpty) {
        await _database.customStatement(
          "DELETE FROM search_documents WHERE kind = 'episode' "
          'AND entity_id IN (SELECT value FROM json_each(?))',
          [jsonEncode(removedEpisodeIds)],
        );
        await (_database.delete(
          episodes,
        )..where((_) => removableEpisodes)).go();
      }
      await (_database.delete(
        articles,
      )..where((row) => feedArticles & row.starred.equals(false))).go();
      final hasEpisodes =
          await (_database.selectOnly(episodes)
                ..addColumns([episodes.id])
                ..where(feedEpisodes)
                ..limit(1))
              .getSingleOrNull();
      final hasArticles =
          await (_database.selectOnly(articles)
                ..addColumns([articles.id])
                ..where(feedArticles)
                ..limit(1))
              .getSingleOrNull();
      if (hasEpisodes == null && hasArticles == null) {
        await (_database.delete(
          _database.feeds,
        )..where((row) => row.id.equals(feedId))).go();
        deletedCredential = feed.credentialRef;
        return;
      }
      await (_database.update(
        _database.feeds,
      )..where((row) => row.id.equals(feedId))).write(
        FeedsCompanion(
          subscribed: const Value(false),
          notifications: const Value(false),
          autoDownload: const Value(false),
          autoQueue: const Value(false),
          updatedAt: Value(
            _nextFeedRevision(DateTime.now().toUtc(), feed.updatedAt),
          ),
        ),
      );
    });
    if (isPrivate) {
      for (final episodeId in removedEpisodeIds) {
        try {
          await _privateFeeds.deleteMediaUrl(episodeId);
        } on Object {
          // Secure storage cleanup is best effort after the commit.
        }
      }
      if (deletedCredential case final credential?) {
        invalidatePrivateFeedIndex();
        await _deleteCredential(credential);
      }
    }
    return removedEpisodeIds;
  }

  Future<Feed> resubscribe(Feed feed) async {
    if (feed.subscribed) return feed;
    if (feed.protocol == FeedProtocol.nostr.index) {
      return _nostr.subscribe(feed.feedUrl);
    }
    if (!feed.isPrivate) return subscribe(feed.feedUrl);
    final updated = await _database.transaction(() async {
      final current = await _database.feedById(feed.id);
      if (current == null || _feedDeletions.containsKey(feed.id)) {
        throw const _FeedNoLongerExists();
      }
      if (current.subscribed) return current;
      final now = DateTime.now().toUtc();
      final changed = current.copyWith(
        subscribed: true,
        etag: const Value(null),
        lastModified: const Value(null),
        updatedAt: _nextFeedRevision(now, current.updatedAt),
      );
      await _database.update(_database.feeds).replace(changed);
      return changed;
    });
    await refreshFeed(updated);
    final current = await _database.feedById(feed.id);
    if (current == null || !current.subscribed) {
      throw const _FeedNoLongerExists();
    }
    return current;
  }

  Future<void> markArticleRead(String articleId, {required bool read}) {
    return (_database.update(
      _database.articles,
    )..where((row) => row.id.equals(articleId))).write(
      ArticlesCompanion(readAt: Value(read ? DateTime.now().toUtc() : null)),
    );
  }

  Future<void> markAllArticlesRead({String? feedId, String? category}) async {
    if (feedId != null && category != null) {
      throw ArgumentError('Choose a feed or category, not both.');
    }
    final categoryIdentity = feedCategoryIdentity(category);
    if (category != null && categoryIdentity == null) {
      throw ArgumentError.value(category, 'category', 'Category is empty');
    }
    if (feedId == null && categoryIdentity == null) {
      await _database.customUpdate(
        'UPDATE articles SET read_at = ? WHERE read_at IS NULL '
        'AND EXISTS (SELECT 1 FROM feeds WHERE feeds.id = articles.feed_id '
        'AND feeds.subscribed = 1)',
        variables: [Variable(DateTime.now().toUtc())],
        updates: {_database.articles},
      );
      return;
    }
    if (categoryIdentity != null) {
      await _database.transaction(() async {
        final feeds = _database.feeds;
        final labels =
            await (_database.selectOnly(feeds)
                  ..addColumns([feeds.id, feeds.category])
                  ..where(
                    feeds.subscribed.equals(true) &
                        feeds.kind.equals(FeedKind.reader.index),
                  ))
                .get();
        final ids = [
          for (final row in labels)
            if (matchesFeedCategory(row.read(feeds.category), categoryIdentity))
              row.read(feeds.id)!,
        ];
        if (ids.isEmpty) return;
        await _database.customUpdate(
          'UPDATE articles SET read_at = ? WHERE read_at IS NULL '
          'AND feed_id IN (SELECT value FROM json_each(?))',
          variables: [
            Variable(DateTime.now().toUtc()),
            Variable(jsonEncode(ids)),
          ],
          updates: {_database.articles},
        );
      });
      return;
    }
    final query = _database.update(_database.articles)
      ..where((row) {
        final unread = row.readAt.isNull();
        return unread & row.feedId.equals(feedId!);
      });
    await query.write(ArticlesCompanion(readAt: Value(DateTime.now().toUtc())));
  }

  Future<void> starEpisode(String episodeId, {required bool starred}) {
    return (_database.update(_database.episodes)
          ..where((row) => row.id.equals(episodeId)))
        .write(EpisodesCompanion(starred: Value(starred)));
  }

  Future<void> updateFeedSettings(
    String feedId, {
    required bool autoDownload,
    required int autoDownloadLimit,
    required bool notifications,
    required int introSkipMs,
    required int outroSkipMs,
    required bool autoQueue,
    required String? category,
  }) async {
    await _database.transaction(() async {
      final current = await _database.feedById(feedId);
      if (current == null) return;
      final normalizedCategory = current.kind == FeedKind.reader.index
          ? normalizeFeedCategory(category)
          : null;
      final downloadLimit = autoDownloadLimit.clamp(1, 10);
      final intro = introSkipMs.clamp(0, 600000);
      final outro = outroSkipMs.clamp(0, 600000);
      if (current.autoDownload == autoDownload &&
          current.autoDownloadLimit == downloadLimit &&
          current.notifications == notifications &&
          current.introSkipMs == intro &&
          current.outroSkipMs == outro &&
          current.autoQueue == autoQueue &&
          current.category == normalizedCategory) {
        return;
      }
      final now = DateTime.now().toUtc();
      await (_database.update(
        _database.feeds,
      )..where((row) => row.id.equals(feedId))).write(
        FeedsCompanion(
          autoDownload: Value(autoDownload),
          autoDownloadLimit: Value(downloadLimit),
          notifications: Value(notifications),
          introSkipMs: Value(intro),
          outroSkipMs: Value(outro),
          autoQueue: Value(autoQueue),
          category: Value(normalizedCategory),
          updatedAt: Value(_nextFeedRevision(now, current.updatedAt)),
        ),
      );
    });
  }

  Future<int> updateFeedCategories(
    Iterable<String> feedIds,
    String? category,
  ) async {
    final ids = feedIds.toSet();
    if (ids.isEmpty) return 0;
    final normalized = normalizeFeedCategory(category);
    return _database.transaction(() async {
      final readerFeeds = await (_database.select(
        _database.feeds,
      )..where((row) => row.kind.equals(FeedKind.reader.index))).get();
      final matchingFeeds = readerFeeds
          .where((feed) => ids.contains(feed.id) && feed.category != normalized)
          .toList(growable: false);
      if (matchingFeeds.isEmpty) return 0;

      final now = DateTime.now().toUtc();
      await _database.batch((batch) {
        for (final feed in matchingFeeds) {
          batch.update(
            _database.feeds,
            FeedsCompanion(
              category: Value(normalized),
              updatedAt: Value(_nextFeedRevision(now, feed.updatedAt)),
            ),
            where: (row) => row.id.equals(feed.id),
          );
        }
      });
      return matchingFeeds.length;
    });
  }

  Future<int> renameFeedCategory(String currentName, String newName) async {
    final currentCategory = normalizeFeedCategory(currentName);
    final renamedCategory = normalizeFeedCategory(newName);
    if (currentCategory == null || renamedCategory == null) return 0;

    return _database.transaction(() async {
      final readerFeeds = await (_database.select(
        _database.feeds,
      )..where((row) => row.kind.equals(FeedKind.reader.index))).get();
      final matchingFeeds = readerFeeds
          .where(
            (feed) =>
                feedCategoryIdentity(feed.category) ==
                feedCategoryIdentity(currentCategory),
          )
          .toList(growable: false);
      if (matchingFeeds.isEmpty ||
          matchingFeeds.every((feed) => feed.category == renamedCategory)) {
        return 0;
      }

      final now = DateTime.now().toUtc();
      await _database.batch((batch) {
        for (final feed in matchingFeeds) {
          batch.update(
            _database.feeds,
            FeedsCompanion(
              category: Value(renamedCategory),
              updatedAt: Value(_nextFeedRevision(now, feed.updatedAt)),
            ),
            where: (row) => row.id.equals(feed.id),
          );
        }
      });
      return matchingFeeds.length;
    });
  }

  Future<_ResolvedFeed> _resolveFeedDocument(
    Uri address,
    Map<String, String> headers,
    Duration totalTimeout, {
    FeedKind? kind,
  }) async {
    final stopwatch = Stopwatch()..start();
    final directYouTubeFeed = directYouTubeFeedUri(address);
    final requestAddress = directYouTubeFeed ?? address;
    final requestHeaders = sameOrigin(address, requestAddress)
        ? headers
        : const <String, String>{};
    final document = await _network.get(
      requestAddress,
      headers: requestHeaders,
      maxBytes: AppConstants.feedLimitBytes,
      totalTimeout: totalTimeout,
    );
    try {
      final prepared = await _prepare(document, kind: kind);
      return _ResolvedFeed(document, requestAddress, requestHeaders, prepared);
    } on FeedParseException {
      final html = html_parser.parse(document.text);
      final urls = html
          .querySelectorAll('link[rel~="alternate"]')
          .where(
            (link) => const {
              'application/rss+xml',
              'application/atom+xml',
              'application/feed+json',
              'application/json',
            }.contains(link.attributes['type']?.toLowerCase()),
          )
          .map((link) => link.attributes['href'])
          .whereType<String>()
          .map(document.url.resolve)
          .where((uri) => uri.scheme == 'https' || uri.scheme == 'http')
          .map(
            (uri) => uri.scheme == 'http' ? uri.replace(scheme: 'https') : uri,
          )
          .toSet();
      final discoveredYouTubeFeed = discoverYouTubeFeedUri(
        document.url,
        document.text,
      );
      if (discoveredYouTubeFeed != null &&
          discoveredYouTubeFeed != requestAddress) {
        urls.add(discoveredYouTubeFeed);
      }
      urls.remove(requestAddress);
      if (urls.isEmpty) {
        throw const FeedParseException(
          'No RSS, Atom, or JSON Feed was found on that page.',
        );
      }
      TrickleException? firstFailure;
      for (final candidate in urls.take(_maxDiscoveredFeedCandidates)) {
        final remaining = totalTimeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) {
          throw const NetworkException('The request timed out.');
        }
        final candidateHeaders = sameOrigin(requestAddress, candidate)
            ? requestHeaders
            : const <String, String>{};
        try {
          final feedDocument = await _network.get(
            candidate,
            headers: candidateHeaders,
            maxBytes: AppConstants.feedLimitBytes,
            totalTimeout: remaining,
          );
          final prepared = await _prepare(feedDocument, kind: kind);
          if (kind == FeedKind.podcast && !prepared.hasPodcastContent) {
            throw const FeedParseException(
              'That address is not a podcast feed.',
            );
          }
          return _ResolvedFeed(
            feedDocument,
            candidate,
            candidateHeaders,
            prepared,
          );
        } on TrickleException catch (error) {
          firstFailure ??= error;
        }
      }
      throw firstFailure!;
    }
  }

  Future<void> _storeParsedFeed({
    required String feedId,
    required String storedUrl,
    required _PreparedFeed prepared,
    required bool isPrivate,
    required String? credentialRef,
    required NetworkDocument document,
    required Uri requestUrl,
    required bool requireExisting,
    bool requireSubscribed = false,
    String? initialCategory,
    DateTime? expectedRevision,
    String? expectedCredentialRef,
  }) async {
    final parsed = prepared.feed;
    final now = DateTime.now().toUtc();
    if (requireExisting && _feedDeletions.containsKey(feedId)) {
      throw const _FeedNoLongerExists();
    }
    final currentFeed = await _database.feedById(feedId);
    if (requireExisting &&
        (currentFeed == null || _feedDeletions.containsKey(feedId))) {
      throw const _FeedNoLongerExists();
    }
    if (requireSubscribed && currentFeed?.subscribed != true) {
      throw const _FeedNoLongerExists();
    }
    if (expectedRevision != null &&
        currentFeed?.updatedAt != expectedRevision) {
      throw const _StaleFeedRefresh();
    }
    final currentKind =
        currentFeed != null &&
            currentFeed.kind >= 0 &&
            currentFeed.kind < FeedKind.values.length
        ? FeedKind.values[currentFeed.kind]
        : null;
    final kind = currentKind ?? parsed.kind;
    final parsedEpisodes = kind == FeedKind.podcast
        ? parsed.episodes
        : const <ParsedEpisode>[];
    final parsedArticles = kind == FeedKind.reader
        ? parsed.articles
        : const <ParsedArticle>[];
    final episodeRefreshIds = [
      for (final episode in parsedEpisodes)
        stableContentId(feedId, _episodeIdentity(episode)),
    ];
    final legacyEpisodeIds = isPrivate
        ? [
            for (final episode in parsedEpisodes)
              _legacyEpisodeId(feedId, episode),
          ]
        : const <String?>[];
    final articleRefreshIds = [
      for (final article in parsedArticles)
        stableContentId(feedId, _articleIdentity(article)),
    ];
    final legacyArticleIds = isPrivate
        ? [
            for (final article in parsedArticles)
              if (article.canonicalUrl == null ||
                  article.guid?.trim().isNotEmpty == true)
                null
              else
                stableContentId(
                  feedId,
                  articleIdentity(
                    guid: null,
                    canonicalUrl: null,
                    publishedAt: article.publishedAt,
                    title: article.title,
                  ),
                ),
          ]
        : const <String?>[];
    await _database.transaction(() async {
      final searchItems = <SearchIndexEntry>[
        SearchIndexEntry(
          entityId: feedId,
          kind: 'feed',
          title: parsed.title,
          body: prepared.feedBody,
          feedTitle: parsed.title,
        ),
      ];
      final feedAtWrite = await _database.feedById(feedId);
      if ((requireExisting &&
              (_feedDeletions.containsKey(feedId) || feedAtWrite == null)) ||
          (requireSubscribed && feedAtWrite?.subscribed != true)) {
        throw const _FeedNoLongerExists();
      }
      if (expectedRevision != null &&
          feedAtWrite?.updatedAt != expectedRevision) {
        throw const _StaleFeedRefresh();
      }
      if (expectedCredentialRef != null &&
          feedAtWrite?.credentialRef != expectedCredentialRef) {
        throw _privateAccessChanged;
      }
      if (!requireExisting &&
          feedAtWrite != null &&
          feedAtWrite.feedUrl != storedUrl) {
        throw const FeedParseException('This feed changed. Try again.');
      }
      if (feedAtWrite != null && feedAtWrite.kind != kind.index) {
        throw FeedParseException(
          feedAtWrite.kind == FeedKind.podcast.index
              ? 'This address is already added as a podcast.'
              : 'This address is already added as a feed.',
        );
      }
      final effectiveFeed = feedAtWrite ?? currentFeed;
      // Don't merge separate library records if both URLs already exist.
      final existingAddress = !isPrivate && storedUrl != effectiveFeed?.feedUrl
          ? await _database.feedByUrl(storedUrl)
          : null;
      final effectiveUrl =
          existingAddress != null && existingAddress.id != feedId
          ? effectiveFeed?.feedUrl ??
                (throw const FeedParseException(
                  'This feed is already in your library.',
                ))
          : storedUrl;
      final validatorUrl = isPrivate
          ? feedUrlIdentity(requestUrl.toString())
          : effectiveUrl;
      final keepValidators =
          validatorUrl == feedUrlIdentity(document.url.toString());
      final updatedAt = effectiveFeed == null
          ? now
          : _nextFeedRevision(now, effectiveFeed.updatedAt);
      final privateMedia = <String, Uri>{};
      if (isPrivate && effectiveFeed?.isPrivate == false) {
        await _moveFeedToPrivateStorage(feedId, kind, privateMedia);
      }
      // Read only incoming IDs, inside the transaction so a concurrent read,
      // save, playback, or preview update is preserved.
      final storedEpisodes = <String, Episode>{};
      final storedArticles = <String, Article>{};
      final incomingIds = kind == FeedKind.podcast
          ? {...episodeRefreshIds, ...legacyEpisodeIds.nonNulls}.toList()
          : {...articleRefreshIds, ...legacyArticleIds.nonNulls}.toList();
      for (
        var start = 0;
        start < incomingIds.length;
        start += AppDatabase.safeVariableBatchSize
      ) {
        final ids = incomingIds.sublist(
          start,
          (start + AppDatabase.safeVariableBatchSize).clamp(
            0,
            incomingIds.length,
          ),
        );
        if (kind == FeedKind.podcast) {
          for (final item
              in await (_database.select(
                    _database.episodes,
                  )..where((row) => row.id.isIn(ids) | row.refreshId.isIn(ids)))
                  .get()) {
            if (item.refreshId case final alias?) {
              storedEpisodes.putIfAbsent(alias, () => item);
            }
            storedEpisodes[item.id] = item;
          }
        } else {
          for (final item
              in await (_database.select(
                    _database.articles,
                  )..where((row) => row.id.isIn(ids) | row.refreshId.isIn(ids)))
                  .get()) {
            if (item.refreshId case final alias?) {
              storedArticles.putIfAbsent(alias, () => item);
            }
            storedArticles[item.id] = item;
          }
        }
      }
      await _database
          .into(_database.feeds)
          .insertOnConflictUpdate(
            FeedsCompanion.insert(
              id: feedId,
              title: parsed.title,
              description: Value(parsed.description),
              feedUrl: effectiveUrl,
              siteUrl: Value(parsed.siteUrl?.toString()),
              imageUrl: Value(
                parsed.imageUrl?.toString() ?? effectiveFeed?.imageUrl,
              ),
              author: Value(parsed.author),
              category: Value(
                kind == FeedKind.reader
                    ? initialCategory ?? effectiveFeed?.category
                    : null,
              ),
              kind: Value(kind.index),
              protocol: Value(
                effectiveFeed?.protocol ?? FeedProtocol.syndication.index,
              ),
              subscribed: const Value(true),
              isPrivate: Value(isPrivate),
              credentialRef: Value(credentialRef),
              etag: Value(keepValidators ? document.header('etag') : null),
              lastModified: Value(
                keepValidators ? document.header('last-modified') : null,
              ),
              lastRefresh: Value(now),
              refreshError: const Value(null),
              autoDownload: Value(effectiveFeed?.autoDownload ?? false),
              autoDownloadLimit: Value(effectiveFeed?.autoDownloadLimit ?? 3),
              notifications: Value(effectiveFeed?.notifications ?? false),
              introSkipMs: Value(effectiveFeed?.introSkipMs ?? 0),
              outroSkipMs: Value(effectiveFeed?.outroSkipMs ?? 0),
              autoQueue: Value(effectiveFeed?.autoQueue ?? false),
              createdAt: effectiveFeed?.createdAt ?? now,
              updatedAt: updatedAt,
            ),
          );
      if (kind == FeedKind.podcast) {
        await _database.customStatement(
          "DELETE FROM search_documents WHERE kind = 'article' AND entity_id "
          'IN (SELECT id FROM articles WHERE feed_id = ?)',
          [feedId],
        );
        await (_database.delete(
          _database.articles,
        )..where((row) => row.feedId.equals(feedId))).go();
      } else {
        await _database.customStatement(
          "DELETE FROM search_documents WHERE kind = 'episode' AND entity_id "
          'IN (SELECT id FROM episodes WHERE feed_id = ?)',
          [feedId],
        );
        await (_database.delete(
          _database.episodes,
        )..where((row) => row.feedId.equals(feedId))).go();
      }

      final legacyMedia = <String, Uri?>{};
      for (
        var episodeIndex = 0;
        episodeIndex < parsedEpisodes.length;
        episodeIndex++
      ) {
        final parsedEpisode = parsedEpisodes[episodeIndex];
        final refreshId = episodeRefreshIds[episodeIndex];
        var existing = storedEpisodes[refreshId];
        final legacyId = isPrivate ? legacyEpisodeIds[episodeIndex] : null;
        if (existing == null && legacyId != null) {
          final legacy = storedEpisodes[legacyId];
          if (legacy != null && legacy.refreshId == null) {
            if (!legacyMedia.containsKey(legacyId)) {
              legacyMedia[legacyId] = await _privateFeeds.readMediaUrl(
                legacyId,
              );
            }
            if (_matchesLegacyEpisode(
              legacy,
              legacyMedia[legacyId],
              parsedEpisode,
            )) {
              existing = legacy;
            }
          }
        }
        final id = existing?.id ?? refreshId;
        if (isPrivate) privateMedia[id] = parsedEpisode.enclosureUrl;
        if (existing != null &&
            existing.chaptersUrl != parsedEpisode.chaptersUrl?.toString()) {
          await (_database.delete(
            _database.chapters,
          )..where((row) => row.episodeId.equals(id))).go();
        }
        final episodeUpdate = EpisodesCompanion.insert(
          id: id,
          refreshId: Value(id == refreshId ? null : refreshId),
          feedId: feedId,
          guid: Value(parsedEpisode.guid),
          title: parsedEpisode.title,
          description: Value(parsedEpisode.description),
          enclosureUrl: isPrivate
              ? 'private-media://$id'
              : parsedEpisode.enclosureUrl.toString(),
          mimeType: Value(parsedEpisode.mimeType),
          imageUrl: Value(parsedEpisode.imageUrl?.toString()),
          chaptersUrl: Value(parsedEpisode.chaptersUrl?.toString()),
          publishedAt: Value(parsedEpisode.publishedAt),
          discoveredAt: existing?.discoveredAt ?? now,
          durationMs: Value(parsedEpisode.duration?.inMilliseconds),
          fileSize: Value(
            (parsedEpisode.fileSize ?? 0) > 0 ? parsedEpisode.fileSize : null,
          ),
          explicit: Value(parsedEpisode.explicit),
          played: Value(existing?.played ?? false),
          starred: Value(existing?.starred ?? false),
          automationApplied: Value(
            existing?.automationApplied ??
                !((effectiveFeed?.autoDownload ?? false) ||
                    (effectiveFeed?.autoQueue ?? false)),
          ),
          queueAutomationApplied: Value(
            existing?.queueAutomationApplied ?? false,
          ),
        );
        if (existing == null ||
            existing.copyWithCompanion(episodeUpdate) != existing) {
          await _database
              .into(_database.episodes)
              .insertOnConflictUpdate(episodeUpdate);
        }
        final transcriptIds = <String>[];
        for (final transcript in parsedEpisode.transcripts) {
          final transcriptId = stableContentId(id, transcript.url.toString());
          transcriptIds.add(transcriptId);
          await _database
              .into(_database.transcripts)
              .insertOnConflictUpdate(
                TranscriptsCompanion.insert(
                  id: transcriptId,
                  episodeId: id,
                  url: transcript.url.toString(),
                  mimeType: Value(transcript.mimeType),
                ),
              );
        }
        final staleTranscripts = _database.delete(_database.transcripts)
          ..where(
            (row) =>
                row.episodeId.equals(id) &
                (transcriptIds.isEmpty
                    ? const Constant(true)
                    : row.id.isNotIn(transcriptIds)),
          );
        await staleTranscripts.go();
        searchItems.add(
          SearchIndexEntry(
            entityId: id,
            kind: 'episode',
            title: parsedEpisode.title,
            body: prepared.episodeBodies[episodeIndex],
            feedTitle: parsed.title,
          ),
        );
      }

      for (
        var articleIndex = 0;
        articleIndex < parsedArticles.length;
        articleIndex++
      ) {
        final parsedArticle = parsedArticles[articleIndex];
        final refreshId = articleRefreshIds[articleIndex];
        var existing = storedArticles[refreshId];
        if (existing == null && isPrivate) {
          final legacy = storedArticles[legacyArticleIds[articleIndex]];
          if (legacy != null &&
              legacy.refreshId == null &&
              _sameArticleLink(
                legacy.canonicalUrl,
                parsedArticle.canonicalUrl,
                isPrivate: true,
              )) {
            existing = legacy;
          }
        }
        final id = existing?.id ?? refreshId;
        final sameLink = _sameArticleLink(
          existing?.canonicalUrl,
          parsedArticle.canonicalUrl,
          isPrivate: isPrivate,
        );
        final articleUpdate = ArticlesCompanion.insert(
          id: id,
          refreshId: Value(id == refreshId ? null : refreshId),
          feedId: feedId,
          guid: Value(parsedArticle.guid),
          title: parsedArticle.title,
          author: Value(parsedArticle.author),
          summary: Value(parsedArticle.summary),
          contentHtml: Value(parsedArticle.contentHtml),
          readerHtml: Value(sameLink ? existing?.readerHtml : null),
          readerFetchedAt: Value(sameLink ? existing?.readerFetchedAt : null),
          canonicalUrl: Value(parsedArticle.canonicalUrl?.toString()),
          imageUrl: Value(
            parsedArticle.imageUrl?.toString() ??
                (sameLink ? existing?.imageUrl : null),
          ),
          publishedAt: Value(parsedArticle.publishedAt),
          discoveredAt: existing?.discoveredAt ?? now,
          readAt: Value(existing?.readAt),
          starred: Value(existing?.starred ?? false),
        );
        if (existing == null ||
            existing.copyWithCompanion(articleUpdate) != existing) {
          await _database
              .into(_database.articles)
              .insertOnConflictUpdate(articleUpdate);
        }
        searchItems.add(
          SearchIndexEntry(
            entityId: id,
            kind: 'article',
            title: parsedArticle.title,
            body: prepared.articleBodies[articleIndex],
            feedTitle: parsed.title,
            preserveBody: articleUpdate.readerHtml.value != null,
          ),
        );
      }
      await _database.indexSearchItems(searchItems);
      if (isPrivate) await _writePrivateMedia(feedId, privateMedia);
    });
  }

  Future<void> _moveFeedToPrivateStorage(
    String feedId,
    FeedKind kind,
    Map<String, Uri> media,
  ) async {
    // Keep row IDs stable for saved state, active playback, and offline files.
    // Only an unambiguous private identity may point at a different row ID.
    final aliases = <String, String?>{};
    void record(String id, String identity) {
      final refreshId = stableContentId(feedId, identity);
      if (aliases.containsKey(refreshId)) {
        aliases[refreshId] = null;
      } else {
        aliases[refreshId] = refreshId == id ? null : id;
      }
    }

    if (kind == FeedKind.podcast) {
      final rows = await _database
          .customSelect(
            'SELECT id, guid, title, enclosure_url, published_at '
            'FROM episodes WHERE feed_id = ?',
            variables: [Variable(feedId)],
          )
          .get();
      for (final row in rows) {
        final id = row.read<String>('id');
        final url = Uri.tryParse(row.read<String>('enclosure_url'));
        if (url == null || url.scheme != 'https' || url.host.isEmpty) continue;
        media[id] = url;
        record(
          id,
          episodeIdentity(
            guid: row.readNullable<String>('guid'),
            enclosureUrl: url,
            publishedAt: row.readNullable<DateTime>('published_at'),
            title: row.read<String>('title'),
          ),
        );
      }
      final refreshIds = {
        for (final MapEntry(key: alias, value: id) in aliases.entries)
          ?id: alias,
      };
      await _database.batch((batch) {
        for (final id in media.keys) {
          batch.update(
            _database.episodes,
            EpisodesCompanion(
              enclosureUrl: Value('private-media://$id'),
              refreshId: Value(refreshIds[id]),
            ),
            where: (row) => row.id.equals(id),
          );
        }
      });
    } else {
      final rows = await _database
          .customSelect(
            'SELECT id, guid, title, canonical_url, published_at '
            'FROM articles WHERE feed_id = ?',
            variables: [Variable(feedId)],
          )
          .get();
      for (final row in rows) {
        record(
          row.read<String>('id'),
          articleIdentity(
            guid: row.readNullable<String>('guid'),
            canonicalUrl: Uri.tryParse(
              row.readNullable<String>('canonical_url') ?? '',
            ),
            publishedAt: row.readNullable<DateTime>('published_at'),
            title: row.read<String>('title'),
          ),
        );
      }
      await _database.batch((batch) {
        for (final MapEntry(key: alias, value: id) in aliases.entries) {
          if (id == null) continue;
          batch.update(
            _database.articles,
            ArticlesCompanion(refreshId: Value(alias)),
            where: (row) => row.id.equals(id),
          );
        }
      });
    }
  }

  Future<void> _writePrivateMedia(String feedId, Map<String, Uri> media) async {
    // The SQLite write transaction already owns the feed revision. Another
    // refresh cannot commit its media or have its URLs reverted by this one.
    final previous = <String, Uri?>{};
    try {
      for (final MapEntry(key: id, value: url) in media.entries) {
        if (_feedDeletions.containsKey(feedId)) {
          throw const _FeedNoLongerExists();
        }
        final stored = await _privateFeeds.readMediaUrl(id);
        if (stored == url) continue;
        previous[id] = stored;
        await _privateFeeds.saveMediaUrl(id, url);
      }
      if (_feedDeletions.containsKey(feedId)) throw const _FeedNoLongerExists();
    } on Object catch (error, stackTrace) {
      for (final MapEntry(key: id, value: url) in previous.entries) {
        try {
          if (url == null) {
            await _privateFeeds.deleteMediaUrl(id);
          } else {
            await _privateFeeds.saveMediaUrl(id, url);
          }
        } on Object {
          // Continue restoring other media entries before rolling back SQLite.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _recordRefreshError(
    String feedId,
    String message, {
    required DateTime previousRevision,
  }) async {
    await (_database.update(_database.feeds)..where(
          (row) =>
              row.id.equals(feedId) &
              row.subscribed.equals(true) &
              row.updatedAt.equals(previousRevision),
        ))
        .write(
          FeedsCompanion(
            lastRefresh: Value(DateTime.now().toUtc()),
            refreshError: Value(message),
          ),
        );
  }

  DateTime _nextFeedRevision(DateTime now, DateTime previous) {
    final nextStoredSecond = previous.add(_feedRevisionStep);
    return now.isAfter(nextStoredSecond) ? now : nextStoredSecond;
  }

  Future<Feed?> _feedByAddress(Uri url, Map<String, String> headers) async {
    if (headers.isEmpty) {
      final publicFeed = await _database.feedByUrl(
        feedUrlIdentity(url.toString()),
      );
      if (publicFeed != null) return publicFeed;
    }
    final indexed =
        (await _privateFeedIndex())[_subscriptionIdentity(url, headers)];
    if (indexed == null) return null;
    final current = await _database.feedById(indexed.id);
    return current?.credentialRef == indexed.credentialRef ? current : null;
  }

  Future<Map<String, Feed>> _privateFeedIndex() async {
    final active = _privateFeedsByIdentity;
    if (active != null) return active;
    final load = _loadPrivateFeedIndex();
    _privateFeedsByIdentity = load;
    try {
      return await load;
    } on Object {
      if (identical(_privateFeedsByIdentity, load)) {
        _privateFeedsByIdentity = null;
      }
      rethrow;
    }
  }

  void invalidatePrivateFeedIndex() => _privateFeedsByIdentity = null;

  Future<Map<String, Feed>> _loadPrivateFeedIndex() async {
    final privateFeeds = await (_database.select(
      _database.feeds,
    )..where((row) => row.isPrivate.equals(true))).get();
    final result = <String, Feed>{};
    for (final feed in privateFeeds) {
      try {
        final secret = await _privateFeeds.read(feed.credentialRef ?? '');
        if (secret == null) continue;
        result.putIfAbsent(
          _subscriptionIdentity(secret.url, secret.headers),
          () => feed,
        );
      } on FormatException {
        // This one subscription can be repaired without hiding the others.
      } on TypeError {
        // Invalid credential records are equivalent to missing credentials.
      }
    }
    return result;
  }

  Future<void> _deleteCredential(String credentialRef) async {
    try {
      await _privateFeeds.delete(credentialRef);
    } on Object {
      // A credential not referenced by a feed is no longer usable by the app.
    }
  }

  Future<T> _serializeSubscription<T>(
    String identity,
    Future<T> Function() operation,
  ) async {
    final previous = _subscriptionWrites[identity];
    final done = Completer<void>();
    _subscriptionWrites[identity] = done.future;
    try {
      await previous;
      return await operation();
    } finally {
      done.complete();
      if (identical(_subscriptionWrites[identity], done.future)) {
        unawaited(_subscriptionWrites.remove(identity));
      }
    }
  }

  String _subscriptionIdentity(Uri url, Map<String, String> headers) {
    final headerEntries = headers.entries.toList()
      ..sort((left, right) {
        final keyOrder = left.key.compareTo(right.key);
        return keyOrder != 0 ? keyOrder : left.value.compareTo(right.value);
      });
    return stableContentId(
      'private-feed',
      jsonEncode([
        feedUrlIdentity(url.toString()),
        for (final entry in headerEntries) [entry.key, entry.value],
      ]),
    );
  }

  Map<String, String> _authenticationHeaders({
    String? username,
    String? password,
    String? bearerToken,
  }) {
    if (username?.isNotEmpty == true) {
      return {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}',
      };
    }
    if (bearerToken?.isNotEmpty == true) {
      return {'Authorization': 'Bearer ${bearerToken!.trim()}'};
    }
    return <String, String>{};
  }

  Future<_PreparedFeed> _prepare(NetworkDocument document, {FeedKind? kind}) {
    return compute(_parseAndPrepareFeed, (
      source: document.text,
      url: document.url.toString(),
      kind: kind,
    ));
  }
}

final class _FeedNoLongerExists implements Exception {
  const _FeedNoLongerExists();
}

final class _StaleFeedRefresh implements Exception {
  const _StaleFeedRefresh();
}

final class _ResolvedFeed {
  const _ResolvedFeed(
    this.document,
    this.refreshUrl,
    this.refreshHeaders,
    this.prepared,
  );

  final NetworkDocument document;
  final Uri refreshUrl;
  final Map<String, String> refreshHeaders;
  final _PreparedFeed prepared;
}

final class _PreparedFeed {
  const _PreparedFeed({
    required this.feed,
    required this.feedBody,
    required this.episodeBodies,
    required this.articleBodies,
  });

  final ParsedFeed feed;
  final String feedBody;
  final List<String> episodeBodies;
  final List<String> articleBodies;

  bool get hasPodcastContent =>
      feed.episodes.isNotEmpty || feed.hasPodcastMetadata;
}

_PreparedFeed _parseAndPrepareFeed(
  ({String source, String url, FeedKind? kind}) input,
) {
  final feed = const FeedParser().parse(
    input.source,
    Uri.parse(input.url),
    kind: input.kind,
  );
  return _PreparedFeed(
    feed: feed,
    feedBody: '${feed.author ?? ''} ${plainText(feed.description)}',
    episodeBodies: [
      for (final episode in feed.episodes) plainText(episode.description),
    ],
    articleBodies: [
      for (final article in feed.articles)
        '${article.author ?? ''} ${plainText(article.contentHtml ?? article.summary)}',
    ],
  );
}

String _episodeIdentity(ParsedEpisode episode) => episodeIdentity(
  guid: episode.guid,
  enclosureUrl: episode.enclosureUrl,
  publishedAt: episode.publishedAt,
  title: episode.title,
);

String? _legacyEpisodeId(String feedId, ParsedEpisode episode) =>
    episode.guid?.trim().isNotEmpty == true
    ? null
    : stableContentId(
        feedId,
        legacyPrivateEpisodeIdentity(
          enclosureUrl: episode.enclosureUrl,
          publishedAt: episode.publishedAt,
          title: episode.title,
        ),
      );

bool _matchesLegacyEpisode(
  Episode row,
  Uri? storedUrl,
  ParsedEpisode incoming,
) =>
    row.refreshId == null &&
    storedUrl != null &&
    credentialAgnosticUrl(storedUrl) ==
        credentialAgnosticUrl(incoming.enclosureUrl);

String _articleIdentity(ParsedArticle article) => articleIdentity(
  guid: article.guid,
  canonicalUrl: article.canonicalUrl,
  publishedAt: article.publishedAt,
  title: article.title,
);

bool _sameArticleLink(
  String? previous,
  Uri? current, {
  required bool isPrivate,
}) {
  if (previous == current?.toString()) return true;
  if (!isPrivate || previous == null || current == null) return false;
  final old = Uri.tryParse(previous);
  return old != null &&
      credentialAgnosticUrl(old) == credentialAgnosticUrl(current);
}
