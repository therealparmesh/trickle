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

  test('download limit does not cap automatic queueing', () async {
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
    final queued = <String>[];
    final downloaded = <String>[];

    await applyPodcastAutomation(
      database: database,
      queueEpisode: (id) async => queued.add(id),
      downloadEpisode: (id) async => downloaded.add(id),
    );

    expect(queued, ['episode-3', 'episode-2', 'episode-1', 'episode-0']);
    expect(downloaded, ['episode-3', 'episode-2']);
    expect(
      (await database.select(database.episodes).get()).every(
        (episode) => episode.automationApplied,
      ),
      isTrue,
    );
  });

  test(
    'a failed selected action remains pending without draining history',
    () async {
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

      await applyPodcastAutomation(
        database: database,
        queueEpisode: (_) => throw StateError('queue unavailable'),
        downloadEpisode: (_) async {},
      );

      final rows = {
        for (final episode in await database.select(database.episodes).get())
          episode.id: episode,
      };
      expect(rows['episode-1']!.automationApplied, isFalse);
      expect(rows['episode-0']!.automationApplied, isFalse);
    },
  );

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
      queueEpisode: (_) async {},
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
      queueEpisode: (_) async {},
      downloadEpisode: (_) => throw StateError('enqueue failed'),
    );

    expect((await database.episodeById('episode'))!.automationApplied, isFalse);
  });
}
