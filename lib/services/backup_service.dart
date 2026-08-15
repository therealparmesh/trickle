import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/database/app_database.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../core/feed_category.dart';
import '../core/feed_identity.dart';
import '../core/formatters.dart';
import '../core/nostr_identifier.dart';
import '../data/security/private_feed_store.dart';

final class BackupResult {
  const BackupResult({
    required this.feeds,
    required this.episodes,
    required this.articles,
  });
  final int feeds;
  final int episodes;
  final int articles;
}

final class BackupService {
  BackupService(
    this._database, {
    PrivateFeedStore? privateFeeds,
    Future<XFile?> Function()? pickFile,
    Future<void> Function()? onImported,
  }) : _privateFeeds = privateFeeds,
       _pickFile = pickFile ?? _pickBackupFile,
       _onImported = onImported;

  final AppDatabase _database;
  final PrivateFeedStore? _privateFeeds;
  final Future<XFile?> Function() _pickFile;
  final Future<void> Function()? _onImported;
  Future<BackupResult?>? _activeImport;

  Future<List<int>> exportBytes() async {
    final portableFeeds = await _portableFeeds();
    final feedIds = portableFeeds.map((feed) => feed.id).toSet();
    final storedFeeds = {
      for (final feed in await _database.select(_database.feeds).get())
        feed.id: feed,
    };
    final episodes = <Episode>[];
    for (final episode in await _database.select(_database.episodes).get()) {
      if (!feedIds.contains(episode.feedId)) continue;
      if (storedFeeds[episode.feedId]?.isPrivate != true) {
        episodes.add(episode);
        continue;
      }
      final mediaUrl = await _privateFeeds?.readMediaUrl(episode.id);
      if (_https(mediaUrl?.toString()) case final url?) {
        episodes.add(episode.copyWith(enclosureUrl: url));
      }
    }
    final episodeIds = episodes.map((episode) => episode.id).toSet();
    final articles = (await _database.select(_database.articles).get())
        .where((article) => feedIds.contains(article.feedId))
        .toList(growable: false);
    final articleIds = articles.map((article) => article.id).toSet();
    final progress =
        (await _database.select(_database.playbackProgresses).get())
            .where((item) => episodeIds.contains(item.episodeId))
            .toList(growable: false);
    final queue = (await _database.select(_database.queueEntries).get())
        .where((item) => episodeIds.contains(item.episodeId))
        .toList(growable: false);
    final bookmarks = (await _database.select(_database.bookmarks).get())
        .where((item) => episodeIds.contains(item.episodeId))
        .toList(growable: false);
    final attachments =
        (await _database.select(_database.articleAttachments).get())
            .where((item) => articleIds.contains(item.articleId))
            .toList(growable: false);
    final nostrProfiles =
        (await _database.select(_database.nostrProfiles).get())
            .where((item) => feedIds.contains(item.feedId))
            .toList(growable: false);
    final nostrRelays = (await _database.select(_database.nostrRelays).get())
        .where((item) => feedIds.contains(item.feedId))
        .toList(growable: false);
    final settings = (await _database.select(_database.appSettings).get())
        .where(_validSetting)
        .toList(growable: false);
    final payload = <String, Object?>{
      'format': 'trickle-backup',
      'version': 2,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'feeds': portableFeeds.map((row) => row.toJson()).toList(),
      'episodes': episodes.map((row) => row.toJson()).toList(),
      'articles': articles.map((row) => row.toJson()).toList(),
      'articleAttachments': attachments.map((row) => row.toJson()).toList(),
      'nostrProfiles': nostrProfiles.map((row) => row.toJson()).toList(),
      'nostrRelays': nostrRelays.map((row) => row.toJson()).toList(),
      'progress': progress.map((row) => row.toJson()).toList(),
      'queue': queue.map((row) => row.toJson()).toList(),
      'bookmarks': bookmarks.map((row) => row.toJson()).toList(),
      'settings': settings.map((row) => row.toJson()).toList(),
    };
    final bytes = await compute(_encodeBackup, payload);
    return bytes;
  }

