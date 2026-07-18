import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/feed_identity.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/services/backup_service.dart';

void main() {
  late AppDatabase database;
  late BackupService backups;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    backups = BackupService(database);
    final now = DateTime.utc(2026, 7, 14);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'local-feed',
            title: 'Local title',
            feedUrl: 'https://example.com/feed.xml',
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() => database.close());

  test('restore remaps identities and rejects orphan state', () async {
    final now = DateTime.utc(2026, 7, 14);
    final localFeed = (await database.select(database.feeds).get()).single;
    final importedFeed = localFeed.copyWith(
      id: 'foreign-feed',
      title: 'Restored title',
    );
    final episode = Episode(
      id: 'foreign-episode',
      feedId: 'foreign-feed',
      guid: 'episode-guid',
      title: 'Episode',
      enclosureUrl: 'https://cdn.example.com/episode.mp3',
      discoveredAt: now,
      explicit: false,
      played: true,
      starred: true,
      automationApplied: true,
      durationMs: 1 << 60,
      fileSize: 1 << 100,
    );
    final orphan = episode.copyWith(
      id: 'orphan-episode',
      feedId: 'missing-feed',
      guid: const Value('orphan-guid'),
    );
    final progress = PlaybackProgressesData(
      episodeId: episode.id,
      positionMs: 60000,
      durationMs: 60000,
      completed: true,
      completedAt: now,
      updatedAt: now,
    );
    final queue = QueueEntry(
      id: 'foreign-queue',
      episodeId: episode.id,
      sortKey: 1 << 100,
      addedAt: now,
    );
    final payload = {
      'format': 'trickle-backup',
      'version': 1,
      'feeds': [importedFeed.toJson()],
      'episodes': [episode.toJson(), orphan.toJson()],
      'articles': <Object?>[],
      'progress': [progress.toJson()],
      'queue': [queue.toJson()],
      'bookmarks': <Object?>[],
      'settings': [
        AppSetting(
          key: 'playback_speed',
          value: '999',
          updatedAt: now,
        ).toJson(),
        AppSetting(
          key: 'last_background_refresh',
          value: DateTime.utc(2099).toIso8601String(),
          updatedAt: now,
        ).toJson(),
      ],
    };
    final archive = Archive()
      ..addFile(ArchiveFile.string('trickle.json', jsonEncode(payload)));
    final bytes = ZipEncoder().encode(archive);

    final first = await backups.importBytes(bytes);
    final second = await backups.importBytes(bytes);

    expect(first.feeds, 1);
    expect(first.episodes, 1);
    expect(second.episodes, 1);
    final feeds = await database.select(database.feeds).get();
    expect(feeds, hasLength(1));
    expect(feeds.single.id, 'local-feed');
    final episodes = await database.select(database.episodes).get();
    expect(episodes, hasLength(1));
    expect(episodes.single.feedId, 'local-feed');
    expect(episodes.single.durationMs, isNull);
    expect(episodes.single.fileSize, isNull);
    final restoredProgress =
        (await database.select(database.playbackProgresses).get()).single;
    expect(restoredProgress.episodeId, episodes.single.id);
    expect(restoredProgress.completedAt?.isAtSameMomentAs(now), isTrue);
    final restoredQueue =
        (await database.select(database.queueEntries).get()).single;
    expect(restoredQueue.episodeId, episodes.single.id);
    expect(restoredQueue.sortKey, 0);
    expect(await database.select(database.appSettings).get(), isEmpty);
  });

  test('restore keeps no-GUID items that reuse a media URL', () async {
    final localFeed = (await database.select(database.feeds).get()).single;
    final importedFeed = localFeed.copyWith(id: 'foreign-feed');
    final firstDate = DateTime.utc(2026, 7, 14);
    final secondDate = DateTime.utc(2026, 7, 15);
    const mediaUrl = 'https://cdn.example.com/rolling-latest.mp3';
    Episode episode(String id, DateTime publishedAt) => Episode(
      id: id,
      feedId: importedFeed.id,
      title: 'Daily episode',
      enclosureUrl: mediaUrl,
      publishedAt: publishedAt,
      discoveredAt: publishedAt,
      explicit: false,
      played: false,
      starred: false,
      automationApplied: true,
    );
    final payload = {
      'format': 'trickle-backup',
      'version': 1,
      'feeds': [importedFeed.toJson()],
      'episodes': [
        episode('foreign-first', firstDate).toJson(),
        episode('foreign-second', secondDate).toJson(),
      ],
      'articles': <Object?>[],
      'progress': <Object?>[],
      'queue': <Object?>[],
      'bookmarks': <Object?>[],
      'settings': <Object?>[],
    };
    final archive = Archive()
      ..addFile(ArchiveFile.string('trickle.json', jsonEncode(payload)));
    final bytes = ZipEncoder().encode(archive);

    await backups.importBytes(bytes);
    await backups.importBytes(bytes);

    final restored = await database.select(database.episodes).get();
    expect(restored, hasLength(2));
    expect(restored.map((episode) => episode.id).toSet(), {
      stableContentId(
        localFeed.id,
        publicEpisodeIdentity(
          guid: null,
          enclosureUrl: Uri.parse(mediaUrl),
          publishedAt: firstDate,
          title: 'Daily episode',
        ),
      ),
      stableContentId(
        localFeed.id,
        publicEpisodeIdentity(
          guid: null,
          enclosureUrl: Uri.parse(mediaUrl),
          publishedAt: secondDate,
          title: 'Daily episode',
        ),
      ),
    });
  });
}
