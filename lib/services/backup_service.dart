import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/database/app_database.dart';
import '../core/constants.dart';
import '../core/feed_identity.dart';

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
  BackupService(this._database);

  final AppDatabase _database;

  Future<void> exportAndShare({Rect? sharePositionOrigin}) async {
    final publicFeeds = await (_database.select(
      _database.feeds,
    )..where((row) => row.isPrivate.equals(false))).get();
    final episodeQuery = _database.select(_database.episodes).join([
      innerJoin(
        _database.feeds,
        _database.feeds.id.equalsExp(_database.episodes.feedId),
      ),
    ])..where(_database.feeds.isPrivate.equals(false));
    final episodes = (await episodeQuery.get())
        .map((row) => row.readTable(_database.episodes))
        .toList(growable: false);
    final articleQuery = _database.select(_database.articles).join([
      innerJoin(
        _database.feeds,
        _database.feeds.id.equalsExp(_database.articles.feedId),
      ),
    ])..where(_database.feeds.isPrivate.equals(false));
    final articles = (await articleQuery.get())
        .map((row) => row.readTable(_database.articles))
        .toList(growable: false);
    final progressQuery = _database.select(_database.playbackProgresses).join([
      innerJoin(
        _database.episodes,
        _database.episodes.id.equalsExp(_database.playbackProgresses.episodeId),
      ),
      innerJoin(
        _database.feeds,
        _database.feeds.id.equalsExp(_database.episodes.feedId),
      ),
    ])..where(_database.feeds.isPrivate.equals(false));
    final progress = (await progressQuery.get())
        .map((row) => row.readTable(_database.playbackProgresses))
        .toList(growable: false);
    final queueQuery = _database.select(_database.queueEntries).join([
      innerJoin(
        _database.episodes,
        _database.episodes.id.equalsExp(_database.queueEntries.episodeId),
      ),
      innerJoin(
        _database.feeds,
        _database.feeds.id.equalsExp(_database.episodes.feedId),
      ),
    ])..where(_database.feeds.isPrivate.equals(false));
    final queue = (await queueQuery.get())
        .map((row) => row.readTable(_database.queueEntries))
        .toList(growable: false);
    final bookmarkQuery = _database.select(_database.bookmarks).join([
      innerJoin(
        _database.episodes,
        _database.episodes.id.equalsExp(_database.bookmarks.episodeId),
      ),
      innerJoin(
        _database.feeds,
        _database.feeds.id.equalsExp(_database.episodes.feedId),
      ),
    ])..where(_database.feeds.isPrivate.equals(false));
    final bookmarks = (await bookmarkQuery.get())
        .map((row) => row.readTable(_database.bookmarks))
        .toList(growable: false);
    final settings = (await _database.select(_database.appSettings).get())
        .where(_validSetting)
        .toList(growable: false);
    final payload = <String, Object?>{
      'format': 'trickle-backup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'feeds': publicFeeds.map((row) => row.toJson()).toList(),
      'episodes': episodes.map((row) => row.toJson()).toList(),
      'articles': articles.map((row) => row.toJson()).toList(),
      'progress': progress.map((row) => row.toJson()).toList(),
      'queue': queue.map((row) => row.toJson()).toList(),
      'bookmarks': bookmarks.map((row) => row.toJson()).toList(),
      'settings': settings.map((row) => row.toJson()).toList(),
    };
    final bytes = await compute(_encodeBackup, payload);
    final temp = await getTemporaryDirectory();
    final date = DateTime.now().toUtc().toIso8601String().split('T').first;
    final file = File(p.join(temp.path, 'trickle-$date.zip'));
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/zip')],
        subject: 'trickle backup',
        text:
            'Local trickle backup. Private feed credentials and downloaded media are excluded.',
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  Future<BackupResult?> pickAndImport() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'trickle backup', extensions: ['zip']),
      ],
    );
    if (picked == null) return null;
    if (await picked.length() > 50 * 1024 * 1024) {
      throw const FormatException('Backup exceeds the 50 MiB import limit.');
    }
    final bytes = await picked.readAsBytes();
    return importBytes(bytes);
  }

  Future<BackupResult> importBytes(List<int> bytes) async {
    if (bytes.length > 50 * 1024 * 1024) {
      throw const FormatException('Backup exceeds the 50 MiB import limit.');
    }
    final data = await compute(_decodeBackup, bytes);
    if (data['format'] != 'trickle-backup' || data['version'] != 1) {
      throw const FormatException('Unsupported trickle backup version.');
    }
    final feeds = _maps(data['feeds']);
    final episodes = _maps(data['episodes']);
    final articles = _maps(data['articles']);
    if (feeds.length > 5000 ||
        episodes.length > 200000 ||
        articles.length > 200000) {
      throw const FormatException('Backup contains too many records.');
    }
    final acceptedFeeds = <String, String>{};
    final feedTitles = <String, String>{};
    final acceptedEpisodes = <String, String>{};
    final episodeIdentities = <String, Map<String, String>>{};
    final articleIdentities = <String, Map<String, String>>{};
    final acceptedArticles = <String>{};
    final existingQueue = await (_database.select(
      _database.queueEntries,
    )..orderBy([(row) => OrderingTerm.asc(row.sortKey)])).get();
    final existingQueueIds = {
      for (final entry in existingQueue) entry.episodeId: entry.id,
    };
    var nextQueueSortKey = existingQueue.isEmpty
        ? 0
        : existingQueue.last.sortKey + 1024;
    await _database.transaction(() async {
      for (final json in feeds) {
        final feed = Feed.fromJson(json);
        final url = Uri.tryParse(feed.feedUrl);
        if (feed.isPrivate ||
            feed.credentialRef != null ||
            url?.scheme != 'https' ||
            url!.host.isEmpty ||
            url.userInfo.isNotEmpty ||
            feed.kind < 0 ||
            feed.kind > 2) {
          continue;
        }
        final sameUrl = await _database.feedByUrl(feed.feedUrl);
        final idCollision = await _database.feedById(feed.id);
        final actualFeedId =
            sameUrl?.id ??
            (idCollision == null
                ? feed.id
                : stableContentId('feed', feed.feedUrl));
        final sanitized = feed.copyWith(
          id: actualFeedId,
          isPrivate: false,
          credentialRef: const Value(null),
          siteUrl: Value(_https(feed.siteUrl)),
          imageUrl: Value(_https(feed.imageUrl)),
          autoDownloadLimit: feed.autoDownloadLimit.clamp(1, 10),
          introSkipMs: feed.introSkipMs.clamp(0, 600000),
          outroSkipMs: feed.outroSkipMs.clamp(0, 600000),
        );
        await _database.into(_database.feeds).insertOnConflictUpdate(sanitized);
        acceptedFeeds[feed.id] = actualFeedId;
        feedTitles[actualFeedId] = feed.title;
        await _database.indexSearchItem(
          entityId: actualFeedId,
          kind: 'feed',
          title: feed.title,
          body: '${feed.author ?? ''} ${_plain(feed.description)}',
          feedTitle: feed.title,
        );
      }
      for (final json in episodes) {
        final episode = Episode.fromJson({
          ...json,
          'automationApplied': json['automationApplied'] ?? false,
        });
        final enclosure = Uri.tryParse(episode.enclosureUrl);
        final actualFeedId = acceptedFeeds[episode.feedId];
        if (actualFeedId == null ||
            enclosure?.scheme != 'https' ||
            enclosure!.host.isEmpty ||
            enclosure.userInfo.isNotEmpty) {
          continue;
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
            identities[identity] ?? stableContentId(actualFeedId, identity);
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
        await _database.indexSearchItem(
          entityId: actualEpisodeId,
          kind: 'episode',
          title: episode.title,
          body: _plain(episode.description),
          feedTitle: feedTitles[actualFeedId] ?? '',
        );
      }
      for (final json in articles) {
        final article = Article.fromJson(json);
        final actualFeedId = acceptedFeeds[article.feedId];
        if (actualFeedId == null) continue;
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
          canonicalUrl: Value(_https(article.canonicalUrl)),
          imageUrl: Value(_https(article.imageUrl)),
        );
        await _database
            .into(_database.articles)
            .insertOnConflictUpdate(sanitized);
        acceptedArticles.add(actualArticleId);
        await _database.indexSearchItem(
          entityId: actualArticleId,
          kind: 'article',
          title: article.title,
          body:
              '${article.author ?? ''} ${_plain(article.contentHtml ?? article.summary)}',
          feedTitle: feedTitles[actualFeedId] ?? '',
        );
      }
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

  String _plain(String? html) {
    if (html == null || html.isEmpty) return '';
    return (html_parser.parseFragment(html).text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String? _https(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    return uri?.scheme == 'https' &&
            uri!.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri.toString()
        : null;
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