  Future<void> exportAndShare({Rect? sharePositionOrigin}) async {
    final bytes = await exportBytes();
    final temp = await getTemporaryDirectory();
    final date = DateTime.now().toUtc().toIso8601String().split('T').first;
    final file = File(p.join(temp.path, 'trickle-$date.zip'));
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/zip')],
        subject: 'trickle backup',
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  Future<BackupResult?> pickAndImport() {
    final active = _activeImport;
    if (active != null) return active;
    final future = _pickAndImport();
    _activeImport = future;
    unawaited(
      future.then<void>(
        (_) => _clearActiveImport(future),
        onError: (Object _, StackTrace _) => _clearActiveImport(future),
      ),
    );
    return future;
  }

  void _clearActiveImport(Future<BackupResult?> future) {
    if (identical(_activeImport, future)) _activeImport = null;
  }

  Future<BackupResult?> _pickAndImport() async {
    XFile? picked;
    try {
      picked = await _pickFile();
    } on Object {
      throw const BackupException('Couldn’t open the file picker.');
    }
    if (picked == null) return null;
    late List<int> bytes;
    try {
      if (await picked.length() > 50 * 1024 * 1024) {
        throw const BackupException('Backup exceeds the 50 MiB import limit.');
      }
      bytes = await picked.readAsBytes();
    } on BackupException {
      rethrow;
    } on Object {
      throw const BackupException('Couldn’t read that backup file.');
    }
    final result = await importBytes(bytes);
    try {
      await _onImported?.call();
    } on Object {
      throw const BackupException(
        'Backup restored, but playback state couldn’t reload. Restart trickle to finish.',
      );
    }
    return result;
  }

  Future<BackupResult> importBytes(List<int> bytes) async {
    if (bytes.length > 50 * 1024 * 1024) {
      throw const BackupException('Backup exceeds the 50 MiB import limit.');
    }
    late Map<String, Object?> data;
    try {
      data = await compute(_decodeBackup, bytes);
    } on Object {
      throw const BackupException('That file isn’t a valid trickle backup.');
    }
    final version = data['version'];
    if (data['format'] != 'trickle-backup' ||
        version is! int ||
        version < 1 ||
        version > 2) {
      throw const BackupException('Unsupported trickle backup version.');
    }
    final feeds = _maps(data['feeds']);
    final episodes = _maps(data['episodes']);
    final articles = _maps(data['articles']);
    final attachments = _maps(data['articleAttachments']);
    final nostrProfiles = _maps(data['nostrProfiles']);
    final nostrRelays = _maps(data['nostrRelays']);
    final importedArticlesById = <String, Map<String, Object?>>{
      for (final article in articles)
        if (article['id'] case final String id) id: article,
    };
    final importedAttachmentsById = <String, Map<String, Object?>>{
      for (final attachment in attachments)
        if (attachment['id'] case final String id) id: attachment,
    };
    if (feeds.length > 5000 ||
        episodes.length > 200000 ||
        articles.length > 200000 ||
        attachments.length > 500000 ||
        nostrProfiles.length > 5000 ||
        nostrRelays.length > 20000) {
      throw const BackupException('Backup contains too many records.');
    }
    final acceptedFeeds = <String, String>{};
    final feedTitles = <String, String>{};
    final feedKinds = <String, FeedKind>{};
    final feedProtocols = <String, FeedProtocol>{};
    final acceptedEpisodes = <String, String>{};
    final episodeIdentities = <String, Map<String, String>>{};
    final articleIdentities = <String, Map<String, String>>{};
    final acceptedArticles = <String, String>{};
    final importedNostrKeys = <String, String>{};
    for (final json in nostrProfiles) {
      try {
        final profile = NostrProfile.fromJson(json);
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(profile.publicKey)) {
          importedNostrKeys.putIfAbsent(
            profile.feedId,
            () => profile.publicKey,
          );
        }
      } on Object {
        // Invalid child records are ignored without rejecting usable content.
      }
    }
    final existingQueue = await (_database.select(
      _database.queueEntries,
    )..orderBy([(row) => OrderingTerm.asc(row.sortKey)])).get();
    final existingQueueIds = {
      for (final entry in existingQueue) entry.episodeId: entry.id,
    };
    final existingFeeds = await _database.select(_database.feeds).get();
    final existingFeedsById = {for (final feed in existingFeeds) feed.id: feed};
    final existingFeedsByUrl = {
      for (final feed in existingFeeds) feed.feedUrl: feed,
    };
    final existingNostrFeedsByKey = <String, Feed>{};
    for (final profile
        in await _database.select(_database.nostrProfiles).get()) {
      final feed = existingFeedsById[profile.feedId];
      if (feed != null) existingNostrFeedsByKey[profile.publicKey] = feed;
    }
    final backupFeedsWithEpisodes = {
      for (final episode in episodes)
        if (episode['feedId'] case final String feedId) feedId,
    };
    var nextQueueSortKey = existingQueue.isEmpty
        ? 0
        : existingQueue.last.sortKey + 1024;
    await _database.transaction(() async {
      final searchItems = <SearchIndexEntry>[];
      for (final json in feeds) {
        final feed = Feed.fromJson({
          ...json,
          'protocol': json['protocol'] ?? FeedProtocol.syndication.index,
          'subscribed': json['subscribed'] ?? true,
        });
        final url = Uri.tryParse(feed.feedUrl);
        final protocol =
            feed.protocol >= 0 && feed.protocol < FeedProtocol.values.length
            ? FeedProtocol.values[feed.protocol]
            : FeedProtocol.syndication;
        final importedNostrKey = importedNostrKeys[feed.id];
        final addressKey = protocol == FeedProtocol.nostr
            ? _nostrPublicKey(feed.feedUrl)
            : null;
        final validAddress = protocol == FeedProtocol.nostr
            ? feed.kind == FeedKind.reader.index &&
                  importedNostrKey != null &&
                  addressKey == importedNostrKey
            : url?.scheme == 'https' &&
                  url?.host.isNotEmpty == true &&
                  url?.userInfo.isEmpty == true;
        if (feed.isPrivate ||
            feed.credentialRef != null ||
            !validAddress ||
            feed.kind < 0 ||
            feed.kind > 2) {
          continue;
        }
        final sameUrl =
            (importedNostrKey == null
                ? null
                : existingNostrFeedsByKey[importedNostrKey]) ??
            existingFeedsByUrl[feed.feedUrl];
        final idCollision = existingFeedsById[feed.id];
        final actualFeedId =
            sameUrl?.id ??
            (idCollision == null
                ? feed.id
                : stableContentId('feed', feed.feedUrl));
        final importedKind = feed.kind == 2
            ? (backupFeedsWithEpisodes.contains(feed.id)
                  ? FeedKind.podcast
                  : FeedKind.reader)
            : FeedKind.values[feed.kind];
        final existingKind = sameUrl?.kind;
        final kind =
            existingKind != null &&
                existingKind >= 0 &&
                existingKind < FeedKind.values.length
            ? FeedKind.values[existingKind]
            : importedKind;
        final sanitized = feed.copyWith(
          id: actualFeedId,
          kind: kind.index,
          protocol: protocol.index,
          category: Value(
            kind == FeedKind.reader
                ? normalizeFeedCategory(feed.category)
                : null,
          ),
          isPrivate: false,
          credentialRef: const Value(null),
          siteUrl: Value(_https(feed.siteUrl)),
          imageUrl: Value(_https(feed.imageUrl)),
          autoDownloadLimit: feed.autoDownloadLimit.clamp(1, 10),
          introSkipMs: feed.introSkipMs.clamp(0, 600000),
          outroSkipMs: feed.outroSkipMs.clamp(0, 600000),
        );
        await _database.into(_database.feeds).insertOnConflictUpdate(sanitized);
        existingFeedsById[actualFeedId] = sanitized;
        existingFeedsByUrl[feed.feedUrl] = sanitized;
        if (importedNostrKey != null) {
          existingNostrFeedsByKey[importedNostrKey] = sanitized;
        }
        acceptedFeeds[feed.id] = actualFeedId;
        feedTitles[actualFeedId] = feed.title;
        feedKinds[actualFeedId] = kind;
        feedProtocols[actualFeedId] = protocol;
        searchItems.add(
          SearchIndexEntry(
            entityId: actualFeedId,
            kind: 'feed',
            title: feed.title,
            body: '${feed.author ?? ''} ${plainText(feed.description)}',
            feedTitle: feed.title,
          ),
        );
      }
      for (final json in episodes) {
        var episode = Episode.fromJson({
          ...json,
          'automationApplied': json['automationApplied'] ?? false,
        });
        final enclosure = Uri.tryParse(episode.enclosureUrl);
        final actualFeedId = acceptedFeeds[episode.feedId];
        if (actualFeedId == null ||
            (feedKinds[actualFeedId] != FeedKind.podcast &&
                feedProtocols[actualFeedId] != FeedProtocol.nostr) ||
            enclosure?.scheme != 'https' ||
            enclosure!.host.isEmpty ||
            enclosure.userInfo.isNotEmpty) {
          continue;
        }
        String? linkedAttachmentId;
        if (feedProtocols[actualFeedId] == FeedProtocol.nostr) {
          final attachmentJson = importedAttachmentsById[episode.id];
          final articleJson = attachmentJson == null
              ? null
              : importedArticlesById[attachmentJson['articleId']];
          if (attachmentJson != null && articleJson != null) {
            final attachment = ArticleAttachment.fromJson(attachmentJson);
            final article = Article.fromJson({
              ...articleJson,
              'contentFormat':
                  articleJson['contentFormat'] ??
                  ArticleContentFormat.html.index,
              'mediaKind':
                  articleJson['mediaKind'] ?? ArticleMediaKind.none.index,
            });
            final mediaUrl = _https(attachment.url);
            if (article.feedId == episode.feedId && mediaUrl != null) {
              var articleIds = articleIdentities[actualFeedId];
              if (articleIds == null) {
                final existing = await (_database.select(
                  _database.articles,
                )..where((row) => row.feedId.equals(actualFeedId))).get();
                articleIds = {
                  for (final item in existing) _articleIdentity(item): item.id,
                };
                articleIdentities[actualFeedId] = articleIds;
              }
              final articleIdentity = _articleIdentity(article);
              final actualArticleId =
                  articleIds[articleIdentity] ??
                  stableContentId(actualFeedId, articleIdentity);
              articleIds[articleIdentity] = actualArticleId;
              linkedAttachmentId = stableContentId(
                actualArticleId,
                '${attachment.position.clamp(0, 1000)}:$mediaUrl',
              );
              episode = episode.copyWith(
                guid: Value('nostr-media:$actualArticleId'),
              );
            }
          }
        }
        var identities = episodeIdentities[actualFeedId];
        if (identities == null) {
          final existing = await (_database.select(
            _database.episodes,
          )..where((row) => row.feedId.equals(actualFeedId))).get();
          identities = {
            for (final item in existing) _episodeIdentity(item): item.id,
          };
          episodeIdentities[actualFeedId] = identities;
        }
        final identity = _episodeIdentity(episode);
        final actualEpisodeId =
            linkedAttachmentId ??
            identities[identity] ??
            stableContentId(actualFeedId, identity);
        identities[identity] = actualEpisodeId;
        final sanitized = episode.copyWith(
          id: actualEpisodeId,
          feedId: actualFeedId,
          imageUrl: Value(_https(episode.imageUrl)),
          chaptersUrl: Value(_https(episode.chaptersUrl)),
          fileSize: Value(
            (episode.fileSize ?? 0) > 0 &&
                    episode.fileSize! <= 0x7FFFFFFFFFFFFFFF
                ? episode.fileSize
                : null,
          ),
          durationMs: Value(
            (episode.durationMs ?? 0) > 0 &&
                    episode.durationMs! <= _maxMediaDurationMs
                ? episode.durationMs
                : null,
          ),
        );
        await _database
            .into(_database.episodes)
            .insertOnConflictUpdate(sanitized);
        acceptedEpisodes[episode.id] = actualEpisodeId;
        searchItems.add(
          SearchIndexEntry(
            entityId: actualEpisodeId,
            kind: 'episode',
            title: episode.title,
            body: plainText(episode.description),
            feedTitle: feedTitles[actualFeedId] ?? '',
          ),
        );
      }
      for (final json in articles) {
        final article = Article.fromJson({
          ...json,
          'contentFormat':
              json['contentFormat'] ?? ArticleContentFormat.html.index,
          'mediaKind': json['mediaKind'] ?? ArticleMediaKind.none.index,
        });
        final actualFeedId = acceptedFeeds[article.feedId];
        if (actualFeedId == null ||
            feedKinds[actualFeedId] != FeedKind.reader) {
          continue;
        }
        var identities = articleIdentities[actualFeedId];
        if (identities == null) {
          final existing = await (_database.select(
            _database.articles,
          )..where((row) => row.feedId.equals(actualFeedId))).get();
          identities = {
            for (final item in existing) _articleIdentity(item): item.id,
          };
          articleIdentities[actualFeedId] = identities;
        }
        final identity = _articleIdentity(article);
        final actualArticleId =
            identities[identity] ?? stableContentId(actualFeedId, identity);
        identities[identity] = actualArticleId;
        final sanitized = article.copyWith(
          id: actualArticleId,
          feedId: actualFeedId,
          canonicalUrl: Value(
            feedProtocols[actualFeedId] == FeedProtocol.nostr &&
                    Uri.tryParse(article.canonicalUrl ?? '')?.scheme == 'nostr'
                ? article.canonicalUrl
                : _https(article.canonicalUrl),
          ),
          imageUrl: Value(_https(article.imageUrl)),
          contentFormat: article.contentFormat.clamp(
            0,
            ArticleContentFormat.values.length - 1,
          ),
          mediaKind: article.mediaKind.clamp(
            0,
            ArticleMediaKind.values.length - 1,
          ),
        );
        await _database
            .into(_database.articles)
            .insertOnConflictUpdate(sanitized);
        acceptedArticles[article.id] = actualArticleId;
        searchItems.add(
          SearchIndexEntry(
            entityId: actualArticleId,
            kind: 'article',
            title: article.title,
            body:
                '${article.author ?? ''} ${plainText(article.contentHtml ?? article.summary)}',
            feedTitle: feedTitles[actualFeedId] ?? '',
          ),
        );
      }
      final clearedAttachmentArticles = <String>{};
      for (final json in attachments) {
        final attachment = ArticleAttachment.fromJson(json);
        final actualArticleId = acceptedArticles[attachment.articleId];
        final mediaUrl = _https(attachment.url);
        if (actualArticleId == null || mediaUrl == null) continue;
        if (clearedAttachmentArticles.add(actualArticleId)) {
          await (_database.delete(
            _database.articleAttachments,
          )..where((row) => row.articleId.equals(actualArticleId))).go();
        }
        await _database
            .into(_database.articleAttachments)
            .insertOnConflictUpdate(
              attachment.copyWith(
                id: stableContentId(
                  actualArticleId,
                  '${attachment.position}:$mediaUrl',
                ),
                articleId: actualArticleId,
                position: attachment.position.clamp(0, 1000),
                url: mediaUrl,
                previewUrl: Value(_https(attachment.previewUrl)),
                width: Value(attachment.width?.clamp(1, 100000)),
                height: Value(attachment.height?.clamp(1, 100000)),
                durationMs: Value(
                  attachment.durationMs?.clamp(1, _maxMediaDurationMs),
                ),
                fallbackUrls: Value(_portableUrlList(attachment.fallbackUrls)),
              ),
            );
      }
      for (final json in nostrProfiles) {
        NostrProfile profile;
        try {
          profile = NostrProfile.fromJson(json);
        } on Object {
          continue;
        }
        final actualFeedId = acceptedFeeds[profile.feedId];
        if (actualFeedId == null ||
            feedProtocols[actualFeedId] != FeedProtocol.nostr ||
            importedNostrKeys[profile.feedId] != profile.publicKey) {
          continue;
        }
        await _database
            .into(_database.nostrProfiles)
            .insertOnConflictUpdate(profile.copyWith(feedId: actualFeedId));
      }
      final relayCounts = <String, int>{};
      final clearedRelayFeeds = <String>{};
      for (final json in nostrRelays) {
        NostrRelay relay;
        try {
          relay = NostrRelay.fromJson(json);
        } on Object {
          continue;
        }
        final actualFeedId = acceptedFeeds[relay.feedId];
        final uri = normalizeNostrRelay(relay.url);
        if (actualFeedId == null ||
            feedProtocols[actualFeedId] != FeedProtocol.nostr ||
            uri == null ||
            (relayCounts[actualFeedId] ?? 0) >= 4) {
          continue;
        }
        if (clearedRelayFeeds.add(actualFeedId)) {
          await (_database.delete(
            _database.nostrRelays,
          )..where((row) => row.feedId.equals(actualFeedId))).go();
        }
        relayCounts[actualFeedId] = (relayCounts[actualFeedId] ?? 0) + 1;
        await _database
            .into(_database.nostrRelays)
            .insertOnConflictUpdate(
              relay.copyWith(feedId: actualFeedId, url: uri.toString()),
            );
      }
      await _database.indexSearchItems(searchItems);
      for (final json in _maps(data['progress'])) {
        final progress = PlaybackProgressesData.fromJson({
          ...json,
          'completedAt': json['completedAt'],
        });
        final actualEpisodeId = acceptedEpisodes[progress.episodeId];
        if (actualEpisodeId == null) continue;
        await _database
            .into(_database.playbackProgresses)
            .insertOnConflictUpdate(
              progress.copyWith(
                episodeId: actualEpisodeId,
                positionMs: progress.positionMs.clamp(0, _maxMediaDurationMs),
                durationMs: Value(
                  progress.durationMs?.clamp(0, _maxMediaDurationMs),
                ),
              ),
            );
      }
      for (final json in _maps(data['queue'])) {
        final entry = QueueEntry.fromJson(json);
        final actualEpisodeId = acceptedEpisodes[entry.episodeId];
        if (actualEpisodeId == null) continue;
        if (existingQueueIds.containsKey(actualEpisodeId)) continue;
        final actualQueueId = stableContentId('queue', actualEpisodeId);
        existingQueueIds[actualEpisodeId] = actualQueueId;
        await _database
            .into(_database.queueEntries)
            .insertOnConflictUpdate(
              entry.copyWith(
                id: actualQueueId,
                episodeId: actualEpisodeId,
                sortKey: nextQueueSortKey,
              ),
            );
        nextQueueSortKey += 1024;
      }
      for (final json in _maps(data['bookmarks'])) {
        final bookmark = Bookmark.fromJson(json);
        final actualEpisodeId = acceptedEpisodes[bookmark.episodeId];
        if (actualEpisodeId == null ||
            bookmark.positionMs < 0 ||
            bookmark.positionMs > _maxMediaDurationMs) {
          continue;
        }
        await _database
            .into(_database.bookmarks)
            .insertOnConflictUpdate(
              bookmark.copyWith(
                id: stableContentId(actualEpisodeId, bookmark.id),
                episodeId: actualEpisodeId,
              ),
            );
      }
      for (final json in _maps(data['settings'])) {
        final setting = AppSetting.fromJson(json);
        if (!_validSetting(setting)) continue;
        await _database
            .into(_database.appSettings)
            .insertOnConflictUpdate(setting);
      }
    });
    return BackupResult(
      feeds: acceptedFeeds.length,
      episodes: acceptedEpisodes.length,
      articles: acceptedArticles.length,
    );
  }

