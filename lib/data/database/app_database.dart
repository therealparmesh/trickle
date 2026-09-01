import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';
import '../../core/content_filters.dart';
import '../../core/feed_identity.dart';

part 'app_database.g.dart';

final class SearchIndexEntry {
  const SearchIndexEntry({
    required this.entityId,
    required this.kind,
    required this.title,
    required this.body,
    required this.feedTitle,
  });

  final String entityId;
  final String kind;
  final String title;
  final String body;
  final String feedTitle;
}

class Feeds extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get feedUrl => text()();
  TextColumn get siteUrl => text().nullable()();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get author => text().nullable()();
  TextColumn get category => text().nullable()();
  IntColumn get kind => integer().withDefault(const Constant(1))();
  IntColumn get protocol => integer().withDefault(const Constant(0))();
  BoolColumn get subscribed => boolean().withDefault(const Constant(true))();
  BoolColumn get isPrivate => boolean().withDefault(const Constant(false))();
  TextColumn get credentialRef => text().nullable()();
  TextColumn get etag => text().nullable()();
  TextColumn get lastModified => text().nullable()();
  DateTimeColumn get lastRefresh => dateTime().nullable()();
  TextColumn get refreshError => text().nullable()();
  BoolColumn get autoDownload => boolean().withDefault(const Constant(false))();
  IntColumn get autoDownloadLimit => integer().withDefault(const Constant(3))();
  BoolColumn get notifications =>
      boolean().withDefault(const Constant(false))();
  IntColumn get introSkipMs => integer().withDefault(const Constant(0))();
  IntColumn get outroSkipMs => integer().withDefault(const Constant(0))();
  BoolColumn get autoQueue => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {feedUrl},
  ];
}

