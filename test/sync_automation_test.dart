import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/services/sync_coordinator.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test(
    'download retries respect the limit and do not restore a cleared queue',
    () async {
      final now = DateTime.utc(2026, 7, 16);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'feed',
              title: 'Feed',
              feedUrl: 'https://example.com/feed',
              autoDownload: const Value(true),
              autoQueue: const Value(true),
              autoDownloadLimit: const Value(2),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (var index = 0; index < 4; index++) {
        await database
            .into(database.episodes)
            .insert(
              EpisodesCompanion.insert(
                id: 'episode-$index',
                feedId: 'feed',
                title: 'Episode $index',
                enclosureUrl: 'https://example.com/$index.mp3',
                publishedAt: Value(now.add(Duration(hours: index))),
                discoveredAt: now,
              ),
            );
      }
      final downloaded = <String>[];
      Future<void> run({required bool canDownload}) => applyPodcastAutomation(
        database: database,
        canStartDownload: () => canDownload,
        downloadEpisode: (id) async => downloaded.add(id),
      );
      await run(canDownload: false);
      final staged = await (database.select(
        database.pendingQueueAdds,
      )..orderBy([(row) => OrderingTerm.asc(row.sortKey)])).get();
      expect(staged.map((row) => row.episodeId), [
        'episode-3',
        'episode-2',
        'episode-1',
        'episode-0',
      ]);
      expect(downloaded, isEmpty);

      // Clear the queue, then try a stale request from another refresh as well
      // as a new refresh that can retry the downloads.
      await database.delete(database.pendingQueueAdds).go();
      await database.stageAutomaticQueueAdditions(['episode-3']);
      await run(canDownload: true);
      expect(await database.select(database.pendingQueueAdds).get(), isEmpty);
      expect(downloaded, ['episode-3', 'episode-2']);
      expect(
        (await database.select(database.episodes).get()).where(
          (row) => !row.automationApplied,
        ),
        isEmpty,
      );
    },
  );

  test('failed queue staging rolls back its batch and can retry', () async {
    final now = DateTime.utc(2026, 7, 16);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.com/feed',
            autoQueue: const Value(true),
            autoDownloadLimit: const Value(1),
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (var index = 0; index < 2; index++) {
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: 'episode-$index',
              feedId: 'feed',
              title: 'Episode $index',
              enclosureUrl: 'https://example.com/$index.mp3',
              publishedAt: Value(now.add(Duration(hours: index))),
              discoveredAt: now,
            ),
          );
    }

    await database.customStatement('''
        CREATE TRIGGER reject_queue_stage BEFORE INSERT ON pending_queue_adds
        WHEN NEW.episode_id = 'episode-0'
        BEGIN SELECT RAISE(ABORT, 'queue unavailable'); END
      ''');
    await applyPodcastAutomation(
      database: database,
      downloadEpisode: (_) async {},
    );

    expect(await database.select(database.pendingQueueAdds).get(), isEmpty);
    expect(
      (await database.select(database.episodes).get()).where(
        (row) => row.automationApplied || row.queueAutomationApplied,
      ),
      isEmpty,
    );
    await database.customStatement('DROP TRIGGER reject_queue_stage');
    await applyPodcastAutomation(
      database: database,
      downloadEpisode: (_) async {},
    );
    expect(
      await database.select(database.pendingQueueAdds).get(),
      hasLength(2),
    );
  });

  test('failed and canceled automatic downloads are retried', () async {
    final now = DateTime.utc(2026, 7, 17);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.com/feed',
            autoDownload: const Value(true),
            autoDownloadLimit: const Value(1),
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (var index = 0; index < 3; index++) {
      final episodeId = 'episode-$index';
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: episodeId,
              feedId: 'feed',
              title: 'Episode $index',
              enclosureUrl: 'https://example.com/$index.mp3',
              publishedAt: Value(now.add(Duration(hours: index))),
              discoveredAt: now,
            ),
          );
      if (index < 2) {
        await database
            .into(database.mediaDownloads)
            .insert(
              MediaDownloadsCompanion.insert(
                episodeId: episodeId,
                taskId: 'task-$index',
                status: Value(
                  index == 0
                      ? DownloadState.failed.index
                      : DownloadState.canceled.index,
                ),
                updatedAt: now,
              ),
            );
      }
    }
    final retried = <String>[];

    await applyPodcastAutomation(
      database: database,
      downloadEpisode: (id) async => retried.add(id),
    );

    expect(retried, ['episode-2', 'episode-1', 'episode-0']);
    expect(
      (await database.select(database.episodes).get()).every(
        (episode) => episode.automationApplied,
      ),
      isTrue,
    );
  });

  test('retryable automatic download failure stays pending', () async {
    final now = DateTime.utc(2026, 7, 17);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.com/feed',
            autoDownload: const Value(true),
            autoDownloadLimit: const Value(1),
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
            enclosureUrl: 'https://example.com/episode.mp3',
            discoveredAt: now,
          ),
        );
    await database
        .into(database.mediaDownloads)
        .insert(
          MediaDownloadsCompanion.insert(
            episodeId: 'episode',
            taskId: 'failed-task',
            status: Value(DownloadState.failed.index),
            updatedAt: now,
          ),
        );

    await applyPodcastAutomation(
      database: database,
      downloadEpisode: (_) => throw StateError('enqueue failed'),
    );

    expect((await database.episodeById('episode'))!.automationApplied, isFalse);
  });
}