  List<Map<String, Object?>> _maps(Object? value) {
    return (value as List? ?? const [])
        .whereType<Map>()
        .map((raw) => raw.cast<String, Object?>())
        .toList(growable: false);
  }

  bool _validSetting(AppSetting setting) => switch (setting.key) {
    'playback_speed' => AppConstants.allowedSpeeds.contains(
      int.tryParse(setting.value),
    ),
    'remote_images' => setting.value == 'true' || setting.value == 'false',
    'auto_delete' => switch (int.tryParse(setting.value)) {
      final value? => value >= 0 && value < AutoDeletePolicy.values.length,
      null => false,
    },
    'refresh_interval' => RefreshInterval.values.any(
      (interval) => interval.name == setting.value,
    ),
    _ => false,
  };

  String? _https(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    return uri?.scheme == 'https' &&
            uri!.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri.toString()
        : null;
  }

  String? _nostrPublicKey(String raw) {
    try {
      return parseNostrProfile(raw).publicKey;
    } on Object {
      return null;
    }
  }

  Future<List<Feed>> _portableFeeds() async {
    final result = <Feed>[];
    for (final feed in await _database.select(_database.feeds).get()) {
      if (!feed.isPrivate) {
        result.add(feed);
        continue;
      }
      final store = _privateFeeds;
      if (store == null) continue;
      try {
        final secret = await store.read(feed.credentialRef ?? '');
        if (secret == null ||
            secret.headers.isNotEmpty ||
            _https(secret.url.toString()) == null) {
          continue;
        }
        result.add(
          feed.copyWith(
            feedUrl: secret.url.toString(),
            isPrivate: false,
            credentialRef: const Value(null),
          ),
        );
      } on Object {
        // A missing secure-store entry cannot be exported safely.
      }
    }
    return result;
  }

