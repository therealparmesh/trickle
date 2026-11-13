import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../core/errors.dart';
import '../core/feed_category.dart';
import '../core/feed_identity.dart';
import '../core/formatters.dart';
import '../core/nostr_identifier.dart';
import '../core/url_identity.dart';
import '../data/database/app_database.dart';
import '../data/nostr/nostr_event.dart';
import '../data/security/private_feed_store.dart';
import 'backup_archive.dart';

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
    Future<void> Function(Future<void> Function())? applyRestore,
    Future<void> Function()? onImported,
  }) : _privateFeeds = privateFeeds,
       _pickFile = pickFile ?? _pickBackupFile,
       _applyRestore = applyRestore,
       _onImported = onImported;

  final AppDatabase _database;
  final PrivateFeedStore? _privateFeeds;
  final Future<XFile?> Function() _pickFile;
  final Future<void> Function(Future<void> Function())? _applyRestore;
  final Future<void> Function()? _onImported;
  Future<BackupResult?>? _activeImport;

  Future<void> exportToFile(File destination) async {
    final archive = await BackupArchive.create();
    try {
      await _database.transaction(() => _exportRecords(archive));
      await archive.save(destination);
    } finally {
      await archive.dispose();
    }
  }

  Stream<D> _rows<T extends Table, D extends DataClass>(
    TableInfo<T, D> table,
  ) async* {
    var rowId = 0;
    while (true) {
      final rows = await _database
          .customSelect(
            'SELECT rowid AS backup_rowid, * FROM ${table.actualTableName} '
            'WHERE rowid > ? ORDER BY rowid LIMIT 32',
            variables: [Variable(rowId)],
          )
          .get();
      if (rows.isEmpty) return;
      for (final row in rows) {
        rowId = row.read<int>('backup_rowid');
        yield await table.mapFromRow(row);
      }
    }
  }

  Future<void> _exportRecords(BackupArchive archive) async {
    final portableFeeds = await _portableFeeds();
    final feedIds = portableFeeds.map((feed) => feed.id).toSet();
    final privateFeedIds = portableFeeds
        .where((feed) => feed.isPrivate)
        .map((feed) => feed.id)
        .toSet();
    final episodeIds = <String>{};
    final articleIds = <String>{};
    Stream<Map<String, Object?>> episodes() async* {
      await for (var episode in _rows(_database.episodes)) {
        if (!feedIds.contains(episode.feedId)) continue;
        if (privateFeedIds.contains(episode.feedId)) {
          final mediaUrl = await _privateFeeds?.readMediaUrl(episode.id);
          final url = _https(mediaUrl?.toString());
          if (url == null) continue;
          episode = episode.copyWith(enclosureUrl: url);
        }
        episodeIds.add(episode.id);
        yield episode.toJson()..remove('refreshId');
      }
    }

    Stream<Map<String, Object?>> articles() async* {
      await for (final article in _rows(_database.articles)) {
        if (!feedIds.contains(article.feedId)) continue;
        articleIds.add(article.id);
        yield article.toJson()..remove('refreshId');
      }
    }

    await archive.write(
      'feeds',
      Stream.fromIterable(
        portableFeeds.map((feed) {
          final json = feed.toJson();
          if (feed.isPrivate) {
            // Older versions can still import the portable URL.
            json['isPrivate'] = false;
            json['portablePrivate'] = true;
          }
          return json;
        }),
      ),
    );
    await archive.write('episodes', episodes());
    await archive.write('articles', articles());
    await archive.write(
      'progress',
      _rows(_database.playbackProgresses)
          .where((item) => episodeIds.contains(item.episodeId))
          .map((row) => row.toJson()),
    );
    // Preserve the visible order, then append background additions not merged yet.
    final queue = await (_database.select(
      _database.queueEntries,
    )..orderBy([(row) => OrderingTerm.asc(row.sortKey)])).get();
    final queuedIds = queue.map((item) => item.episodeId).toSet();
    final staged = await (_database.select(
      _database.pendingQueueAdds,
    )..orderBy([(row) => OrderingTerm.asc(row.sortKey)])).get();
    await archive.write(
      'queue',
      Stream.fromIterable(<QueueEntry>[
        for (final item in queue)
          if (episodeIds.contains(item.episodeId)) item,
        for (final item in staged)
          if (!queuedIds.contains(item.episodeId) &&
              episodeIds.contains(item.episodeId))
            QueueEntry(
              id: stableContentId('queue', item.episodeId),
              episodeId: item.episodeId,
              sortKey: item.sortKey,
              addedAt: item.addedAt,
            ),
      ]).map((item) => item.toJson()),
    );
    await archive.write(
      'bookmarks',
      _rows(_database.bookmarks)
          .where((item) => episodeIds.contains(item.episodeId))
          .map((row) => row.toJson()),
    );
    await archive.write(
      'articleAttachments',
      _rows(_database.articleAttachments)
          .where((item) => articleIds.contains(item.articleId))
          .map((row) => row.toJson()),
    );
    await archive.write(
      'nostrProfiles',
      _rows(_database.nostrProfiles)
          .where((item) => feedIds.contains(item.feedId))
          .map((row) => row.toJson()),
    );
    await archive.write(
      'nostrRelays',
      _rows(_database.nostrRelays)
          .where((item) => feedIds.contains(item.feedId))
          .map((row) => row.toJson()),
    );
    await archive.write(
      'settings',
      _rows(
        _database.appSettings,
      ).where(_validSetting).map((row) => row.toJson()),
    );
  }

  Future<void> exportAndShare({Rect? sharePositionOrigin}) async {
    final temp = await getTemporaryDirectory();
    final date = DateTime.now().toUtc().toIso8601String().split('T').first;
    final file = File(p.join(temp.path, 'trickle-$date.zip'));
    await exportToFile(file);
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
    final int size;
    try {
      size = await picked.length();
    } on Object {
      throw const BackupException('Couldn’t read that backup file.');
    }
    if (size > BackupArchive.maxFileBytes) {
      throw const BackupException('Backup exceeds the 2 GiB size limit.');
    }
    final temporary = await Directory.systemTemp.createTemp('trickle-import-');
    try {
      final file = File(p.join(temporary.path, 'backup.zip'));
      try {
        await picked.saveTo(file.path);
      } catch (_) {
        throw const BackupException('Couldn’t read that backup file.');
      }
      return await importFile(file);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<BackupResult> importFile(File file) async {
    final archive = await BackupArchive.open(file);
    try {
      return await _importRecords(archive);
    } on FormatException {
      throw const BackupException('That file isn’t a valid trickle backup.');
    } on TypeError {
      throw const BackupException('That file isn’t a valid trickle backup.');
    } finally {
      await archive.dispose();
    }
  }

  Future<BackupResult> _importRecords(BackupArchive archive) async {
    final acceptedFeeds = <String, String>{};
    final olderSubscribedFeeds = <String>{};
    final feedTitles = <String, String>{};
    final feedKinds = <String, FeedKind>{};
    final feedProtocols = <String, FeedProtocol>{};
    final acceptedEpisodes = <String, String>{};
    final episodeIdentities = <String, Map<String, String>>{};
    final articleIdentities = <String, Map<String, String>>{};
    final acceptedArticles = <String, String>{};
    final importedNostrKeys = <String, String>{};
    await for (final json in archive.records('nostrProfiles')) {
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
    final backupFeedsWithEpisodes = <String>{};
    final nostrAudioIds = <String>{};
    await for (final episode in archive.records('episodes')) {
      if (episode['feedId'] case final String feedId) {
        backupFeedsWithEpisodes.add(feedId);
        if (importedNostrKeys.containsKey(feedId) && episode['id'] is String) {
          nostrAudioIds.add(episode['id']! as String);
        }
      }
    }
    final importedAttachmentsById = <String, Map<String, Object?>>{};
    final linkedArticleIds = <String>{};
    if (nostrAudioIds.isNotEmpty) {
      await for (final attachment in archive.records('articleAttachments')) {
        if (nostrAudioIds.contains(attachment['id'])) {
          importedAttachmentsById[attachment['id']! as String] = attachment;
          if (attachment['articleId'] case final String id) {
            linkedArticleIds.add(id);
          }
        }
      }
    }
    final importedArticlesById = <String, Map<String, Object?>>{};
    if (linkedArticleIds.isNotEmpty) {
      await for (final article in archive.records('articles')) {
        if (linkedArticleIds.contains(article['id'])) {
          importedArticlesById[article['id']! as String] = {...article}
            ..remove('contentHtml')
            ..remove('summary');
        }
      }
    }
    final privateStore = _privateFeeds;
    final newPrivateCredentials = <String>{};
    final newPrivateMedia = <String>{};
    Future<void> restore() async {
      await _database.mergePendingQueueAdditions();
      final existingQueue = await (_database.select(
        _database.queueEntries,
      )..orderBy([(row) => OrderingTerm.asc(row.sortKey)])).get();
      final existingQueueIds = existingQueue
          .map((entry) => entry.episodeId)
          .toSet();
      var nextQueueSortKey = existingQueue.isEmpty
          ? 0
          : existingQueue.last.sortKey + 1024;
      final existingFeeds = await _database.select(_database.feeds).get();
      final existingFeedsById = {
        for (final feed in existingFeeds) feed.id: feed,
      };
      final existingFeedsByUrl = {
        for (final feed in existingFeeds) feedUrlIdentity(feed.feedUrl): feed,
      };
      if (privateStore != null) {
        for (final feed in existingFeeds) {
          final url = await _portablePrivateFeedUrl(feed, privateStore);
          if (url != null) {
            existingFeedsByUrl.putIfAbsent(feedUrlIdentity(url), () => feed);
          }
        }
      }
      final existingNostrFeedsByKey = <String, Feed>{};
      for (final profile
          in await _database.select(_database.nostrProfiles).get()) {
        final feed = existingFeedsById[profile.feedId];
        if (feed != null) existingNostrFeedsByKey[profile.publicKey] = feed;
      }
      final searchItems = <SearchIndexEntry>[];
      final retainedNostrFeeds = <String>{};
      Future<void> index(SearchIndexEntry item) async {
        searchItems.add(item);
        if (searchItems.length >= 100) {
          await _database.indexSearchItems(searchItems);
          searchItems.clear();
        }
      }

      await for (final json in archive.records('feeds')) {
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
        final identity = feedUrlIdentity(feed.feedUrl);
        final sameUrl =
            (addressKey == null ? null : existingNostrFeedsByKey[addressKey]) ??
            existingFeedsByUrl[identity];
        final idCollision = existingFeedsById[feed.id];
        final importedKind = feed.kind == 2
            ? (backupFeedsWithEpisodes.contains(feed.id)
                  ? FeedKind.podcast
                  : FeedKind.reader)
            : FeedKind.values[feed.kind];
        // Public redirects preserve the ID and creation time. Match that
        // record before looking up an old URL that another feed may now use.
        final samePublicFeed =
            idCollision != null &&
            protocol == FeedProtocol.syndication &&
            idCollision.protocol == protocol.index &&
            idCollision.kind == importedKind.index &&
            idCollision.createdAt.isAtSameMomentAs(feed.createdAt) &&
            !idCollision.isPrivate &&
            json['portablePrivate'] != true &&
            !url!.hasQuery &&
            Uri.tryParse(idCollision.feedUrl)?.hasQuery == false;
        final existing = samePublicFeed ? idCollision : sameUrl;
        final actualFeedId =
            existing?.id ??
            (idCollision == null ? feed.id : stableContentId('feed', identity));
        final existingKind = existing?.kind;
        final kind =
            existingKind != null &&
                existingKind >= 0 &&
                existingKind < FeedKind.values.length
            ? FeedKind.values[existingKind]
            : importedKind;
        final latest =
            existing != null && !feed.updatedAt.isAfter(existing.updatedAt)
            ? existing
            : feed;
        if (feed.subscribed && !latest.subscribed) {
          olderSubscribedFeeds.add(feed.id);
        }
        if (addressKey != null && identical(latest, existing)) {
          retainedNostrFeeds.add(actualFeedId);
        }
        final restorePrivate =
            existing == null &&
            protocol == FeedProtocol.syndication &&
            (json['portablePrivate'] == true ||
                feedUrlMayContainCredentials(url!));
        var credentialRef = existing?.credentialRef;
        if (restorePrivate) {
          if (privateStore == null) {
            throw const BackupException(
              'Couldn’t restore private feed access.',
            );
          }
          credentialRef = await privateStore.save(
            PrivateFeedSecret(url: Uri.parse(identity), headers: const {}),
          );
          newPrivateCredentials.add(credentialRef);
        }
        final useImportedAddress =
            samePublicFeed &&
            identical(latest, feed) &&
            (sameUrl == null || sameUrl.id == actualFeedId);
        final storedUrl = restorePrivate
            ? 'private://$credentialRef'
            : useImportedAddress
            ? identity
            : existing?.feedUrl ?? identity;
        final keepRefreshState =
            !samePublicFeed || storedUrl == feedUrlIdentity(latest.feedUrl);
        final sanitized = latest.copyWith(
          id: actualFeedId,
          feedUrl: storedUrl,
          kind: kind.index,
          protocol: protocol.index,
          category: Value(
            kind == FeedKind.reader
                ? normalizeFeedCategory(latest.category)
                : null,
          ),
          isPrivate: restorePrivate || existing?.isPrivate == true,
          credentialRef: Value(credentialRef),
          etag: Value(keepRefreshState ? latest.etag : null),
          lastModified: Value(keepRefreshState ? latest.lastModified : null),
          lastRefresh: Value(keepRefreshState ? latest.lastRefresh : null),
          refreshError: Value(keepRefreshState ? latest.refreshError : null),
          siteUrl: Value(_https(latest.siteUrl)),
          imageUrl: Value(_https(latest.imageUrl)),
          autoDownloadLimit: latest.autoDownloadLimit.clamp(1, 10),
          introSkipMs: latest.introSkipMs.clamp(0, 600000),
          outroSkipMs: latest.outroSkipMs.clamp(0, 600000),
        );
        await _database.into(_database.feeds).insertOnConflictUpdate(sanitized);
        existingFeedsById[actualFeedId] = sanitized;
        if (useImportedAddress && existing!.feedUrl != storedUrl) {
          existingFeedsByUrl.remove(feedUrlIdentity(existing.feedUrl));
        }
        existingFeedsByUrl[sanitized.isPrivate
                ? identity
                : feedUrlIdentity(storedUrl)] =
            sanitized;
        if (addressKey != null) {
          existingNostrFeedsByKey[addressKey] = sanitized;
        }
        acceptedFeeds[feed.id] = actualFeedId;
        feedTitles[actualFeedId] = sanitized.title;
        feedKinds[actualFeedId] = kind;
        feedProtocols[actualFeedId] = protocol;
        if (sanitized.subscribed) {
          await index(
            SearchIndexEntry(
              entityId: actualFeedId,
              kind: 'feed',
              title: sanitized.title,
              body:
                  '${sanitized.author ?? ''} ${plainText(sanitized.description)}',
              feedTitle: sanitized.title,
            ),
          );
        } else {
          await _database.customStatement(
            "DELETE FROM search_documents WHERE kind = 'feed' AND entity_id = ?",
            [actualFeedId],
          );
        }
      }
      final nostrDeletions = <String, Map<String, DateTime>>{};
      final nostrFeedIds = [
        for (final entry in feedProtocols.entries)
          if (entry.value == FeedProtocol.nostr) entry.key,
      ];
      final deletions = _database.nostrDeletions;
      for (
        var start = 0;
        start < nostrFeedIds.length;
        start += AppDatabase.safeVariableBatchSize
      ) {
        final end = (start + AppDatabase.safeVariableBatchSize).clamp(
          0,
          nostrFeedIds.length,
        );
        final rows =
            await (_database.select(deletions)..where(
                  (row) => row.feedId.isIn(nostrFeedIds.sublist(start, end)),
                ))
                .get();
        for (final row in rows) {
          nostrDeletions.putIfAbsent(row.feedId, () => {})[row.target] =
              row.deletedAt;
        }
      }
      bool wasDeleted(String feedId, Article article) {
        final deletions = nostrDeletions[feedId];
        return deletions != null &&
            isNostrPostDeleted(
              deletions,
              eventId: article.sourceEventId,
              address: article.sourceAddress,
              publishedAt: article.publishedAt,
            );
      }

      final otherRevisionArticles = <String>{};
      final retainedEpisodeIds = <String>{};
      if (olderSubscribedFeeds.isNotEmpty) {
        await for (final json in archive.records('progress')) {
          final position = json['positionMs'];
          final id = json['episodeId'];
          if (position is int && position > 0 && id is String) {
            retainedEpisodeIds.add(id);
          }
        }
        await for (final json in archive.records('queue')) {
          if (json['episodeId'] case final String id) {
            retainedEpisodeIds.add(id);
          }
        }
        await for (final json in archive.records('bookmarks')) {
          final position = json['positionMs'];
          final id = json['episodeId'];
          if (position is int &&
              position >= 0 &&
              position <= _maxMediaDurationMs &&
              id is String) {
            retainedEpisodeIds.add(id);
          }
        }
      }

      await for (final json in archive.records('episodes')) {
        var episode = Episode.fromJson({
          ...json,
          'automationApplied': json['automationApplied'] ?? false,
          'queueAutomationApplied': json['queueAutomationApplied'] ?? false,
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
              if (wasDeleted(actualFeedId, article)) continue;
              var articleIds = articleIdentities[actualFeedId];
              if (articleIds == null) {
                articleIds = await _existingArticleIdentities(actualFeedId);
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
              final articles = _database.articles;
              final revision =
                  await (_database.selectOnly(articles)
                        ..addColumns([articles.sourceEventId])
                        ..where(articles.id.equals(actualArticleId)))
                      .getSingleOrNull();
              if (revision != null &&
                  revision.read(articles.sourceEventId) !=
                      article.sourceEventId) {
                final attachments = _database.articleAttachments;
                final currentAttachment =
                    await (_database.selectOnly(attachments)
                          ..addColumns([attachments.id])
                          ..where(attachments.id.equals(linkedAttachmentId)))
                        .getSingleOrNull();
                if (currentAttachment == null) continue;
              }
              episode = episode.copyWith(
                guid: Value('nostr-media:$actualArticleId'),
              );
            }
          }
        }
        final private =
            privateStore != null &&
            existingFeedsById[actualFeedId]?.isPrivate == true;
        var identities = episodeIdentities[actualFeedId];
        if (identities == null) {
          final existing = await _database
              .customSelect(
                'SELECT id,feed_id,guid,title,enclosure_url,published_at,discovered_at,'
                'explicit,played,starred,automation_applied,queue_automation_applied '
                'FROM episodes WHERE feed_id = ?',
                variables: [Variable(actualFeedId)],
              )
              .asyncMap(_database.episodes.mapFromRow)
              .get();
          identities = {};
          for (var item in existing) {
            if (private && (item.guid?.trim().isEmpty ?? true)) {
              final media = await privateStore.readMediaUrl(item.id);
              if (media != null) {
                item = item.copyWith(enclosureUrl: media.toString());
              }
            }
            final identity = _episodeIdentity(item);
            if (!identities.containsKey(identity) ||
                item.id == stableContentId(actualFeedId, identity)) {
              identities[identity] = item.id;
            }
          }
          episodeIdentities[actualFeedId] = identities;
        }
        final identity = _episodeIdentity(episode);
        if (olderSubscribedFeeds.contains(episode.feedId) &&
            !episode.starred &&
            !retainedEpisodeIds.contains(episode.id) &&
            !identities.containsKey(identity)) {
          continue;
        }
        final actualEpisodeId =
            linkedAttachmentId ??
            identities[identity] ??
            stableContentId(actualFeedId, identity);
        identities[identity] = actualEpisodeId;
        if (private &&
            await privateStore.readMediaUrl(actualEpisodeId) == null) {
          newPrivateMedia.add(actualEpisodeId);
          await privateStore.saveMediaUrl(actualEpisodeId, enclosure);
        }
        final sanitized = episode.copyWith(
          id: actualEpisodeId,
          feedId: actualFeedId,
          refreshId: const Value(null),
          enclosureUrl: private ? 'private-media://$actualEpisodeId' : null,
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
        final merged = await _database
            .into(_database.episodes)
            .insertReturning(
              sanitized,
              onConflict: DoUpdate.withExcluded(
                (old, incoming) => EpisodesCompanion.custom(
                  starred: old.starred | incoming.starred,
                  automationApplied:
                      old.automationApplied | incoming.automationApplied,
                  queueAutomationApplied:
                      old.queueAutomationApplied |
                      incoming.queueAutomationApplied,
                ),
              ),
            );
        acceptedEpisodes[episode.id] = actualEpisodeId;
        await index(
          SearchIndexEntry(
            entityId: actualEpisodeId,
            kind: 'episode',
            title: merged.title,
            body: plainText(merged.description),
            feedTitle: feedTitles[actualFeedId] ?? '',
          ),
        );
      }
      await for (final json in archive.records('articles')) {
        final article = Article.fromJson({
          ...json,
          'contentFormat':
              json['contentFormat'] ?? ArticleContentFormat.html.index,
          'mediaKind': json['mediaKind'] ?? ArticleMediaKind.none.index,
        });
        final actualFeedId = acceptedFeeds[article.feedId];
        if (actualFeedId == null ||
            feedKinds[actualFeedId] != FeedKind.reader ||
            wasDeleted(actualFeedId, article)) {
          continue;
        }
        var identities = articleIdentities[actualFeedId];
        if (identities == null) {
          identities = await _existingArticleIdentities(actualFeedId);
          articleIdentities[actualFeedId] = identities;
        }
        final identity = _articleIdentity(article);
        if (olderSubscribedFeeds.contains(article.feedId) &&
            !article.starred &&
            !identities.containsKey(identity)) {
          continue;
        }
        final actualArticleId =
            identities[identity] ?? stableContentId(actualFeedId, identity);
        identities[identity] = actualArticleId;
        final sanitized = article.copyWith(
          id: actualArticleId,
          feedId: actualFeedId,
          refreshId: const Value(null),
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
        final merged = await _database
            .into(_database.articles)
            .insertReturning(
              sanitized,
              onConflict: DoUpdate.withExcluded((old, incoming) {
                final useImportedReader =
                    incoming.readerHtml.isNotNull() &
                    old.canonicalUrl.isExp(incoming.canonicalUrl) &
                    (old.readerHtml.isNull() |
                        old.readerFetchedAt.isNull() |
                        incoming.readerFetchedAt.isBiggerThan(
                          old.readerFetchedAt,
                        ));
                return ArticlesCompanion.custom(
                  starred: old.starred | incoming.starred,
                  readerHtml: CaseWhenExpression(
                    cases: [
                      CaseWhen(useImportedReader, then: incoming.readerHtml),
                    ],
                    orElse: old.readerHtml,
                  ),
                  readerFetchedAt: CaseWhenExpression(
                    cases: [
                      CaseWhen(
                        useImportedReader,
                        then: incoming.readerFetchedAt,
                      ),
                    ],
                    orElse: old.readerFetchedAt,
                  ),
                );
              }),
            );
        acceptedArticles[article.id] = actualArticleId;
        if (feedProtocols[actualFeedId] == FeedProtocol.nostr &&
            merged.sourceEventId != article.sourceEventId) {
          otherRevisionArticles.add(article.id);
        }
        await index(
          SearchIndexEntry(
            entityId: actualArticleId,
            kind: 'article',
            title: merged.title,
            body:
                '${merged.author ?? ''} ${plainText(merged.readerHtml ?? merged.contentHtml ?? merged.summary)}',
            feedTitle: feedTitles[actualFeedId] ?? '',
          ),
        );
      }
      await for (final json in archive.records('articleAttachments')) {
        final attachment = ArticleAttachment.fromJson(json);
        final actualArticleId = acceptedArticles[attachment.articleId];
        final mediaUrl = _https(attachment.url);
        if (actualArticleId == null ||
            mediaUrl == null ||
            otherRevisionArticles.contains(attachment.articleId)) {
          continue;
        }
        await _database
            .into(_database.articleAttachments)
            .insert(
              attachment.copyWith(
                id: stableContentId(
                  actualArticleId,
                  '${attachment.position.clamp(0, 1000)}:$mediaUrl',
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
              onConflict: DoNothing(target: const []),
            );
      }
      await for (final json in archive.records('nostrProfiles')) {
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
      await for (final json in archive.records('nostrRelays')) {
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
            retainedNostrFeeds.contains(actualFeedId) ||
            uri == null ||
            (relayCounts[actualFeedId] ?? 0) >= 4) {
          continue;
        }
        if (!relayCounts.containsKey(actualFeedId)) {
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
      final restoredProgressIds = <String>{};
      await for (final json in archive.records('progress')) {
        final progress = PlaybackProgressesData.fromJson({
          ...json,
          'completedAt': json['completedAt'],
        });
        final actualEpisodeId = acceptedEpisodes[progress.episodeId];
        if (actualEpisodeId == null) continue;
        final sanitized = progress.copyWith(
          episodeId: actualEpisodeId,
          positionMs: progress.positionMs.clamp(0, _maxMediaDurationMs),
          durationMs: Value(progress.durationMs?.clamp(0, _maxMediaDurationMs)),
        );
        final updated = await _database
            .into(_database.playbackProgresses)
            .insertReturningOrNull(
              sanitized,
              onConflict: DoUpdate(
                (_) => sanitized,
                where: (old) =>
                    old.updatedAt.isSmallerThanValue(progress.updatedAt),
              ),
            );
        if (updated != null) {
          restoredProgressIds.add(actualEpisodeId);
          await (_database.update(_database.episodes)
                ..where((row) => row.id.equals(actualEpisodeId)))
              .write(EpisodesCompanion(played: Value(updated.completed)));
        }
      }
      await for (final json in archive.records('queue')) {
        final entry = QueueEntry.fromJson(json);
        final actualEpisodeId = acceptedEpisodes[entry.episodeId];
        if (actualEpisodeId == null) continue;
        if (!existingQueueIds.contains(actualEpisodeId)) {
          // Only local completion history can veto a restored queue entry.
          // A backup may intentionally contain an episode marked played.
          final inserted = await _database.customWriteReturning(
            'INSERT INTO queue_entries (id, episode_id, sort_key, added_at) '
            'SELECT ?, ?, ?, ? WHERE ? OR NOT EXISTS ('
            'SELECT 1 FROM playback_progresses WHERE episode_id = ? '
            'AND completed = 1 AND COALESCE(completed_at, updated_at) > ?) '
            'RETURNING episode_id',
            variables: [
              Variable(stableContentId('queue', actualEpisodeId)),
              Variable(actualEpisodeId),
              Variable(nextQueueSortKey),
              Variable(entry.addedAt),
              Variable(restoredProgressIds.contains(actualEpisodeId)),
              Variable(actualEpisodeId),
              Variable(entry.addedAt),
            ],
            updates: {_database.queueEntries},
            updateKind: UpdateKind.insert,
          );
          if (inserted.isEmpty) continue;
          existingQueueIds.add(actualEpisodeId);
          nextQueueSortKey += 1024;
        }
        await (_database.update(_database.episodes)..where(
              (row) =>
                  row.id.equals(actualEpisodeId) &
                  row.automationApplied.equals(false) &
                  row.queueAutomationApplied.equals(false),
            ))
            .write(
              const EpisodesCompanion(queueAutomationApplied: Value(true)),
            );
      }
      Map<String, Set<(int, int, String?)>>? bookmarkIdentities;
      await for (final json in archive.records('bookmarks')) {
        final bookmark = Bookmark.fromJson(json);
        final actualEpisodeId = acceptedEpisodes[bookmark.episodeId];
        if (actualEpisodeId == null ||
            bookmark.positionMs < 0 ||
            bookmark.positionMs > _maxMediaDurationMs) {
          continue;
        }
        bookmarkIdentities ??= await _existingBookmarkIdentities();
        final known = bookmarkIdentities.putIfAbsent(actualEpisodeId, () => {});
        if (known.add(_bookmarkIdentity(bookmark))) {
          await _database
              .into(_database.bookmarks)
              .insert(
                bookmark.copyWith(episodeId: actualEpisodeId),
                onConflict: DoNothing(),
              );
        }
      }
      await for (final json in archive.records('settings')) {
        final setting = AppSetting.fromJson(json);
        if (!_validSetting(setting)) continue;
        await _database
            .into(_database.appSettings)
            .insert(
              setting,
              onConflict: DoUpdate(
                (_) => setting,
                where: (old) =>
                    old.updatedAt.isSmallerThanValue(setting.updatedAt),
              ),
            );
      }
    }

    var committed = false;
    try {
      Future<void> apply() async {
        await _database.transaction(restore);
        committed = true;
        await _onImported?.call();
      }

      await (_applyRestore?.call(apply) ?? apply());
    } on Object {
      if (committed) {
        throw const BackupException(
          'Backup restored, but playback state couldn’t reload. Restart trickle to finish.',
        );
      }
      for (final episodeId in newPrivateMedia) {
        try {
          await privateStore?.deleteMediaUrl(episodeId);
        } on Object {
          // Keep the restore error if secure-storage cleanup also fails.
        }
      }
      for (final ref in newPrivateCredentials) {
        try {
          await privateStore?.delete(ref);
        } on Object {
          // Keep the restore error if secure-storage cleanup also fails.
        }
      }
      rethrow;
    }
    return BackupResult(
      feeds: acceptedFeeds.length,
      episodes: acceptedEpisodes.length,
      articles: acceptedArticles.length,
    );
  }

  bool _validSetting(AppSetting setting) => switch (setting.key) {
    'playback_speed' => AppConstants.allowedSpeeds.contains(
      int.tryParse(setting.value),
    ),
    'remote_images' => setting.value == 'true' || setting.value == 'false',
    'reader_text_scale' => switch (int.tryParse(setting.value)) {
      final value? => value >= 80 && value <= 150 && value % 10 == 0,
      null => false,
    },
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
      final url = await _portablePrivateFeedUrl(feed, _privateFeeds);
      if (url != null) {
        result.add(
          feed.copyWith(feedUrl: url, credentialRef: const Value(null)),
        );
      }
    }
    return result;
  }

  Future<String?> _portablePrivateFeedUrl(
    Feed feed,
    PrivateFeedStore? store,
  ) async {
    final ref = feed.credentialRef;
    if (!feed.isPrivate || store == null || ref == null) return null;
    try {
      final secret = await store.read(ref);
      if (secret == null || secret.headers.isNotEmpty) return null;
      return _https(secret.url.toString());
    } on Object {
      return null;
    }
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
    return episodeIdentity(
      guid: episode.guid,
      enclosureUrl: uri,
      publishedAt: episode.publishedAt,
      title: episode.title,
    );
  }

  Future<Map<String, Set<(int, int, String?)>>>
  _existingBookmarkIdentities() async {
    final identities = <String, Set<(int, int, String?)>>{};
    await for (final bookmark in _rows(_database.bookmarks)) {
      identities
          .putIfAbsent(bookmark.episodeId, () => {})
          .add(_bookmarkIdentity(bookmark));
    }
    return identities;
  }

  Future<Map<String, String>> _existingArticleIdentities(String feedId) async {
    final rows = await _database
        .customSelect(
          'SELECT id,feed_id,guid,title,canonical_url,published_at,discovered_at,'
          'content_format,media_kind,starred FROM articles WHERE feed_id = ?',
          variables: [Variable(feedId)],
        )
        .asyncMap(_database.articles.mapFromRow)
        .get();
    final identities = <String, String>{};
    for (final article in rows) {
      final identity = _articleIdentity(article);
      if (!identities.containsKey(identity) ||
          article.id == stableContentId(feedId, identity)) {
        identities[identity] = article.id;
      }
    }
    return identities;
  }

  String _articleIdentity(Article article) {
    return articleIdentity(
      guid: article.guid,
      canonicalUrl: Uri.tryParse(article.canonicalUrl ?? ''),
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

(int, int, String?) _bookmarkIdentity(Bookmark bookmark) => (
  bookmark.positionMs,
  bookmark.createdAt.millisecondsSinceEpoch ~/ 1000,
  bookmark.note,
);
