import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';

part 'app_database.g.dart';

class Feeds extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get feedUrl => text()();
  TextColumn get siteUrl => text().nullable()();
  TextColumn get imageUrl => text().nullable()();
  TextColumn get author => text().nullable()();
  IntColumn get kind => integer().withDefault(const Constant(1))();
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
  DateTimeColumn get publishedAt => dateTime().nullable()();
  DateTimeColumn get discoveredAt => dateTime()();
  DateTimeColumn get readAt => dateTime().nullable()();
  BoolColumn get starred => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
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
    PlaybackProgresses,
    QueueEntries,
    MediaDownloads,
    Chapters,
    Transcripts,
    Bookmarks,
    AppSettings,
    SearchCaches,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _createIndexes();
      await _createSearchIndex();
    },
    onUpgrade: (_, from, to) async {
      if (from != 1 || to != 2) {
        throw StateError('Unsupported database migration from $from to $to.');
      }
      // Version 2 changes feed classification data, not the SQL schema. The
      // idempotent repair runs in beforeOpen after the search index is ready.
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
    await customStatement('DROP INDEX IF EXISTS idx_articles_unread');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_feeds_last_refresh '
      'ON feeds(last_refresh)',
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
      'CREATE INDEX IF NOT EXISTS idx_episodes_automation '
      'ON episodes(feed_id, automation_applied, published_at DESC)',
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

  Stream<List<Feed>> watchPodcastFeeds() {
    return (select(feeds)
          ..where((row) => row.kind.equals(FeedKind.podcast.index))
          ..orderBy([
            (row) => OrderingTerm.asc(row.title),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .watch();
  }

  Stream<List<Feed>> watchReaderFeeds() {
    return (select(feeds)
          ..where((row) => row.kind.equals(FeedKind.reader.index))
          ..orderBy([
            (row) => OrderingTerm.asc(row.title),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .watch();
  }

  Stream<List<Episode>> watchRecentEpisodes({int limit = 50}) {
    return (select(episodes)
          ..orderBy([
            (row) => OrderingTerm.desc(row.publishedAt),
            (row) => OrderingTerm.desc(row.discoveredAt),
            (row) => OrderingTerm.asc(row.id),
          ])
          ..limit(limit))
        .watch();
  }

  Stream<List<Article>> watchUnreadArticles({int limit = 50}) {
    return (select(articles)
          ..where((row) => row.readAt.isNull())
          ..orderBy([
            (row) => OrderingTerm.desc(row.publishedAt),
            (row) => OrderingTerm.desc(row.discoveredAt),
            (row) => OrderingTerm.asc(row.id),
          ])
          ..limit(limit))
        .watch();
  }

  Stream<List<Article>> watchAllArticles({int limit = 200}) {
    return (select(articles)
          ..orderBy([
            (row) => OrderingTerm.desc(row.publishedAt),
            (row) => OrderingTerm.desc(row.discoveredAt),
            (row) => OrderingTerm.asc(row.id),
          ])
          ..limit(limit))
        .watch();
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
    return (selectOnly(articles)
          ..addColumns([count])
          ..where(articles.readAt.isNull()))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  Stream<int> watchArticleCount() {
    final count = articles.id.count();
    return (selectOnly(
      articles,
    )..addColumns([count])).watchSingle().map((row) => row.read(count) ?? 0);
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

  Stream<int> watchCompletedDownloadCount() {
    final count = mediaDownloads.episodeId.count();
    return (selectOnly(mediaDownloads)
          ..addColumns([count])
          ..where(mediaDownloads.status.equals(DownloadState.complete.index)))
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

  Stream<List<Episode>> watchEpisodesForFeed(
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
    return query.watch();
  }

  Stream<List<Article>> watchArticlesForFeed(
    String feedId, {
    required int limit,
  }) {
    final query = select(articles)
      ..where((row) => row.feedId.equals(feedId))
      ..orderBy([
        (row) => OrderingTerm.desc(row.publishedAt),
        (row) => OrderingTerm.desc(row.discoveredAt),
        (row) => OrderingTerm.asc(row.id),
      ]);
    query.limit(limit);
    return query.watch();
  }

  Stream<int> watchEpisodeCountForFeed(String feedId) {
    final count = episodes.id.count();
    return (selectOnly(episodes)
          ..addColumns([count])
          ..where(episodes.feedId.equals(feedId)))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  Stream<int> watchArticleCountForFeed(String feedId) {
    final count = articles.id.count();
    return (selectOnly(articles)
          ..addColumns([count])
          ..where(articles.feedId.equals(feedId)))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  Future<void> indexSearchItem({
    required String entityId,
    required String kind,
    required String title,
    required String body,
    required String feedTitle,
  }) async {
    await customStatement(
      'DELETE FROM search_index WHERE entity_id = ? AND kind = ?',
      [entityId, kind],
    );
    await customStatement(
      'INSERT INTO search_index(entity_id, kind, title, body, feed_title) '
      'VALUES (?, ?, ?, ?, ?)',
      [entityId, kind, title, body, feedTitle],
    );
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
