import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trickle/core/content_filters.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';

void main() {
  late AppDatabase database;
  late _SelectLog queries;

  setUp(() {
    queries = _SelectLog();
    database = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(queries),
    );
  });

  tearDown(() => database.close());

  test(
    'source artwork is bounded, ordered, and excludes content warnings',
    () async {
      await database.customStatement(
        "INSERT INTO feeds(id,title,feed_url,created_at,updated_at) VALUES ('reader','Reader','https://example.test/feed',1,1)",
      );
      await database.customStatement('''
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000)
      INSERT INTO articles(id,feed_id,title,image_url,published_at,discovered_at)
      SELECT 'a'||x,'reader','Article '||x,
        CASE WHEN x=1 THEN 'https://example.test/old.png' ELSE NULL END,x,x FROM n
    ''');
      queries.selects.clear();
      expect(await database.watchRecentFeedImage('reader').first, isNull);
      final statement = queries.selects.single;
      final plan = await database.executor.runSelect(
        'EXPLAIN QUERY PLAN ${statement.$1}',
        statement.$2,
      );
      expect(
        plan.map((row) => row['detail']).join('\n'),
        contains('idx_articles_feed_date'),
      );
      await database.customUpdate(
        '''
      UPDATE articles SET image_url='https://example.test/'||id||'.png',
        content_warning=CASE WHEN id='a10000' THEN 'Sensitive' ELSE NULL END
      WHERE id IN ('a9999','a10000')
    ''',
        updates: {database.articles},
      );
      expect(
        await database.watchRecentFeedImage('reader').first,
        'https://example.test/a9999.png',
      );
      await database.customUpdate(
        "UPDATE articles SET content_warning='' WHERE id='a10000'",
        updates: {database.articles},
      );
      expect(
        await database.watchRecentFeedImage('reader').first,
        'https://example.test/a10000.png',
      );
      expect(await database.watchRecentFeedImage('missing').first, isNull);
    },
  );

  test(
    'large timelines and unread counts use indexes without loading reader bodies',
    () async {
      await database.customStatement(
        "INSERT INTO feeds(id,title,feed_url,created_at,updated_at) VALUES ('reader','Reader','https://example.test/feed',1,1)",
      );
      await database.customStatement('''
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000)
      INSERT INTO articles(id,feed_id,title,content_html,published_at,discovered_at)
      SELECT 'a'||x,'reader','Article '||x,'<p>Retained body</p>',x,x FROM n
    ''');
      queries.selects.clear();
      final items = await database
          .watchFilteredArticles(
            limit: 100,
            sort: ContentSort.newest,
            filter: ArticleFeedFilter.all,
          )
          .first;
      final statement = queries.selects.single;
      final plan = await database.executor.runSelect(
        'EXPLAIN QUERY PLAN ${statement.$1}',
        statement.$2,
      );
      expect(items, hasLength(100));
      expect(items.first.id, 'a10000');
      expect(items.last.id, 'a9901');
      expect(items.every((item) => item.contentHtml == null), isTrue);
      expect(
        (await database.articleById('a10000'))?.contentHtml,
        '<p>Retained body</p>',
      );
      final details = plan.map((row) => row['detail']).join('\n');
      expect(details, contains('idx_articles_global_date'));
      expect(details, isNot(contains('TEMP B-TREE')));

      queries.selects.clear();
      expect(await database.watchUnreadArticleCountsByFeed().first, {
        'reader': 10000,
      });
      final countStatement = queries.selects.single;
      final countPlan = await database.executor.runSelect(
        'EXPLAIN QUERY PLAN ${countStatement.$1}',
        countStatement.$2,
      );
      final countDetails = countPlan.map((row) => row['detail']).join('\n');
      expect(countDetails, contains('COVERING INDEX idx_articles_unread_feed'));
      expect(countDetails, isNot(contains('TEMP B-TREE')));
    },
  );

  test(
    'version 8 migration adds indexed refresh IDs without re-keying items',
    () async {
      await database.close();
      final underlying = sqlite3.openInMemory();
      addTearDown(underlying.close);
      database = AppDatabase.forTesting(
        NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
      );
      await database.customStatement(
        "INSERT INTO feeds(id,title,feed_url,kind,created_at,updated_at) VALUES ('podcast','Podcast','https://example.test/feed',0,1,1)",
      );
      await database.customStatement(
        "INSERT INTO episodes(id,feed_id,title,enclosure_url,discovered_at,queue_automation_applied) VALUES ('episode','podcast','Episode','https://example.test/audio.mp3',1,1)",
      );
      await database.customStatement(
        "INSERT INTO playback_progresses(episode_id,position_ms,updated_at) VALUES ('episode',18000,1)",
      );
      await database.close();
      _removeRefreshIdentitySchema(underlying);
      underlying.userVersion = 8;
      database = AppDatabase.forTesting(
        NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
      );

      final episode = (await database.episodeById('episode'))!;
      expect(episode.refreshId, isNull);
      expect(episode.queueAutomationApplied, isTrue);
      expect(
        (await database.watchPlaybackProgressForEpisode('episode').first)
            ?.positionMs,
        18000,
      );
      for (final table in ['episodes', 'articles']) {
        final plan = await database
            .customSelect(
              'EXPLAIN QUERY PLAN SELECT * FROM $table WHERE id IN (?, ?) OR refresh_id IN (?, ?)',
              variables: const [
                Variable('a'),
                Variable('b'),
                Variable('a'),
                Variable('b'),
              ],
            )
            .get();
        expect(
          plan.map((row) => row.read<String>('detail')).join('\n'),
          contains('idx_${table}_refresh_id'),
        );
      }
    },
  );

  test('version 9 upgrade retains items and adds Nostr deletion storage', () async {
    await database.close();
    final underlying = sqlite3.openInMemory();
    addTearDown(underlying.close);
    database = AppDatabase.forTesting(
      NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
    );
    await database.customStatement(
      "INSERT INTO feeds(id,title,feed_url,created_at,updated_at) VALUES ('reader','Reader','https://example.test/feed',1,1)",
    );
    await database.customStatement(
      "INSERT INTO articles(id,feed_id,title,discovered_at,starred) VALUES ('saved','reader','Saved',1,1)",
    );
    await database.customStatement(
      "INSERT INTO episodes(id,feed_id,title,enclosure_url,discovered_at) VALUES ('episode','reader','Episode','https://example.test/audio.mp3',1)",
    );
    await database.customStatement(
      "INSERT INTO playback_progresses(episode_id,position_ms,updated_at) VALUES ('episode',18000,1)",
    );
    await database.customStatement(
      "INSERT INTO queue_entries(id,episode_id,sort_key,added_at) VALUES ('queued','episode',1024,1)",
    );
    await database.close();
    underlying.execute('DROP TABLE nostr_deletions');
    underlying.userVersion = 9;
    database = AppDatabase.forTesting(
      NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
    );

    expect((await database.articleById('saved'))?.starred, isTrue);
    expect((await database.watchQueuedEpisodes().first).single.id, 'episode');
    expect(
      (await database.watchPlaybackProgressForEpisode('episode').first)
          ?.positionMs,
      18000,
    );
    expect(await database.select(database.nostrDeletions).get(), isEmpty);
    await database
        .into(database.nostrDeletions)
        .insert(
          NostrDeletionsCompanion.insert(
            feedId: 'reader',
            target: 'deleted-event',
            deletedAt: DateTime.utc(2026),
          ),
        );
    await database.delete(database.feeds).go();
    expect(await database.select(database.nostrDeletions).get(), isEmpty);
    expect(
      await database.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
    );
  });

  test('version 5 migration preserves enriched search content and item state', () async {
    await database.close();
    final underlying = sqlite3.openInMemory();
    addTearDown(underlying.close);
    database = AppDatabase.forTesting(
      NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
    );
    await database.customStatement(
      "INSERT INTO feeds(id,title,feed_url,created_at,updated_at) VALUES ('reader','Reader','https://example.test/feed',1,1)",
    );
    await database.customStatement(
      "INSERT INTO articles(id,feed_id,title,content_html,discovered_at,read_at,starred) VALUES ('article','reader','Title','<p>Offline content</p>',1,2,1)",
    );
    await database.indexSearchItem(
      entityId: 'article',
      kind: 'article',
      title: 'Title',
      body: 'Enriched search content',
      feedTitle: 'Reader',
    );
    for (final action in ['insert', 'update', 'delete']) {
      await database.customStatement('DROP TRIGGER search_documents_$action');
    }
    await database.customStatement('DROP TABLE search_index');
    await database.customStatement(
      "CREATE VIRTUAL TABLE search_index USING fts5(entity_id UNINDEXED, kind UNINDEXED, title, body, feed_title, tokenize='unicode61 remove_diacritics 2')",
    );
    await database.customStatement(
      'INSERT INTO search_index SELECT entity_id,kind,title,body,feed_title FROM search_documents',
    );
    await database.customStatement('DROP TABLE search_documents');
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN reader_html',
    );
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN reader_fetched_at',
    );
    await database.close();
    _removeRefreshIdentitySchema(underlying);
    underlying.userVersion = 5;
    underlying.execute(
      'ALTER TABLE episodes DROP COLUMN queue_automation_applied',
    );
    database = AppDatabase.forTesting(
      NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
    );
    expect(await database.search('enriched'), hasLength(1));
    final article = await database.articleById('article');
    expect(article?.starred, isTrue);
    expect(article?.readAt, isNotNull);
    expect(article?.contentHtml, '<p>Offline content</p>');
    expect(article?.readerHtml, isNull);
    expect(article?.readerFetchedAt, isNull);
    await database.customStatement(
      "DELETE FROM search_documents WHERE kind='article' AND entity_id='article'",
    );
    expect(await database.search('enriched'), isEmpty);
    expect((await database.articleById('article'))?.starred, isTrue);
  });

  test(
    'article queries combine category, state, search, and sorting',
    () async {
      final now = DateTime.utc(2026, 8, 22);
      for (final (id, category) in const [
        ('science', 'Science'),
        ('news', 'News'),
      ]) {
        await database
            .into(database.feeds)
            .insert(
              FeedsCompanion.insert(
                id: id,
                title: id,
                feedUrl: 'https://example.test/$id.xml',
                category: Value(category),
                kind: Value(FeedKind.reader.index),
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      for (final article in [
        ArticlesCompanion.insert(
          id: 'new',
          feedId: 'science',
          title: 'New Signal',
          discoveredAt: now,
        ),
        ArticlesCompanion.insert(
          id: 'old',
          feedId: 'science',
          title: 'Old signal',
          discoveredAt: now.subtract(const Duration(days: 1)),
        ),
        ArticlesCompanion.insert(
          id: 'read',
          feedId: 'science',
          title: 'Read Signal',
          discoveredAt: now.subtract(const Duration(days: 2)),
          readAt: Value(now),
        ),
        ArticlesCompanion.insert(
          id: 'other-category',
          feedId: 'news',
          title: 'News Signal',
          discoveredAt: now,
        ),
      ]) {
        await database.into(database.articles).insert(article);
      }

      final query = (
        categoryFeedIdsJson: '["science"]',
        sort: ContentSort.oldest,
        filter: ArticleFeedFilter.unread,
        query: 'SIGNAL',
      );
      final items = await database
          .watchFilteredArticles(
            categoryFeedIdsJson: query.categoryFeedIdsJson,
            limit: 100,
            sort: query.sort,
            filter: query.filter,
            query: query.query,
          )
          .first;
      final count = await database
          .watchFilteredArticleCount(
            categoryFeedIdsJson: query.categoryFeedIdsJson,
            filter: query.filter,
            query: query.query,
          )
          .first;

      expect(items.map((article) => article.id), ['old', 'new']);
      expect(count, 2);

      await (database.update(database.feeds)
            ..where((feed) => feed.id.equals('science')))
          .write(const FeedsCompanion(subscribed: Value(false)));
      final retained = await database
          .watchFilteredArticles(
            feedId: 'science',
            limit: 100,
            sort: ContentSort.newest,
            filter: ArticleFeedFilter.all,
          )
          .first;
      final hiddenFromTimeline = await database
          .watchFilteredArticleCount(
            categoryFeedIdsJson: '["science"]',
            filter: ArticleFeedFilter.all,
          )
          .first;
      expect(retained.map((article) => article.id), ['new', 'old', 'read']);
      expect(hiddenFromTimeline, 0);
    },
  );

  test('episode queries apply playback and download filters', () async {
    final now = DateTime.utc(2026, 8, 22);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'podcast',
            title: 'Podcast',
            feedUrl: 'https://example.test/podcast.xml',
            kind: Value(FeedKind.podcast.index),
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final (id, title, discoveredAt) in [
      ('progress', 'Signal in motion', now.subtract(const Duration(hours: 2))),
      ('download', 'Signal offline', now.subtract(const Duration(hours: 1))),
      ('other', 'Other episode', now),
    ]) {
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: id,
              feedId: 'podcast',
              title: title,
              enclosureUrl: 'https://example.test/$id.mp3',
              discoveredAt: discoveredAt,
            ),
          );
    }
    await database
        .into(database.playbackProgresses)
        .insert(
          PlaybackProgressesCompanion.insert(
            episodeId: 'progress',
            positionMs: const Value(1000),
            updatedAt: now,
          ),
        );
    await database
        .into(database.mediaDownloads)
        .insert(
          MediaDownloadsCompanion.insert(
            episodeId: 'download',
            taskId: 'task',
            status: Value(DownloadState.complete.index),
            updatedAt: now,
          ),
        );

    for (final entry in {
      EpisodeFeedFilter.all: ['download', 'progress'],
      EpisodeFeedFilter.unplayed: ['download', 'progress'],
      EpisodeFeedFilter.inProgress: ['progress'],
      EpisodeFeedFilter.saved: <String>[],
      EpisodeFeedFilter.downloaded: ['download'],
    }.entries) {
      final count = await database
          .watchFilteredEpisodeCountForFeed(
            feedId: 'podcast',
            filter: entry.key,
            query: 'signal',
          )
          .first;
      expect(count, entry.value.length, reason: entry.key.name);
      for (final sort in ContentSort.values) {
        final rows = await database
            .watchFilteredEpisodesForFeed(
              feedId: 'podcast',
              limit: 100,
              sort: sort,
              filter: entry.key,
              query: 'SIGNAL',
            )
            .first;
        expect(
          rows.map((episode) => episode.id),
          sort == ContentSort.newest ? entry.value : entry.value.reversed,
          reason: '${entry.key.name}, ${sort.name}',
        );
      }
    }
  });

  test('episode children cascade when a feed is deleted', () async {
    final now = DateTime.utc(2026, 7, 14);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.com/feed.xml',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.episodes)
        .insert(
          EpisodesCompanion.insert(
            id: 'episode',
            feedId: 'feed',
            title: 'Episode',
            enclosureUrl: 'https://example.com/audio.mp3',
            discoveredAt: now,
          ),
        );
    await database
        .into(database.playbackProgresses)
        .insert(
          PlaybackProgressesCompanion.insert(
            episodeId: 'episode',
            updatedAt: now,
          ),
        );
    await database
        .into(database.queueEntries)
        .insert(
          QueueEntriesCompanion.insert(
            id: 'queue',
            episodeId: 'episode',
            sortKey: 0,
            addedAt: now,
          ),
        );
    await database
        .into(database.pendingQueueAdds)
        .insert(
          PendingQueueAddsCompanion.insert(
            episodeId: 'episode',
            sortKey: 0,
            addedAt: now,
          ),
        );
    await database
        .into(database.bookmarks)
        .insert(
          BookmarksCompanion.insert(
            id: 'bookmark',
            episodeId: 'episode',
            positionMs: 1000,
            createdAt: now,
          ),
        );

    await (database.delete(
      database.feeds,
    )..where((row) => row.id.equals('feed'))).go();

    expect(await database.select(database.episodes).get(), isEmpty);
    expect(await database.select(database.playbackProgresses).get(), isEmpty);
    expect(await database.select(database.queueEntries).get(), isEmpty);
    expect(await database.select(database.pendingQueueAdds).get(), isEmpty);
    expect(await database.select(database.bookmarks).get(), isEmpty);
  });

  test('foreign keys reject orphan episode state', () async {
    final insert = database
        .into(database.bookmarks)
        .insert(
          BookmarksCompanion.insert(
            id: 'bookmark',
            episodeId: 'missing',
            positionMs: 0,
            createdAt: DateTime.utc(2026, 7, 14),
          ),
        );
    await expectLater(insert, throwsA(anything));
  });

  test('library search is case insensitive', () async {
    await database.indexSearchItem(
      entityId: 'episode',
      kind: 'episode',
      title: 'Mixed Case Signal',
      body: 'Technology',
      feedTitle: 'Example Podcast',
    );

    expect(await database.search('SIGNAL'), hasLength(1));
    expect(await database.search('signal'), hasLength(1));
  });

  test('bulk search indexing scales past SQLite variable limits', () async {
    await database.indexSearchItems([
      for (var index = 0; index < 1100; index++)
        SearchIndexEntry(
          entityId: 'episode-$index',
          kind: 'episode',
          title: index == 1099 ? 'Unique scaling target' : 'Episode $index',
          body: '',
          feedTitle: 'Example Podcast',
        ),
    ]);

    final results = await database.search('unique scaling target');

    expect(results, hasLength(1));
    expect(results.single.entityId, 'episode-1099');
  });

  test(
    'search updates preserve document identity and skip unchanged text',
    () async {
      await database.indexSearchItems(const [
        SearchIndexEntry(
          entityId: 'shared',
          kind: 'episode',
          title: 'Episode scaling marker',
          body: '',
          feedTitle: 'Podcast',
        ),
        SearchIndexEntry(
          entityId: 'shared',
          kind: 'article',
          title: 'Article scaling marker',
          body: '',
          feedTitle: 'Feed',
        ),
      ]);

      final before = await database
          .customSelect(
            'SELECT rowid, kind FROM search_documents ORDER BY rowid',
          )
          .get();

      await database.indexSearchItem(
        entityId: 'shared',
        kind: 'article',
        title: 'Updated article marker',
        body: '',
        feedTitle: 'Feed',
      );

      expect(await database.search('episode scaling marker'), hasLength(1));
      expect(await database.search('article scaling marker'), isEmpty);
      expect(await database.search('updated article marker'), hasLength(1));
      final after = await database
          .customSelect(
            'SELECT rowid, kind FROM search_documents ORDER BY rowid',
          )
          .get();
      expect(after.map((row) => row.data), before.map((row) => row.data));
      final changesBefore = await database
          .customSelect('SELECT total_changes() AS count')
          .getSingle();
      await database.indexSearchItem(
        entityId: 'shared',
        kind: 'article',
        title: 'Updated article marker',
        body: '',
        feedTitle: 'Feed',
      );
      final changesAfter = await database
          .customSelect('SELECT total_changes() AS count')
          .getSingle();
      expect(changesAfter.read<int>('count'), changesBefore.read<int>('count'));
    },
  );

  test(
    'shared status progress excludes played history but preserves completion flags',
    () async {
      final now = DateTime.utc(2026, 7, 24);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'feed',
              title: 'Feed',
              feedUrl: 'https://example.com/feed.xml',
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final id in const ['partial', 'complete', 'completed-progress']) {
        await database
            .into(database.episodes)
            .insert(
              EpisodesCompanion.insert(
                id: id,
                feedId: 'feed',
                title: id,
                enclosureUrl: 'https://example.com/$id.mp3',
                discoveredAt: now,
                played: Value(id == 'complete'),
              ),
            );
      }
      await database.batch((batch) {
        batch.insertAll(database.playbackProgresses, [
          PlaybackProgressesCompanion.insert(
            episodeId: 'partial',
            positionMs: const Value(1000),
            updatedAt: now,
          ),
          PlaybackProgressesCompanion.insert(
            episodeId: 'complete',
            positionMs: const Value(2000),
            completed: const Value(true),
            updatedAt: now,
          ),
          PlaybackProgressesCompanion.insert(
            episodeId: 'completed-progress',
            completed: const Value(true),
            updatedAt: now,
          ),
        ]);
      });

      final progresses = await database.watchEpisodeStatusProgresses().first;

      expect(progresses.map((progress) => progress.episodeId).toSet(), {
        'partial',
        'completed-progress',
      });
    },
  );

  test('podcast status views separate new and in-progress episodes', () async {
    final now = DateTime.utc(2026, 7, 29);
    await database.batch((batch) {
      batch.insertAll(database.feeds, [
        FeedsCompanion.insert(
          id: 'podcast',
          title: 'Podcast',
          feedUrl: 'https://example.com/podcast.xml',
          kind: Value(FeedKind.podcast.index),
          createdAt: now,
          updatedAt: now,
        ),
        FeedsCompanion.insert(
          id: 'reader',
          title: 'Reader',
          feedUrl: 'https://example.com/reader.xml',
          kind: Value(FeedKind.reader.index),
          createdAt: now,
          updatedAt: now,
        ),
        FeedsCompanion.insert(
          id: 'unsubscribed',
          title: 'Unsubscribed',
          feedUrl: 'https://example.com/unsubscribed.xml',
          kind: Value(FeedKind.podcast.index),
          subscribed: const Value(false),
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      batch.insertAll(database.episodes, [
        for (final entry in const [
          ('new', 'podcast', false),
          ('partial-newer', 'podcast', false),
          ('partial-older', 'podcast', false),
          ('completed', 'podcast', false),
          ('played', 'podcast', true),
          ('reader-new', 'reader', false),
          ('unsubscribed-new', 'unsubscribed', false),
          ('unsubscribed-partial', 'unsubscribed', false),
          ('reader-partial', 'reader', false),
        ])
          EpisodesCompanion.insert(
            id: entry.$1,
            feedId: entry.$2,
            title: entry.$1,
            enclosureUrl: 'https://example.com/${entry.$1}.mp3',
            discoveredAt: now,
            played: Value(entry.$3),
          ),
      ]);
      batch.insertAll(database.playbackProgresses, [
        for (final id in ['unsubscribed-partial', 'reader-partial'])
          PlaybackProgressesCompanion.insert(
            episodeId: id,
            positionMs: const Value(1000),
            updatedAt: now.subtract(const Duration(hours: 2)),
          ),
        PlaybackProgressesCompanion.insert(
          episodeId: 'partial-newer',
          positionMs: const Value(2000),
          updatedAt: now,
        ),
        PlaybackProgressesCompanion.insert(
          episodeId: 'partial-older',
          positionMs: const Value(1000),
          updatedAt: now.subtract(const Duration(hours: 1)),
        ),
        PlaybackProgressesCompanion.insert(
          episodeId: 'completed',
          positionMs: const Value(3000),
          completed: const Value(true),
          completedAt: Value(now),
          updatedAt: now,
        ),
      ]);
    });

    final newEpisodes = await database.watchNewEpisodes().first;
    final inProgress = await database.watchInProgressEpisodes().first;

    expect(newEpisodes.map((episode) => episode.id), ['new']);
    expect(await database.watchNewEpisodeCount().first, 1);
    expect(inProgress.map((episode) => episode.id), [
      'partial-newer',
      'partial-older',
      'unsubscribed-partial',
    ]);
    final unplayed = await database
        .watchFilteredEpisodesForFeed(
          feedId: 'podcast',
          limit: 20,
          sort: ContentSort.newest,
          filter: EpisodeFeedFilter.unplayed,
        )
        .first;
    expect(unplayed.map((episode) => episode.id).toSet(), {
      'new',
      'partial-newer',
      'partial-older',
    });
    expect(
      await database
          .watchFilteredEpisodeCountForFeed(
            feedId: 'podcast',
            filter: EpisodeFeedFilter.unplayed,
          )
          .first,
      unplayed.length,
    );
    await database
        .into(database.playbackProgresses)
        .insert(
          PlaybackProgressesCompanion.insert(
            episodeId: 'new',
            positionMs: const Value(1000),
            updatedAt: now,
          ),
        );
    expect(await database.watchNewEpisodeCount().first, 0);
  });

  test('podcast automation uses one targeted pending-item index', () async {
    final indexes = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name LIKE 'idx_episodes_%automation'",
        )
        .get();
    final plan = await database
        .customSelect(
          'EXPLAIN QUERY PLAN SELECT * FROM episodes '
          'WHERE automation_applied = 0 '
          'ORDER BY feed_id, published_at DESC, discovered_at DESC',
        )
        .get();

    expect(indexes.map((row) => row.read<String>('name')), [
      'idx_episodes_pending_automation',
    ]);
    expect(
      plan.map((row) => row.read<String>('detail')).join('\n'),
      contains('idx_episodes_pending_automation'),
    );
  });

  test(
    'version 7 migration preserves queued and still-pending automation',
    () async {
      await database.close();
      final underlying = sqlite3.openInMemory();
      addTearDown(underlying.close);
      database = AppDatabase.forTesting(
        NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
      );
      await database.customStatement(
        "INSERT INTO feeds(id,title,feed_url,auto_queue,created_at,updated_at) "
        "VALUES ('feed','Podcast','https://example.test/feed',1,1,1)",
      );
      for (final id in ['queued', 'staged', 'untouched']) {
        await database.customStatement(
          'INSERT INTO episodes(id,feed_id,title,enclosure_url,discovered_at) '
          "VALUES (?,'feed',?,'https://example.test/audio.mp3',1)",
          [id, id],
        );
      }
      await database.customStatement(
        "INSERT INTO queue_entries VALUES ('entry','queued',0,1)",
      );
      await database.customStatement(
        "INSERT INTO pending_queue_adds VALUES ('staged',0,1)",
      );
      await database.close();
      underlying.execute(
        'ALTER TABLE episodes DROP COLUMN queue_automation_applied',
      );
      _removeRefreshIdentitySchema(underlying);
      underlying.userVersion = 7;
      database = AppDatabase.forTesting(
        NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
      );

      expect((await database.watchQueuedEpisodes().first).single.id, 'queued');
      expect(
        (await database.select(database.pendingQueueAdds).getSingle())
            .episodeId,
        'staged',
      );
      await database.batch((batch) {
        batch.deleteAll(database.queueEntries);
        batch.deleteAll(database.pendingQueueAdds);
      });
      await database.stageAutomaticQueueAdditions([
        'queued',
        'staged',
        'untouched',
      ]);
      expect(
        (await database.select(database.pendingQueueAdds).getSingle())
            .episodeId,
        'untouched',
      );
      expect(
        (await database.select(database.episodes).get()).where(
          (row) => row.automationApplied,
        ),
        isEmpty,
      );
    },
  );

  test(
    'version 4 migration preserves Up next and adds queue staging',
    () async {
      await database.close();
      final underlying = sqlite3.openInMemory();
      addTearDown(underlying.close);
      database = AppDatabase.forTesting(
        NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
      );
      final now = DateTime.utc(2026, 9, 1);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'podcast',
              title: 'Podcast',
              feedUrl: 'https://example.test/podcast.xml',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: 'episode',
              feedId: 'podcast',
              title: 'Episode',
              enclosureUrl: 'https://example.test/episode.mp3',
              discoveredAt: now,
            ),
          );
      await database
          .into(database.queueEntries)
          .insert(
            QueueEntriesCompanion.insert(
              id: 'queue-entry',
              episodeId: 'episode',
              sortKey: 0,
              addedAt: now,
            ),
          );
      await (database.update(database.feeds)
            ..where((row) => row.id.equals('podcast')))
          .write(const FeedsCompanion(autoQueue: Value(true)));
      await database.customStatement('DROP TABLE pending_queue_adds');
      await database.customStatement(
        'ALTER TABLE articles DROP COLUMN reader_html',
      );
      await database.customStatement(
        'ALTER TABLE articles DROP COLUMN reader_fetched_at',
      );
      await database.close();
      _removeRefreshIdentitySchema(underlying);
      underlying.userVersion = 4;
      underlying.execute(
        'ALTER TABLE episodes DROP COLUMN queue_automation_applied',
      );

      database = AppDatabase.forTesting(
        NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
      );
      await database.stageAutomaticQueueAdditions(const ['episode']);

      expect(await database.select(database.queueEntries).get(), hasLength(1));
      expect(await database.select(database.pendingQueueAdds).get(), isEmpty);
      expect(
        (await database.episodeById('episode'))?.queueAutomationApplied,
        isTrue,
      );
    },
  );

  test('version 3 migration adds categories without losing feeds', () async {
    await database.close();
    final underlying = sqlite3.openInMemory();
    addTearDown(underlying.close);
    database = AppDatabase.forTesting(
      NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
    );
    final now = DateTime.utc(2026, 8, 14);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'reader',
            title: 'Reader feed',
            feedUrl: 'https://example.com/reader.xml',
            kind: Value(FeedKind.reader.index),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database.customStatement('ALTER TABLE feeds DROP COLUMN category');
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN reader_html',
    );
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN reader_fetched_at',
    );
    await database.close();
    _removeRefreshIdentitySchema(underlying);
    underlying.userVersion = 3;
    underlying.execute(
      'ALTER TABLE episodes DROP COLUMN queue_automation_applied',
    );

    database = AppDatabase.forTesting(
      NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
    );
    final migrated = await database.feedById('reader');

    expect(migrated?.title, 'Reader feed');
    expect(migrated?.category, equals(null));
    await (database.update(database.feeds)
          ..where((row) => row.id.equals('reader')))
        .write(const FeedsCompanion(category: Value('Technology')));
    expect((await database.feedById('reader'))?.category, 'Technology');
  });

  test('version 1 mixed feeds migrate into exactly one library', () async {
    await database.close();
    final underlying = sqlite3.openInMemory();
    addTearDown(underlying.close);
    database = AppDatabase.forTesting(
      NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
    );
    final now = DateTime.utc(2026, 7, 19);
    for (final id in ['podcast', 'reader']) {
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: id,
              title: id,
              feedUrl: 'https://example.com/$id.xml',
              kind: const Value(2),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.articles)
          .insert(
            ArticlesCompanion.insert(
              id: '$id-article',
              feedId: id,
              title: '$id article',
              discoveredAt: now,
            ),
          );
      await database.indexSearchItem(
        entityId: '$id-article',
        kind: 'article',
        title: '$id article',
        body: '',
        feedTitle: id,
      );
    }
    await database
        .into(database.episodes)
        .insert(
          EpisodesCompanion.insert(
            id: 'podcast-episode',
            feedId: 'podcast',
            title: 'episode',
            enclosureUrl: 'https://example.com/audio.mp3',
            discoveredAt: now,
          ),
        );
    await database.customStatement(
      'DROP INDEX IF EXISTS idx_feeds_last_refresh',
    );
    await database.customStatement('DROP INDEX IF EXISTS idx_feeds_protocol');
    await database.customStatement(
      'DROP INDEX IF EXISTS idx_articles_source_event',
    );
    await database.customStatement(
      'DROP INDEX IF EXISTS idx_article_attachments',
    );
    await database.customStatement(
      'DROP INDEX IF EXISTS idx_nostr_relays_feed',
    );
    await database.customStatement('DROP TABLE article_attachments');
    await database.customStatement('DROP TABLE nostr_relays');
    await database.customStatement('DROP TABLE nostr_profiles');
    await database.customStatement('ALTER TABLE feeds DROP COLUMN category');
    await database.customStatement('ALTER TABLE feeds DROP COLUMN protocol');
    await database.customStatement('ALTER TABLE feeds DROP COLUMN subscribed');
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN content_format',
    );
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN content_warning',
    );
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN source_event_id',
    );
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN source_address',
    );
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN media_kind',
    );
    await database.customStatement(
      'CREATE INDEX idx_feeds_last_refresh ON feeds(last_refresh)',
    );
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN reader_html',
    );
    await database.customStatement(
      'ALTER TABLE articles DROP COLUMN reader_fetched_at',
    );
    await database.close();
    _removeRefreshIdentitySchema(underlying);
    underlying.userVersion = 1;
    underlying.execute(
      'ALTER TABLE episodes DROP COLUMN queue_automation_applied',
    );

    database = AppDatabase.forTesting(
      NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
    );
    final feeds = {
      for (final feed in await database.select(database.feeds).get())
        feed.id: feed,
    };

    expect(feeds['podcast']?.kind, FeedKind.podcast.index);
    expect(feeds['reader']?.kind, FeedKind.reader.index);
    expect(feeds['podcast']?.category, equals(null));
    expect(feeds['reader']?.category, equals(null));
    expect(await database.select(database.episodes).get(), hasLength(1));
    expect(await database.select(database.articles).get(), hasLength(1));
    expect(
      (await database.select(database.articles).get()).single.feedId,
      'reader',
    );
    final refreshIndex = await database
        .customSelect(
          "SELECT sql FROM sqlite_master WHERE type = 'index' "
          "AND name = 'idx_feeds_last_refresh'",
        )
        .getSingle();
    expect(
      refreshIndex.read<String>('sql'),
      contains('feeds(subscribed, last_refresh)'),
    );
    expect(await database.search('podcast article'), isEmpty);
  });
}

void _removeRefreshIdentitySchema(Database database) {
  database.execute('DROP TABLE nostr_deletions');
  for (final table in ['episodes', 'articles']) {
    database.execute('DROP INDEX idx_${table}_refresh_id');
    database.execute('ALTER TABLE $table DROP COLUMN refresh_id');
  }
}

final class _SelectLog extends QueryInterceptor {
  final selects = <(String, List<Object?>)>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects.add((statement, args));
    return executor.runSelect(statement, args);
  }
}
