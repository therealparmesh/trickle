import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trickle/core/content_filters.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

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
        category: 'science',
        sort: ContentSort.oldest,
        filter: ArticleFeedFilter.unread,
        query: 'SIGNAL',
      );
      final items = await database
          .watchFilteredArticles(
            category: query.category,
            limit: 100,
            sort: query.sort,
            filter: query.filter,
            query: query.query,
          )
          .first;
      final count = await database
          .watchFilteredArticleCount(
            category: query.category,
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
            category: 'science',
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

    final inProgress = await database
        .watchFilteredEpisodesForFeed(
          feedId: 'podcast',
          limit: 100,
          sort: ContentSort.newest,
          filter: EpisodeFeedFilter.inProgress,
          query: 'SIGNAL',
        )
        .first;
    final inProgressCount = await database
        .watchFilteredEpisodeCountForFeed(
          feedId: 'podcast',
          filter: EpisodeFeedFilter.inProgress,
          query: 'signal',
        )
        .first;
    final downloaded = await database
        .watchFilteredEpisodesForFeed(
          feedId: 'podcast',
          limit: 100,
          sort: ContentSort.oldest,
          filter: EpisodeFeedFilter.downloaded,
        )
        .first;

    expect(inProgress.map((episode) => episode.id), ['progress']);
    expect(inProgressCount, 1);
    expect(downloaded.map((episode) => episode.id), ['download']);
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
    'search replacement preserves a different kind with the same id',
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
    },
  );

  test('shared playback progress excludes completed history', () async {
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
    for (final id in const ['partial', 'complete']) {
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: id,
              feedId: 'feed',
              title: id,
              enclosureUrl: 'https://example.com/$id.mp3',
              discoveredAt: now,
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
      ]);
    });

    final progresses = await database.watchIncompletePlaybackProgresses().first;

    expect(progresses.map((progress) => progress.episodeId), ['partial']);
  });

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
    expect(inProgress.map((episode) => episode.id), [
      'partial-newer',
      'partial-older',
    ]);
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
    'version 4 migration preserves Up Next and adds queue staging',
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
      await database.customStatement('DROP TABLE pending_queue_adds');
      await database.close();
      underlying.userVersion = 4;

      database = AppDatabase.forTesting(
        NativeDatabase.opened(underlying, closeUnderlyingOnClose: false),
      );
      await database.stageQueueAdditions(const ['episode']);

      expect(await database.select(database.queueEntries).get(), hasLength(1));
      expect(await database.select(database.pendingQueueAdds).get(), isEmpty);
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
    await database.close();
    underlying.userVersion = 3;

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
    await database.close();
    underlying.userVersion = 1;

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