class Episodes extends Table {
  TextColumn get id => text()();
  TextColumn get feedId =>
      text().references(Feeds, #id, onDelete: KeyAction.cascade)();
  TextColumn get guid => text().nullable()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get enclosureUrl => text()();
  TextColumn get mimeType => text().nullable()();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get chaptersUrl => text().nullable()();
  DateTimeColumn get publishedAt => dateTime().nullable()();
  DateTimeColumn get discoveredAt => dateTime()();
  IntColumn get durationMs => integer().nullable()();
  IntColumn get fileSize => integer().nullable()();
  BoolColumn get explicit => boolean().withDefault(const Constant(false))();
  BoolColumn get played => boolean().withDefault(const Constant(false))();
  BoolColumn get starred => boolean().withDefault(const Constant(false))();
  BoolColumn get automationApplied =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Articles extends Table {
  TextColumn get id => text()();
  TextColumn get feedId =>
      text().references(Feeds, #id, onDelete: KeyAction.cascade)();
  TextColumn get guid => text().nullable()();
  TextColumn get title => text()();
  TextColumn get author => text().nullable()();
  TextColumn get summary => text().nullable()();
  TextColumn get contentHtml => text().nullable()();
  TextColumn get canonicalUrl => text().nullable()();
  TextColumn get imageUrl => text().nullable()();
  IntColumn get contentFormat => integer().withDefault(const Constant(0))();
  TextColumn get contentWarning => text().nullable()();
  TextColumn get sourceEventId => text().nullable()();
  TextColumn get sourceAddress => text().nullable()();
  IntColumn get mediaKind => integer().withDefault(const Constant(0))();
  DateTimeColumn get publishedAt => dateTime().nullable()();
  DateTimeColumn get discoveredAt => dateTime()();
  DateTimeColumn get readAt => dateTime().nullable()();
  BoolColumn get starred => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class NostrProfiles extends Table {
  TextColumn get feedId =>
      text().references(Feeds, #id, onDelete: KeyAction.cascade)();
  TextColumn get publicKey => text().unique()();

  @override
  Set<Column<Object>> get primaryKey => {feedId};
}

class NostrRelays extends Table {
  TextColumn get feedId =>
      text().references(Feeds, #id, onDelete: KeyAction.cascade)();
  TextColumn get url => text()();

  @override
  Set<Column<Object>> get primaryKey => {feedId, url};
}

class ArticleAttachments extends Table {
  TextColumn get id => text()();
  TextColumn get articleId =>
      text().references(Articles, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  TextColumn get url => text()();
  TextColumn get mimeType => text().nullable()();
  TextColumn get previewUrl => text().nullable()();
  TextColumn get alt => text().nullable()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get fallbackUrls => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {articleId, position},
  ];
}

class PlaybackProgresses extends Table {
  TextColumn get episodeId =>
      text().references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get positionMs => integer().withDefault(const Constant(0))();
  IntColumn get durationMs => integer().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {episodeId};
}

class QueueEntries extends Table {
  TextColumn get id => text()();
  TextColumn get episodeId =>
      text().unique().references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get sortKey => integer()();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PendingQueueAdds extends Table {
  TextColumn get episodeId =>
      text().references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get sortKey => integer()();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {episodeId};
}

class MediaDownloads extends Table {
  TextColumn get episodeId =>
      text().references(Episodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get taskId => text().unique()();
  IntColumn get status => integer().withDefault(const Constant(0))();
  TextColumn get filePath => text().nullable()();
  IntColumn get bytesDownloaded => integer().withDefault(const Constant(0))();
  IntColumn get totalBytes => integer().nullable()();
  BoolColumn get keep => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {episodeId};
}

class Chapters extends Table {
  TextColumn get id => text()();
  TextColumn get episodeId =>
      text().references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get startMs => integer()();
  TextColumn get title => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Transcripts extends Table {
  TextColumn get id => text()();
  TextColumn get episodeId =>
      text().references(Episodes, #id, onDelete: KeyAction.cascade)();
  TextColumn get url => text()();
  TextColumn get mimeType => text().nullable()();
  TextColumn get content => text().nullable()();
  DateTimeColumn get fetchedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Bookmarks extends Table {
  TextColumn get id => text()();
  TextColumn get episodeId =>
      text().references(Episodes, #id, onDelete: KeyAction.cascade)();
  IntColumn get positionMs => integer()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

class SearchCaches extends Table {
  TextColumn get key => text()();
  TextColumn get payload => text()();
  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(
  tables: [
    Feeds,
    Episodes,
    Articles,
    NostrProfiles,
    NostrRelays,
    ArticleAttachments,
    PlaybackProgresses,
    QueueEntries,
    PendingQueueAdds,
    MediaDownloads,
    Chapters,
    Transcripts,
    Bookmarks,
    AppSettings,
    SearchCaches,
  ],
)
class AppDatabase extends _$AppDatabase {
  static const safeVariableBatchSize = 400;

  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _createIndexes();
      await _createSearchIndex();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 1 || from > 4 || to != 5) {
        throw StateError('Unsupported database migration from $from to $to.');
      }
      if (from < 3) {
        await customStatement('DROP INDEX IF EXISTS idx_articles_unread');
        await customStatement('DROP INDEX IF EXISTS idx_episodes_automation');
        await customStatement('DROP INDEX IF EXISTS idx_feeds_last_refresh');
        await migrator.addColumn(feeds, feeds.protocol);
        await migrator.addColumn(feeds, feeds.subscribed);
        await migrator.addColumn(articles, articles.contentFormat);
        await migrator.addColumn(articles, articles.contentWarning);
        await migrator.addColumn(articles, articles.sourceEventId);
        await migrator.addColumn(articles, articles.sourceAddress);
        await migrator.addColumn(articles, articles.mediaKind);
        await migrator.createTable(nostrProfiles);
        await migrator.createTable(nostrRelays);
        await migrator.createTable(articleAttachments);
      }
      if (from < 4) await migrator.addColumn(feeds, feeds.category);
      await migrator.createTable(pendingQueueAdds);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement(
        'PRAGMA busy_timeout = '
        '${AppConstants.databaseLockTimeout.inMilliseconds}',
      );
      if (details.wasCreated) return;
      await _createIndexes();
      await _createSearchIndex();
      await _repairLegacyMixedFeeds();
    },
  );

  Future<void> _repairLegacyMixedFeeds() async {
    // Version 1 stored mixed feeds as kind 2 and surfaced them in both
    // libraries. Preserve their playable side, remove the accidental article
    // copies, and normalize the subscription to one library.
    await customStatement(
      "DELETE FROM search_index WHERE kind = 'article' AND entity_id IN ("
      'SELECT articles.id FROM articles INNER JOIN feeds '
      'ON feeds.id = articles.feed_id WHERE feeds.kind = 2 '
      'AND EXISTS (SELECT 1 FROM episodes WHERE episodes.feed_id = feeds.id))',
    );
    await customStatement(
      'DELETE FROM articles WHERE feed_id IN ('
      'SELECT feeds.id FROM feeds WHERE feeds.kind = 2 '
      'AND EXISTS (SELECT 1 FROM episodes WHERE episodes.feed_id = feeds.id))',
    );
    await customStatement(
      'UPDATE feeds SET kind = 0 WHERE kind = 2 '
      'AND EXISTS (SELECT 1 FROM episodes WHERE episodes.feed_id = feeds.id)',
    );
    await customStatement('UPDATE feeds SET kind = 1 WHERE kind = 2');
  }

  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_feeds_last_refresh '
      'ON feeds(subscribed, last_refresh)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_feeds_protocol '
      'ON feeds(subscribed, protocol, kind)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_episodes_feed_date '
      'ON episodes(feed_id, published_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_episodes_global_date '
      'ON episodes(published_at DESC, discovered_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_articles_feed_date '
      'ON articles(feed_id, published_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_articles_global_date '
      'ON articles(published_at DESC, discovered_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_articles_unread_date '
      'ON articles(read_at, published_at DESC, discovered_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_episodes_starred '
      'ON episodes(starred, published_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_articles_starred '
      'ON articles(starred, published_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_article_attachments '
      'ON article_attachments(article_id, position)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_nostr_relays_feed '
      'ON nostr_relays(feed_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_episodes_pending_automation '
      'ON episodes(feed_id, published_at DESC, discovered_at DESC) '
      'WHERE automation_applied = 0',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_downloads_status '
      'ON media_downloads(status, updated_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_progress_completed '
      'ON playback_progresses(completed, updated_at DESC)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_chapters_episode '
      'ON chapters(episode_id, start_ms)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transcripts_episode '
      'ON transcripts(episode_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_queue_sort ON queue_entries(sort_key)',
    );
  }

  Future<void> _createSearchIndex() async {
    await customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5("
      "entity_id UNINDEXED, kind UNINDEXED, title, body, feed_title, "
      "tokenize='unicode61 remove_diacritics 2')",
    );
  }

  Stream<List<Feed>> watchFeeds() {
    return (select(feeds)
          ..where((row) => row.subscribed.equals(true))
          ..orderBy([
            (row) => OrderingTerm.asc(row.title),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .watch();
  }

  Stream<List<Feed>> watchAllFeeds() {
    return (select(feeds)..orderBy([
          (row) => OrderingTerm.asc(row.title),
          (row) => OrderingTerm.asc(row.id),
        ]))
        .watch();
  }

  Stream<List<Episode>> watchRecentEpisodes({int limit = 50}) {
    final query =
        select(
            episodes,
          ).join([innerJoin(feeds, feeds.id.equalsExp(episodes.feedId))])
          ..where(
            feeds.subscribed.equals(true) &
                feeds.kind.equals(FeedKind.podcast.index),
          )
          ..orderBy([
            OrderingTerm.desc(episodes.publishedAt),
            OrderingTerm.desc(episodes.discoveredAt),
            OrderingTerm.asc(episodes.id),
          ])
          ..limit(limit);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(episodes)).toList(),
    );
  }

  Stream<List<Episode>> watchNewEpisodes({int limit = 50}) {
    final query =
        select(episodes).join([
            innerJoin(feeds, feeds.id.equalsExp(episodes.feedId)),
            leftOuterJoin(
              playbackProgresses,
              playbackProgresses.episodeId.equalsExp(episodes.id),
            ),
          ])
          ..where(
            feeds.subscribed.equals(true) &
                feeds.kind.equals(FeedKind.podcast.index) &
                episodes.played.equals(false) &
                (playbackProgresses.episodeId.isNull() |
                    (playbackProgresses.completed.equals(false) &
                        playbackProgresses.positionMs.isSmallerOrEqualValue(
                          0,
                        ))),
          )
          ..orderBy([
            OrderingTerm.desc(episodes.publishedAt),
            OrderingTerm.desc(episodes.discoveredAt),
            OrderingTerm.asc(episodes.id),
          ])
          ..limit(limit);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(episodes)).toList(),
    );
  }

  Stream<List<Episode>> watchInProgressEpisodes({int limit = 50}) {
    final query =
        select(episodes).join([
            innerJoin(feeds, feeds.id.equalsExp(episodes.feedId)),
            innerJoin(
              playbackProgresses,
              playbackProgresses.episodeId.equalsExp(episodes.id),
            ),
          ])
          ..where(
            feeds.subscribed.equals(true) &
                feeds.kind.equals(FeedKind.podcast.index) &
                episodes.played.equals(false) &
                playbackProgresses.completed.equals(false) &
                playbackProgresses.positionMs.isBiggerThanValue(0),
          )
          ..orderBy([
            OrderingTerm.desc(playbackProgresses.updatedAt),
            OrderingTerm.desc(episodes.publishedAt),
            OrderingTerm.desc(episodes.discoveredAt),
            OrderingTerm.asc(episodes.id),
          ])
          ..limit(limit);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(episodes)).toList(),
    );
  }

  Stream<List<Article>> watchUnreadArticles({int limit = 50}) {
    final query =
        select(
            articles,
          ).join([innerJoin(feeds, feeds.id.equalsExp(articles.feedId))])
          ..where(feeds.subscribed.equals(true) & articles.readAt.isNull())
          ..orderBy([
            OrderingTerm.desc(articles.publishedAt),
            OrderingTerm.desc(articles.discoveredAt),
            OrderingTerm.asc(articles.id),
          ])
          ..limit(limit);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(articles)).toList(),
    );
  }

  Stream<List<Article>> watchStarredArticles({required int limit}) {
    final query = select(articles)
      ..where((row) => row.starred.equals(true))
      ..orderBy([
        (row) => OrderingTerm.desc(row.publishedAt),
        (row) => OrderingTerm.desc(row.discoveredAt),
        (row) => OrderingTerm.asc(row.id),
      ]);
    query.limit(limit);
    return query.watch();
  }

  Stream<int> watchUnreadArticleCount() {
    final count = articles.id.count();
    final query =
        selectOnly(
            articles,
          ).join([innerJoin(feeds, feeds.id.equalsExp(articles.feedId))])
          ..addColumns([count])
          ..where(feeds.subscribed.equals(true) & articles.readAt.isNull());
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  Stream<Map<String, int>> watchUnreadArticleCountsByFeed() {
    final count = articles.id.count();
    final query =
        selectOnly(
            articles,
          ).join([innerJoin(feeds, feeds.id.equalsExp(articles.feedId))])
          ..addColumns([articles.feedId, count])
          ..where(feeds.subscribed.equals(true) & articles.readAt.isNull())
          ..groupBy([articles.feedId]);
    return query.watch().map((rows) {
      final counts = <String, int>{};
      for (final row in rows) {
        final feedId = row.read(articles.feedId);
        if (feedId != null) counts[feedId] = row.read(count) ?? 0;
      }
      return counts;
    });
  }

  Stream<int> watchStarredArticleCount() {
    final count = articles.id.count();
    return (selectOnly(articles)
          ..addColumns([count])
          ..where(articles.starred.equals(true)))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  Stream<int> watchStarredEpisodeCount() {
    final count = episodes.id.count();
    return (selectOnly(episodes)
          ..addColumns([count])
          ..where(episodes.starred.equals(true)))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  Stream<List<Episode>> watchStarredEpisodes({required int limit}) {
    final query = select(episodes)
      ..where((row) => row.starred.equals(true))
      ..orderBy([
        (row) => OrderingTerm.desc(row.publishedAt),
        (row) => OrderingTerm.desc(row.discoveredAt),
        (row) => OrderingTerm.asc(row.id),
      ]);
    query.limit(limit);
    return query.watch();
  }

  Stream<List<MediaDownload>> watchDownloads() {
    return (select(mediaDownloads)..orderBy([
          (row) => OrderingTerm.desc(row.updatedAt),
          (row) => OrderingTerm.asc(row.episodeId),
        ]))
        .watch();
  }

  Stream<List<Episode>> watchDownloadedEpisodes() {
    final query = select(episodes).join([
      innerJoin(
        mediaDownloads,
        mediaDownloads.episodeId.equalsExp(episodes.id),
      ),
    ]);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(episodes)).toList(),
    );
  }

  Stream<List<Episode>> watchQueuedEpisodes() {
    final query = select(episodes).join([
      innerJoin(queueEntries, queueEntries.episodeId.equalsExp(episodes.id)),
    ]);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(episodes)).toList(),
    );
  }

  Future<void> stageQueueAdditions(Iterable<String> episodeIds) async {
    final requested = episodeIds.toSet().toList(growable: false);
    if (requested.isEmpty) return;
    await transaction(() async {
      final queued = await select(queueEntries).get();
      final pending = await select(pendingQueueAdds).get();
      final excluded = {
        ...queued.map((entry) => entry.episodeId),
        ...pending.map((entry) => entry.episodeId),
      };
      var sortKey = pending.fold(
        -1024,
        (maximum, entry) => entry.sortKey > maximum ? entry.sortKey : maximum,
      );
      final now = DateTime.now().toUtc();
      await batch((batch) {
        for (final episodeId in requested) {
          if (excluded.contains(episodeId)) continue;
          sortKey += 1024;
          batch.insert(
            pendingQueueAdds,
            PendingQueueAddsCompanion.insert(
              episodeId: episodeId,
              sortKey: sortKey,
              addedAt: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
        }
      });
    });
  }

  Future<List<String>> mergePendingQueueAdditions() {
    return transaction(() async {
      final pending = await (select(
        pendingQueueAdds,
      )..orderBy([(row) => OrderingTerm.asc(row.sortKey)])).get();
      if (pending.isEmpty) return const <String>[];
      final queued = await select(queueEntries).get();
      final queuedIds = queued.map((entry) => entry.episodeId).toSet();
      var sortKey = queued.fold(
        -1024,
        (maximum, entry) => entry.sortKey > maximum ? entry.sortKey : maximum,
      );
      await batch((batch) {
        for (final entry in pending) {
          if (queuedIds.add(entry.episodeId)) {
            sortKey += 1024;
            batch.insert(
              queueEntries,
              QueueEntriesCompanion.insert(
                id: stableContentId('queue', entry.episodeId),
                episodeId: entry.episodeId,
                sortKey: sortKey,
                addedAt: entry.addedAt,
              ),
              mode: InsertMode.insertOrIgnore,
            );
          }
        }
      });
      return pending.map((entry) => entry.episodeId).toList(growable: false);
    });
  }

  Future<void> acknowledgePendingQueueAdditions(
    Iterable<String> episodeIds,
  ) async {
    final ids = episodeIds.toSet().toList(growable: false);
    for (var start = 0; start < ids.length; start += safeVariableBatchSize) {
      final end = math.min(start + safeVariableBatchSize, ids.length);
      await (delete(
        pendingQueueAdds,
      )..where((row) => row.episodeId.isIn(ids.sublist(start, end)))).go();
    }
  }

  Stream<List<Bookmark>> watchBookmarksForEpisode(String episodeId) {
    return (select(bookmarks)
          ..where((row) => row.episodeId.equals(episodeId))
          ..orderBy([(row) => OrderingTerm.asc(row.positionMs)]))
        .watch();
  }

  Stream<PlaybackProgressesData?> watchPlaybackProgressForEpisode(
    String episodeId,
  ) {
    return (select(
      playbackProgresses,
    )..where((row) => row.episodeId.equals(episodeId))).watchSingleOrNull();
  }

  Stream<List<PlaybackProgressesData>> watchIncompletePlaybackProgresses() {
    return (select(playbackProgresses)..where(
          (row) =>
              row.completed.equals(false) & row.positionMs.isBiggerThanValue(0),
        ))
        .watch();
  }

  Future<Feed?> feedById(String id) {
    return (select(feeds)..where((row) => row.id.equals(id))).getSingleOrNull();
  }

  Stream<Feed?> watchFeedById(String id) {
    return (select(
      feeds,
    )..where((row) => row.id.equals(id))).watchSingleOrNull();
  }

  Future<Feed?> feedByUrl(String url) {
    return (select(
      feeds,
    )..where((row) => row.feedUrl.equals(url))).getSingleOrNull();
  }

  Future<Episode?> episodeById(String id) {
    return (select(
      episodes,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
  }

  Stream<Episode?> watchEpisodeById(String id) {
    return (select(
      episodes,
    )..where((row) => row.id.equals(id))).watchSingleOrNull();
  }

  Future<Article?> articleById(String id) {
    return (select(
      articles,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
  }

  Stream<Article?> watchArticleById(String id) {
    return (select(
      articles,
    )..where((row) => row.id.equals(id))).watchSingleOrNull();
  }

  Future<List<ArticleAttachment>> attachmentsForArticle(String articleId) {
    return (select(articleAttachments)
          ..where((row) => row.articleId.equals(articleId))
          ..orderBy([
            (row) => OrderingTerm.asc(row.position),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .get();
  }

  Selectable<Episode> _episodesForFeedQuery(
    String feedId, {
    required int limit,
  }) {
    final query = select(episodes)
      ..where((row) => row.feedId.equals(feedId))
      ..orderBy([
        (row) => OrderingTerm.desc(row.publishedAt),
        (row) => OrderingTerm.desc(row.discoveredAt),
        (row) => OrderingTerm.asc(row.id),
      ]);
    query.limit(limit);
    return query;
  }

  Future<List<Episode>> episodesForFeed(String feedId, {required int limit}) {
    return _episodesForFeedQuery(feedId, limit: limit).get();
  }

  Stream<List<Episode>> watchFilteredEpisodesForFeed({
    required String feedId,
    required int limit,
    required ContentSort sort,
    required EpisodeFeedFilter filter,
    String query = '',
  }) {
    final statement = select(episodes).join([
      if (filter == EpisodeFeedFilter.inProgress)
        leftOuterJoin(
          playbackProgresses,
          playbackProgresses.episodeId.equalsExp(episodes.id),
        ),
      if (filter == EpisodeFeedFilter.downloaded)
        leftOuterJoin(
          mediaDownloads,
          mediaDownloads.episodeId.equalsExp(episodes.id),
        ),
    ])..where(episodes.feedId.equals(feedId));
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isNotEmpty) {
      statement.where(
        episodes.title.lower().contains(normalizedQuery) |
            episodes.description.lower().contains(normalizedQuery),
      );
    }
    statement.where(switch (filter) {
      EpisodeFeedFilter.all => const Constant(true),
      EpisodeFeedFilter.unplayed => episodes.played.equals(false),
      EpisodeFeedFilter.inProgress =>
        episodes.played.equals(false) &
            playbackProgresses.completed.equals(false) &
            playbackProgresses.positionMs.isBiggerThanValue(0),
      EpisodeFeedFilter.saved => episodes.starred.equals(true),
      EpisodeFeedFilter.downloaded => mediaDownloads.status.equals(
        DownloadState.complete.index,
      ),
    });
    statement
      ..orderBy([
        sort == ContentSort.newest
            ? OrderingTerm.desc(episodes.publishedAt)
            : OrderingTerm.asc(episodes.publishedAt),
        sort == ContentSort.newest
            ? OrderingTerm.desc(episodes.discoveredAt)
            : OrderingTerm.asc(episodes.discoveredAt),
        OrderingTerm.asc(episodes.id),
      ])
      ..limit(limit);
    return statement.watch().map(
      (rows) => rows.map((row) => row.readTable(episodes)).toList(),
    );
  }

  Stream<int> watchFilteredEpisodeCountForFeed({
    required String feedId,
    required EpisodeFeedFilter filter,
    String query = '',
  }) {
    final count = episodes.id.count();
    final statement =
        selectOnly(episodes).join([
            if (filter == EpisodeFeedFilter.inProgress)
              leftOuterJoin(
                playbackProgresses,
                playbackProgresses.episodeId.equalsExp(episodes.id),
              ),
            if (filter == EpisodeFeedFilter.downloaded)
              leftOuterJoin(
                mediaDownloads,
                mediaDownloads.episodeId.equalsExp(episodes.id),
              ),
          ])
          ..addColumns([count])
          ..where(episodes.feedId.equals(feedId));
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isNotEmpty) {
      statement.where(
        episodes.title.lower().contains(normalizedQuery) |
            episodes.description.lower().contains(normalizedQuery),
      );
    }
    statement.where(switch (filter) {
      EpisodeFeedFilter.all => const Constant(true),
      EpisodeFeedFilter.unplayed => episodes.played.equals(false),
      EpisodeFeedFilter.inProgress =>
        episodes.played.equals(false) &
            playbackProgresses.completed.equals(false) &
            playbackProgresses.positionMs.isBiggerThanValue(0),
      EpisodeFeedFilter.saved => episodes.starred.equals(true),
      EpisodeFeedFilter.downloaded => mediaDownloads.status.equals(
        DownloadState.complete.index,
      ),
    });
    return statement.watchSingle().map((row) => row.read(count) ?? 0);
  }

  Stream<List<Article>> watchFilteredArticles({
    String? feedId,
    String? category,
    required int limit,
    required ContentSort sort,
    required ArticleFeedFilter filter,
    String query = '',
  }) {
    final statement = select(
      articles,
    ).join([innerJoin(feeds, feeds.id.equalsExp(articles.feedId))]);
    if (feedId == null) {
      statement.where(feeds.subscribed.equals(true));
    } else {
      statement.where(articles.feedId.equals(feedId));
    }
    final categoryIdentity = category?.trim().toLowerCase();
    if (categoryIdentity?.isNotEmpty == true) {
      statement.where(feeds.category.lower().equals(categoryIdentity!));
    }
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isNotEmpty) {
      statement.where(
        articles.title.lower().contains(normalizedQuery) |
            articles.summary.lower().contains(normalizedQuery) |
            articles.author.lower().contains(normalizedQuery),
      );
    }
    statement.where(switch (filter) {
      ArticleFeedFilter.all => const Constant(true),
      ArticleFeedFilter.unread => articles.readAt.isNull(),
      ArticleFeedFilter.saved => articles.starred.equals(true),
    });
    statement
      ..orderBy([
        sort == ContentSort.newest
            ? OrderingTerm.desc(articles.publishedAt)
            : OrderingTerm.asc(articles.publishedAt),
        sort == ContentSort.newest
            ? OrderingTerm.desc(articles.discoveredAt)
            : OrderingTerm.asc(articles.discoveredAt),
        OrderingTerm.asc(articles.id),
      ])
      ..limit(limit);
    return statement.watch().map(
      (rows) => rows.map((row) => row.readTable(articles)).toList(),
    );
  }

  Stream<int> watchFilteredArticleCount({
    String? feedId,
    String? category,
    required ArticleFeedFilter filter,
    String query = '',
  }) {
    final count = articles.id.count();
    final statement = selectOnly(articles).join([
      innerJoin(feeds, feeds.id.equalsExp(articles.feedId)),
    ])..addColumns([count]);
    if (feedId == null) {
      statement.where(feeds.subscribed.equals(true));
    } else {
      statement.where(articles.feedId.equals(feedId));
    }
    final categoryIdentity = category?.trim().toLowerCase();
    if (categoryIdentity?.isNotEmpty == true) {
      statement.where(feeds.category.lower().equals(categoryIdentity!));
    }
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isNotEmpty) {
      statement.where(
        articles.title.lower().contains(normalizedQuery) |
            articles.summary.lower().contains(normalizedQuery) |
            articles.author.lower().contains(normalizedQuery),
      );
    }
    statement.where(switch (filter) {
      ArticleFeedFilter.all => const Constant(true),
      ArticleFeedFilter.unread => articles.readAt.isNull(),
      ArticleFeedFilter.saved => articles.starred.equals(true),
    });
    return statement.watchSingle().map((row) => row.read(count) ?? 0);
  }

  Future<void> indexSearchItem({
    required String entityId,
    required String kind,
    required String title,
    required String body,
    required String feedTitle,
  }) {
    return indexSearchItems([
      SearchIndexEntry(
        entityId: entityId,
        kind: kind,
        title: title,
        body: body,
        feedTitle: feedTitle,
      ),
    ]);
  }

  Future<void> indexSearchItems(Iterable<SearchIndexEntry> items) async {
    final entries = <String, SearchIndexEntry>{};
    for (final item in items) {
      entries['${item.kind}\u0000${item.entityId}'] = item;
    }
    if (entries.isEmpty) return;
    final values = entries.values.toList(growable: false);
    final entityIdsByKind = <String, Set<String>>{};
    for (final item in values) {
      entityIdsByKind.putIfAbsent(item.kind, () => {}).add(item.entityId);
    }
    // FTS5 cannot index its UNINDEXED identity column. Passing every identity
    // through json_each removes old rows in one scan per content kind instead
    // of scanning the virtual table once per refreshed feed item.
    for (final entry in entityIdsByKind.entries) {
      await customStatement(
        'DELETE FROM search_index WHERE kind = ? AND entity_id IN '
        '(SELECT CAST(value AS TEXT) FROM json_each(?))',
        [entry.key, jsonEncode(entry.value.toList())],
      );
    }
    // Keep large backup imports from building one enormous platform message.
    for (var start = 0; start < values.length; start += 500) {
      final end = (start + 500).clamp(0, values.length);
      await batch((batch) {
        for (final item in values.sublist(start, end)) {
          batch.customStatement(
            'INSERT INTO search_index'
            '(entity_id, kind, title, body, feed_title) '
            'VALUES (?, ?, ?, ?, ?)',
            [item.entityId, item.kind, item.title, item.body, item.feedTitle],
          );
        }
      });
    }
  }

  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) async {
    final tokens = rawQuery
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .map((token) => '"${token.replaceAll('"', '""')}"*')
        .join(' ');
    if (tokens.isEmpty) return const [];
    final rows = await customSelect(
      "SELECT entity_id, kind, title, feed_title, "
      "snippet(search_index, 3, '', '', ' … ', 16) AS excerpt "
      "FROM search_index WHERE search_index MATCH ? "
      "ORDER BY bm25(search_index) LIMIT ?",
      variables: [Variable(tokens), Variable(limit)],
      readsFrom: const {},
    ).get();
    return rows
        .map(
          (row) => SearchHit(
            entityId: row.read<String>('entity_id'),
            kind: row.read<String>('kind'),
            title: row.read<String>('title'),
            feedTitle: row.read<String>('feed_title'),
            excerpt: row.read<String>('excerpt'),
          ),
        )
        .toList(growable: false);
  }
}

final class SearchHit {
  const SearchHit({
    required this.entityId,
    required this.kind,
    required this.title,
    required this.feedTitle,
    required this.excerpt,
  });

  final String entityId;
  final String kind;
  final String title;
  final String feedTitle;
  final String excerpt;
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'trickle.sqlite'));
    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        database.execute('PRAGMA journal_mode = WAL');
        database.execute('PRAGMA synchronous = NORMAL');
      },
    );
  });
}
