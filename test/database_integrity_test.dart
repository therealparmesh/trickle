import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
