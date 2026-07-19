import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/feed_identity.dart';
import '../../core/url_identity.dart';
import '../../domain/feed_models.dart';
import '../database/app_database.dart';
import '../network/safe_network_client.dart';
import '../parsing/feed_parser.dart';
import '../security/private_feed_store.dart';

final class RefreshAllResult {
  const RefreshAllResult({required this.failedFeeds});

  final int failedFeeds;
}

final class FeedRepository {
  FeedRepository({
    required AppDatabase database,
    required SafeNetworkClient network,
    required PrivateFeedStore privateFeeds,
  }) : _database = database,
       _network = network,
       _privateFeeds = privateFeeds;

  final AppDatabase _database;
  final SafeNetworkClient _network;
  final PrivateFeedStore _privateFeeds;
  final Uuid _uuid = const Uuid();
  final Map<String, Completer<bool>> _feedDeletions = {};

  Future<Feed> subscribe(
    String rawAddress, {
    String? username,
    String? password,
    String? bearerToken,
    bool forcePrivate = false,
    Duration totalTimeout = const Duration(seconds: 120),
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
        forcePrivate || headers.isNotEmpty || initial.hasQuery;
    final resolved = await _resolveFeedDocument(initial, headers, totalTimeout);
    final document = resolved.document;
    // A public-looking discovery URL can redirect to a signed refresh URL.
    // Keep that query-bearing URL in secure storage too.
    final isPrivate = requestedPrivate || resolved.refreshUrl.hasQuery;

    Feed? existing;
    String? credentialRef;
    PrivateFeedSecret? previousSecret;
    // Keep the stable address the user entered (or the feed URL discovered in
    // that page), not a transient redirect target such as a signed CDN URL.
    var storedUrl = resolved.refreshUrl.toString();
    if (isPrivate) {
      existing = await _privateFeedBySecret(
        resolved.refreshUrl,
        resolved.refreshHeaders,
      );
      final existingCredentialRef = existing?.credentialRef;
      if (existingCredentialRef != null) {
        previousSecret = await _privateFeeds.read(existingCredentialRef);
      }
      credentialRef = await _privateFeeds.save(
        PrivateFeedSecret(
          url: resolved.refreshUrl,
          headers: resolved.refreshHeaders,
        ),
        existingId: existing?.credentialRef,
      );
      storedUrl = 'private://$credentialRef';
    } else {
      existing = await _database.feedByUrl(storedUrl);
    }

    final feedId = existing?.id ?? _uuid.v4();
    try {
      await _storeParsedFeed(
        feedId: feedId,
        storedUrl: storedUrl,
        prepared: resolved.prepared,
        isPrivate: isPrivate,
        credentialRef: credentialRef,
        document: document,
        requireExisting: false,
      );
    } on Object {
      if (credentialRef != null) {
        if (previousSecret != null) {
          await _privateFeeds.save(previousSecret, existingId: credentialRef);
        } else {
          await _privateFeeds.delete(credentialRef);
        }
      }
      rethrow;
    }
    return (await _database.feedById(feedId))!;
  }

  Future<void> updatePrivateAccess(
    String feedId,
    String rawAddress, {
    String? username,
    String? password,
    String? bearerToken,
    Duration totalTimeout = const Duration(seconds: 120),
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
    final resolved = await _resolveFeedDocument(initial, headers, totalTimeout);
    final previousSecret = await _privateFeeds.read(feed.credentialRef!);
    try {
      await _privateFeeds.save(
        PrivateFeedSecret(
          url: resolved.refreshUrl,
          headers: resolved.refreshHeaders,
        ),
        existingId: feed.credentialRef,
      );
      await _storeParsedFeed(
        feedId: feed.id,
        storedUrl: feed.feedUrl,
        prepared: resolved.prepared,
        isPrivate: true,
        credentialRef: feed.credentialRef,
        document: resolved.document,
        requireExisting: true,
      );
    } on Object catch (error, stackTrace) {
      try {
        final currentFeed = await _feedAfterDeletionSettles(feed.id);
        final feedStillExists =
            currentFeed?.credentialRef == feed.credentialRef;
        if (feedStillExists && previousSecret != null) {
          await _privateFeeds.save(
            previousSecret,
            existingId: feed.credentialRef,
          );
        } else {
          await _privateFeeds.delete(feed.credentialRef!);
        }

        // Deletion can race the restore above. A second check closes the only
        // window where this update could recreate a deleted feed's secret.
        final latestFeed = await _feedAfterDeletionSettles(feed.id);
        if (latestFeed?.credentialRef != feed.credentialRef) {
          await _privateFeeds.delete(feed.credentialRef!);
        }
      } on Object {
        // Preserve the database failure that caused the rollback.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<bool> refreshFeed(
    Feed feed, {
    Duration totalTimeout = const Duration(seconds: 120),
  }) async {
    Uri url;
    Map<String, String> headers = {};
    if (feed.isPrivate) {
      final secret = await _privateFeeds.read(feed.credentialRef ?? '');
      if (secret == null) {
        await _recordRefreshError(
          feed.id,
          'Private feed credentials are missing.',
        );
        return false;
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
    try {
      final document = await _network.get(
        url,
        headers: headers,
        maxBytes: AppConstants.feedLimitBytes,
        totalTimeout: totalTimeout,
      );
      if (document.statusCode == 304) {
        await (_database.update(
          _database.feeds,
        )..where((row) => row.id.equals(feed.id))).write(
          FeedsCompanion(
            lastRefresh: Value(DateTime.now().toUtc()),
            refreshError: const Value(null),
          ),
        );
        return true;
      }
      final prepared = await _prepare(document);
      await _storeParsedFeed(
        feedId: feed.id,
        storedUrl: feed.feedUrl,
        prepared: prepared,
        isPrivate: feed.isPrivate,
        credentialRef: feed.credentialRef,
        document: document,
        requireExisting: true,
      );
      return true;
    } on Object catch (error) {
      await _recordRefreshError(feed.id, friendlyError(error));
      return false;
    }
  }

  Future<RefreshAllResult> refreshAll({
    Duration? budget,
    int maxConcurrent = 4,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (maxConcurrent < 1 || maxConcurrent > 4) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent');
    }
    final feeds = await (_database.select(
      _database.feeds,
    )..orderBy([(row) => OrderingTerm.asc(row.lastRefresh)])).get();
    final stopwatch = Stopwatch()..start();
    var failed = 0;
    onProgress?.call(0, feeds.length);
    for (var offset = 0; offset < feeds.length; offset += maxConcurrent) {
      final remaining = budget == null ? null : budget - stopwatch.elapsed;
      if (remaining != null && remaining <= Duration.zero) {
        return RefreshAllResult(failedFeeds: failed);
      }
      final end = (offset + maxConcurrent).clamp(0, feeds.length);
      final perFeedTimeout =
          remaining == null || remaining > AppConstants.feedRefreshTimeout
          ? AppConstants.feedRefreshTimeout
          : remaining;
      final outcomes = await Future.wait(
        feeds
            .sublist(offset, end)
            .map((feed) => refreshFeed(feed, totalTimeout: perFeedTimeout)),
      );
      failed += outcomes.where((success) => !success).length;
      onProgress?.call(end, feeds.length);
    }
    return RefreshAllResult(failedFeeds: failed);
  }

  Future<void> deleteFeed(String feedId) async {
    final activeDeletion = _feedDeletions[feedId];
    if (activeDeletion != null) {
      if (!await activeDeletion.future) {
        throw StateError('The active subscription deletion failed.');
      }
      return;
    }
    final deletion = Completer<bool>();
    _feedDeletions[feedId] = deletion;
    try {
      final feed = await _database.feedById(feedId);
      final episodeIds =
          await (_database.selectOnly(_database.episodes)
                ..addColumns([_database.episodes.id])
                ..where(_database.episodes.feedId.equals(feedId)))
              .map((row) => row.read(_database.episodes.id)!)
              .get();
      final downloads =
          await (_database.select(_database.mediaDownloads).join([
                innerJoin(
                  _database.episodes,
                  _database.episodes.id.equalsExp(
                    _database.mediaDownloads.episodeId,
                  ),
                ),
              ])..where(_database.episodes.feedId.equals(feedId)))
              .map((row) => row.readTable(_database.mediaDownloads))
              .get();
      await _database.transaction(() async {
        await _database.customStatement(
          'DELETE FROM search_index WHERE entity_id = ? '
          'OR entity_id IN (SELECT id FROM episodes WHERE feed_id = ?) '
          'OR entity_id IN (SELECT id FROM articles WHERE feed_id = ?)',
          [feedId, feedId, feedId],
        );
        // Child rows use ON DELETE CASCADE.
        await (_database.delete(
          _database.feeds,
        )..where((row) => row.id.equals(feedId))).go();
      });
      deletion.complete(true);
      // External cleanup happens only after the database commit. If the
      // transaction fails, the subscription and all credentials remain usable.
      for (final download in downloads) {
        final path = download.filePath;
        if (path == null) continue;
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on Object {
          // The database is authoritative; an inaccessible orphan is harmless
          // and can be reclaimed by the operating system with app storage.
        }
      }
      for (final episodeId in episodeIds) {
        try {
          await _privateFeeds.deleteMediaUrl(episodeId);
        } on Object {
          // Continue removing the remaining external entries.
        }
      }
      if (feed?.credentialRef != null) {
        try {
          await _privateFeeds.delete(feed!.credentialRef!);
        } on Object {
          // The orphan is no longer addressable by application data.
        }
      }
    } on Object {
      if (!deletion.isCompleted) deletion.complete(false);
      rethrow;
    } finally {
      if (!deletion.isCompleted) deletion.complete(false);
      if (identical(_feedDeletions[feedId], deletion)) {
        _feedDeletions.remove(feedId);
      }
    }
  }

  Future<void> markArticleRead(String articleId, {required bool read}) {
    return (_database.update(
      _database.articles,
    )..where((row) => row.id.equals(articleId))).write(
      ArticlesCompanion(readAt: Value(read ? DateTime.now().toUtc() : null)),
    );
  }

  Future<void> markAllArticlesRead({String? feedId}) {
    final query = _database.update(_database.articles)
      ..where((row) {
        final unread = row.readAt.isNull();
        return feedId == null ? unread : unread & row.feedId.equals(feedId);
      });
    return query.write(
      ArticlesCompanion(readAt: Value(DateTime.now().toUtc())),
    );
  }

  Future<void> starArticle(String articleId, {required bool starred}) {
    return (_database.update(_database.articles)
          ..where((row) => row.id.equals(articleId)))
        .write(ArticlesCompanion(starred: Value(starred)));
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
  }) {
    return (_database.update(
      _database.feeds,
    )..where((row) => row.id.equals(feedId))).write(
      FeedsCompanion(
        autoDownload: Value(autoDownload),
        autoDownloadLimit: Value(autoDownloadLimit.clamp(1, 10)),
        notifications: Value(notifications),
        introSkipMs: Value(introSkipMs.clamp(0, 600000)),
        outroSkipMs: Value(outroSkipMs.clamp(0, 600000)),
        autoQueue: Value(autoQueue),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<_ResolvedFeed> _resolveFeedDocument(
    Uri address,
    Map<String, String> headers,
    Duration totalTimeout,
  ) async {
    final stopwatch = Stopwatch()..start();
    final document = await _network.get(
      address,
      headers: headers,
      maxBytes: AppConstants.feedLimitBytes,
      totalTimeout: totalTimeout,
    );
    try {
      final prepared = await _prepare(document);
      return _ResolvedFeed(document, address, headers, prepared);
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
          .toSet()
          .toList();
      if (urls.isEmpty) {
        throw const FeedParseException(
          'No RSS, Atom, or JSON Feed was found on that page.',
        );
      }
      final remaining = totalTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw const NetworkException('The request timed out.');
      }
      final selected = urls.first;
      final selectedHeaders = sameOrigin(address, selected)
          ? headers
          : const <String, String>{};
      final feedDocument = await _network.get(
        selected,
        headers: selectedHeaders,
        maxBytes: AppConstants.feedLimitBytes,
        totalTimeout: remaining,
      );
      final prepared = await _prepare(feedDocument);
      return _ResolvedFeed(feedDocument, selected, selectedHeaders, prepared);
    }
  }

  Future<void> _storeParsedFeed({
    required String feedId,
    required String storedUrl,
    required _PreparedFeed prepared,
    required bool isPrivate,
    required String? credentialRef,
    required NetworkDocument document,
    required bool requireExisting,
  }) async {
    final parsed = prepared.feed;
    final now = DateTime.now().toUtc();
    final currentFeed = await _database.feedById(feedId);
    if (requireExisting &&
        (currentFeed == null || _feedDeletions.containsKey(feedId))) {
      throw const _FeedNoLongerExists();
    }
    final currentEpisodes = {
      for (final episode in await (_database.select(
        _database.episodes,
      )..where((row) => row.feedId.equals(feedId))).get())
        episode.id: episode,
    };
    final currentArticles = {
      for (final article in await (_database.select(
        _database.articles,
      )..where((row) => row.feedId.equals(feedId))).get())
        article.id: article,
    };
    final previousPrivateMedia = <String, Uri?>{};

    try {
      if (isPrivate) {
        for (final episode in parsed.episodes) {
          if (_feedDeletions.containsKey(feedId)) {
            throw const _FeedNoLongerExists();
          }
          final identity = _episodeIdentity(episode, isPrivate: true);
          final id = stableContentId(feedId, identity);
          if (!previousPrivateMedia.containsKey(id)) {
            previousPrivateMedia[id] = await _privateFeeds.readMediaUrl(id);
          }
          await _privateFeeds.saveMediaUrl(id, episode.enclosureUrl);
        }
      }
      await _database.transaction(() async {
        if (requireExisting &&
            (_feedDeletions.containsKey(feedId) ||
                await _database.feedById(feedId) == null)) {
          throw const _FeedNoLongerExists();
        }
        await _database
            .into(_database.feeds)
            .insertOnConflictUpdate(
              FeedsCompanion.insert(
                id: feedId,
                title: parsed.title,
                description: Value(parsed.description),
                feedUrl: storedUrl,
                siteUrl: Value(parsed.siteUrl?.toString()),
                imageUrl: Value(parsed.imageUrl?.toString()),
                author: Value(parsed.author),
                kind: Value(parsed.kind.index),
                isPrivate: Value(isPrivate),
                credentialRef: Value(credentialRef),
                etag: Value(document.header('etag')),
                lastModified: Value(document.header('last-modified')),
                lastRefresh: Value(now),
                refreshError: const Value(null),
                autoDownload: Value(currentFeed?.autoDownload ?? false),
                autoDownloadLimit: Value(currentFeed?.autoDownloadLimit ?? 3),
                notifications: Value(currentFeed?.notifications ?? false),
                introSkipMs: Value(currentFeed?.introSkipMs ?? 0),
                outroSkipMs: Value(currentFeed?.outroSkipMs ?? 0),
                autoQueue: Value(currentFeed?.autoQueue ?? false),
                createdAt: currentFeed?.createdAt ?? now,
                updatedAt: now,
              ),
            );
        await _database.indexSearchItem(
          entityId: feedId,
          kind: 'feed',
          title: parsed.title,
          body: prepared.feedBody,
          feedTitle: parsed.title,
        );

        for (
          var episodeIndex = 0;
          episodeIndex < parsed.episodes.length;
          episodeIndex++
        ) {
          final parsedEpisode = parsed.episodes[episodeIndex];
          final identity = _episodeIdentity(
            parsedEpisode,
            isPrivate: isPrivate,
          );
          final id = stableContentId(feedId, identity);
          final existing = currentEpisodes[id];
          if (existing != null &&
              existing.chaptersUrl != parsedEpisode.chaptersUrl?.toString()) {
            await (_database.delete(
              _database.chapters,
            )..where((row) => row.episodeId.equals(id))).go();
          }
          await _database
              .into(_database.episodes)
              .insertOnConflictUpdate(
                EpisodesCompanion.insert(
                  id: id,
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
                    (parsedEpisode.fileSize ?? 0) > 0
                        ? parsedEpisode.fileSize
                        : null,
                  ),
                  explicit: Value(parsedEpisode.explicit),
                  played: Value(existing?.played ?? false),
                  starred: Value(existing?.starred ?? false),
                  automationApplied: Value(
                    existing?.automationApplied ??
                        !((currentFeed?.autoDownload ?? false) ||
                            (currentFeed?.autoQueue ?? false)),
                  ),
                ),
              );
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
          await _database.indexSearchItem(
            entityId: id,
            kind: 'episode',
            title: parsedEpisode.title,
            body: prepared.episodeBodies[episodeIndex],
            feedTitle: parsed.title,
          );
        }

        for (
          var articleIndex = 0;
          articleIndex < parsed.articles.length;
          articleIndex++
        ) {
          final parsedArticle = parsed.articles[articleIndex];
          final identity = _articleIdentity(
            parsedArticle,
            isPrivate: isPrivate,
          );
          final id = stableContentId(feedId, identity);
          final existing = currentArticles[id];
          await _database
              .into(_database.articles)
              .insertOnConflictUpdate(
                ArticlesCompanion.insert(
                  id: id,
                  feedId: feedId,
                  guid: Value(parsedArticle.guid),
                  title: parsedArticle.title,
                  author: Value(parsedArticle.author),
                  summary: Value(parsedArticle.summary),
                  contentHtml: Value(
                    existing?.canonicalUrl ==
                                parsedArticle.canonicalUrl?.toString() &&
                            (existing?.contentHtml?.length ?? 0) >
                                (parsedArticle.contentHtml?.length ?? 0)
                        ? existing?.contentHtml
                        : parsedArticle.contentHtml,
                  ),
                  canonicalUrl: Value(parsedArticle.canonicalUrl?.toString()),
                  imageUrl: Value(
                    parsedArticle.imageUrl?.toString() ??
                        (existing?.canonicalUrl ==
                                parsedArticle.canonicalUrl?.toString()
                            ? existing?.imageUrl
                            : null),
                  ),
                  publishedAt: Value(parsedArticle.publishedAt),
                  discoveredAt: existing?.discoveredAt ?? now,
                  readAt: Value(existing?.readAt),
                  starred: Value(existing?.starred ?? false),
                ),
              );
          await _database.indexSearchItem(
            entityId: id,
            kind: 'article',
            title: parsedArticle.title,
            body: prepared.articleBodies[articleIndex],
            feedTitle: parsed.title,
          );
        }
      });
    } on Object catch (error, stackTrace) {
      var feedStillExists = true;
      if (requireExisting) {
        try {
          feedStillExists = await _feedAfterDeletionSettles(feedId) != null;
        } on Object {
          // If the database cannot confirm deletion, retaining the previous
          // secret is safer than erasing access for a feed that may remain.
        }
      }
      for (final entry in previousPrivateMedia.entries) {
        try {
          final previous = entry.value;
          if (feedStillExists && previous != null) {
            await _privateFeeds.saveMediaUrl(entry.key, previous);
          } else {
            await _privateFeeds.deleteMediaUrl(entry.key);
          }
        } on Object {
          // Continue restoring other secure-storage entries.
        }
      }
      if (requireExisting && feedStillExists) {
        try {
          final latestFeed = await _feedAfterDeletionSettles(feedId);
          if (latestFeed == null) {
            for (final episodeId in previousPrivateMedia.keys) {
              try {
                await _privateFeeds.deleteMediaUrl(episodeId);
              } on Object {
                // Continue clearing any media entries restored during delete.
              }
            }
          }
        } on Object {
          // Preserve prior media unless database deletion can be confirmed.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<Feed?> _feedAfterDeletionSettles(String feedId) async {
    final deletion = _feedDeletions[feedId];
    if (deletion != null) await deletion.future;
    return _database.feedById(feedId);
  }

  Future<void> _recordRefreshError(String feedId, String message) async {
    await (_database.update(
      _database.feeds,
    )..where((row) => row.id.equals(feedId))).write(
      FeedsCompanion(
        lastRefresh: Value(DateTime.now().toUtc()),
        refreshError: Value(message),
      ),
    );
  }

  Future<Feed?> _privateFeedBySecret(
    Uri url,
    Map<String, String> headers,
  ) async {
    final privateFeeds = await (_database.select(
      _database.feeds,
    )..where((row) => row.isPrivate.equals(true))).get();
    for (final feed in privateFeeds) {
      final secret = await _privateFeeds.read(feed.credentialRef ?? '');
      if (secret != null &&
          (secret.url == url ||
              credentialAgnosticUrl(secret.url) ==
                  credentialAgnosticUrl(url)) &&
          mapEquals(secret.headers, headers)) {
        return feed;
      }
    }
    return null;
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

  Future<_PreparedFeed> _prepare(NetworkDocument document) {
    return compute(_parseAndPrepareFeed, (
      source: document.text,
      url: document.url.toString(),
    ));
  }
}

final class _FeedNoLongerExists implements Exception {
  const _FeedNoLongerExists();
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
}

_PreparedFeed _parseAndPrepareFeed(({String source, String url}) input) {
  final feed = const FeedParser().parse(input.source, Uri.parse(input.url));
  return _PreparedFeed(
    feed: feed,
    feedBody: '${feed.author ?? ''} ${_plainText(feed.description)}',
    episodeBodies: [
      for (final episode in feed.episodes) _plainText(episode.description),
    ],
    articleBodies: [
      for (final article in feed.articles)
        '${article.author ?? ''} ${_plainText(article.contentHtml ?? article.summary)}',
    ],
  );
}

String _episodeIdentity(ParsedEpisode episode, {required bool isPrivate}) {
  if (!isPrivate) {
    return publicEpisodeIdentity(
      guid: episode.guid,
      enclosureUrl: episode.enclosureUrl,
      publishedAt: episode.publishedAt,
      title: episode.title,
    );
  }
  final guid = episode.guid?.trim();
  if (guid?.isNotEmpty == true) return guid!;
  final published = episode.publishedAt?.toUtc().millisecondsSinceEpoch;
  final stableMediaUrl = episode.enclosureUrl
      .replace(userInfo: '', query: '', fragment: '')
      .toString();
  return '$stableMediaUrl|${published ?? episode.title.trim().toLowerCase()}';
}

String _articleIdentity(ParsedArticle article, {required bool isPrivate}) {
  if (!isPrivate) {
    return publicArticleIdentity(
      guid: article.guid,
      canonicalUrl: article.canonicalUrl,
      publishedAt: article.publishedAt,
      title: article.title,
    );
  }
  final guid = article.guid?.trim();
  if (guid?.isNotEmpty == true) return guid!;
  final published = article.publishedAt?.toUtc().millisecondsSinceEpoch;
  return '${article.title.trim().toLowerCase()}|${published ?? 0}';
}

String _plainText(String? html) {
  if (html == null || html.isEmpty) return '';
  return (html_parser.parseFragment(html).text ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
