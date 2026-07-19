import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

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
    expect(await database.select(database.episodes).get(), hasLength(1));
    expect(await database.select(database.articles).get(), hasLength(1));
    expect(
      (await database.select(database.articles).get()).single.feedId,
      'reader',
    );
    expect(await database.search('podcast article'), isEmpty);
  });
}