  String? _portableUrlList(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final urls = decoded
          .whereType<String>()
          .map(_https)
          .whereType<String>()
          .take(10)
          .toList(growable: false);
      return urls.isEmpty ? null : jsonEncode(urls);
    } on Object {
      return null;
    }
  }

  String _episodeIdentity(Episode episode) {
    final uri = Uri.tryParse(episode.enclosureUrl);
    if (uri == null) return episode.enclosureUrl;
    return publicEpisodeIdentity(
      guid: episode.guid,
      enclosureUrl: uri,
      publishedAt: episode.publishedAt,
      title: episode.title,
    );
  }

  String _articleIdentity(Article article) {
    final uri = Uri.tryParse(article.canonicalUrl ?? '');
    return publicArticleIdentity(
      guid: article.guid,
      canonicalUrl: uri != null && uri.host.isNotEmpty ? uri : null,
      publishedAt: article.publishedAt,
      title: article.title,
    );
  }
}

Future<XFile?> _pickBackupFile() => openFile(
  acceptedTypeGroups: const [
    XTypeGroup(
      label: 'trickle backup',
      extensions: ['zip'],
      mimeTypes: [
        'application/zip',
        // Some Android document providers use a generic binary MIME type.
        // The archive contents are still size-limited and validated.
        'application/octet-stream',
      ],
      uniformTypeIdentifiers: ['public.zip-archive'],
    ),
  ],
);

const _maxMediaDurationMs = 365 * 24 * 60 * 60 * 1000;

List<int> _encodeBackup(Map<String, Object?> payload) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('trickle.json', jsonEncode(payload)));
  return ZipEncoder().encode(archive);
}

Map<String, Object?> _decodeBackup(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final entry = archive.findFile('trickle.json');
  if (entry == null) throw const FormatException('Not a trickle backup.');
  if (entry.size > 50 * 1024 * 1024) {
    throw const FormatException(
      'Expanded backup exceeds the 50 MiB import limit.',
    );
  }
  final content = entry.readBytes();
  if (content == null) throw const FormatException('Backup is empty.');
  return (jsonDecode(utf8.decode(content)) as Map).cast<String, Object?>();
}
