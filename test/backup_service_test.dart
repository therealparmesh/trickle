import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/core/errors.dart';
import 'package:trickle/core/feed_identity.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/services/backup_service.dart';

import 'support/playback_harness.dart';

void main() {
  late AppDatabase database;
  late BackupService backups;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
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
            kind: Value(FeedKind.podcast.index),
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() => database.close());

  test(
    'restore skips obsolete queue entries but keeps deliberate requeues',
    () async {
      final addedAt = DateTime.utc(2026, 7, 15);
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: 'finished',
              feedId: 'local-feed',
              guid: const Value('finished'),
              title: 'Finished episode',
              enclosureUrl: 'https://example.test/finished.mp3',
              discoveredAt: addedAt,
            ),
          );
      await database
          .into(database.queueEntries)
          .insert(
            QueueEntriesCompanion.insert(
              id: 'queue:finished',
              episodeId: 'finished',
              sortKey: 0,
              addedAt: addedAt,
            ),
          );
      final bytes = await backups.exportBytes();
      final completedAt = addedAt.add(const Duration(minutes: 30));
      await database
          .update(database.episodes)
          .write(const EpisodesCompanion(played: Value(true)));
      await database
          .into(database.playbackProgresses)
          .insert(
            PlaybackProgressesCompanion.insert(
              episodeId: 'finished',
              positionMs: const Value(1800000),
              completed: const Value(true),
              completedAt: Value(completedAt),
              updatedAt: completedAt,
            ),
          );
      final markedPlayedBackup = await backups.exportBytes();
      await database.removeFinishedQueueEpisode('finished');
      await backups.importBytes(bytes);
      expect(await database.watchQueuedEpisodes().first, isEmpty);
      expect(
        (await database.watchPlaybackProgressForEpisode('finished').first)
            ?.completed,
        isTrue,
      );
      await database
          .into(database.queueEntries)
          .insert(
            QueueEntriesCompanion.insert(
              id: 'queue:finished',
              episodeId: 'finished',
              sortKey: 0,
              addedAt: completedAt.add(const Duration(minutes: 1)),
            ),
          );
      final requeuedBackup = await backups.exportBytes();
      await database.delete(database.queueEntries).go();
      await backups.importBytes(requeuedBackup);
      expect(
        (await database.watchQueuedEpisodes().first).single.id,
        'finished',
      );

      // Mark played leaves manually queued episodes in Up next. Keep both
      // states when there is no local playback or queue history.
      await database.delete(database.episodes).go();
      await backups.importBytes(markedPlayedBackup);
      expect(
        (await database.watchQueuedEpisodes().first).single.played,
        isTrue,
      );
      final restoredId = (await database.watchQueuedEpisodes().first).single.id;
      final completion = (await database
          .watchPlaybackProgressForEpisode(restoredId)
          .first)!;
      await database
          .update(database.playbackProgresses)
          .write(
            PlaybackProgressesCompanion(
              completed: const Value(false),
              completedAt: const Value(null),
              positionMs: const Value(60000),
              updatedAt: Value(completedAt.add(const Duration(hours: 1))),
            ),
          );
      final newerReplay = await backups.exportBytes();
      await database
          .into(database.playbackProgresses)
          .insertOnConflictUpdate(completion);
      await database.delete(database.queueEntries).go();
      await backups.importBytes(newerReplay);
      expect(
        (await database.watchQueuedEpisodes().first).single.id,
        restoredId,
      );
      expect(
        (await database.watchPlaybackProgressForEpisode(restoredId).first)
            ?.completed,
        isFalse,
      );
    },
  );

  test(
    'an older backup does not repopulate unsubscribed feeds with untouched items',
    () async {
      const readerUrl = 'https://example.test/reader';
      await database.customStatement(
        "INSERT INTO feeds(id,title,feed_url,created_at,updated_at) VALUES ('reader','Reader',?,1,1)",
        [readerUrl],
      );
      await database.customStatement('''
      INSERT INTO articles(id,feed_id,guid,title,discovered_at,starred) VALUES
      ('discarded-article','reader','discarded','Discarded article',1,0),
      ('saved-article','reader','saved','Saved article',1,1)
    ''');
      await database.customStatement('''
      INSERT INTO episodes(id,feed_id,guid,title,enclosure_url,discovered_at) VALUES
      ('discarded-episode','local-feed','discarded','Discarded episode','https://example.test/discarded.mp3',1),
      ('played-episode','local-feed','started','Started episode','https://example.test/started.mp3',1)
    ''');
      await database.customStatement(
        "INSERT INTO playback_progresses(episode_id,position_ms,updated_at) VALUES ('played-episode',18000,1)",
      );
      final bytes = await backups.exportBytes();
      final network = SafeNetworkClient.forTesting(
        Dio(),
        addressValidator: (_) async {},
      );
      addTearDown(network.close);
      final repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: PrivateFeedStore(),
      );
      await repository.deleteFeed('reader');
      await repository.deleteFeed('local-feed');
      expect((await database.feedById('reader'))?.subscribed, isFalse);
      expect((await database.feedById('local-feed'))?.subscribed, isFalse);
      // Missing locally, but still kept in the backup because it was started.
      await (database.delete(
        database.episodes,
      )..where((row) => row.id.equals('played-episode'))).go();

      await backups.importBytes(bytes);
      expect((await database.feedById('reader'))?.subscribed, isFalse);
      expect((await database.feedById('local-feed'))?.subscribed, isFalse);
      expect(
        (await database.select(database.articles).get()).map((a) => a.title),
        ['Saved article'],
      );
      expect(
        (await database.select(database.episodes).get()).map((e) => e.title),
        ['Started episode'],
      );
      expect(await database.search('Discarded'), isEmpty);
      final restored = await database.select(database.episodes).getSingle();
      expect(
        (await database.watchPlaybackProgressForEpisode(restored.id).first)
            ?.positionMs,
        18000,
      );
    },
  );

  test('invalid archives return a safe, actionable backup error', () async {
    final damaged = Uint8List.fromList(await backups.exportBytes());
    final headers = ByteData.sublistView(damaged);
    for (var offset = 0; offset <= damaged.length - 46; offset++) {
      if (headers.getUint32(offset, Endian.little) == 0x02014b50) {
        // Alter a central-directory CRC without changing its valid JSON body.
        damaged[offset + 16] ^= 1;
        break;
      }
    }
    for (final bytes in [
      const [0, 1, 2, 3],
      damaged,
    ]) {
      await expectLater(
        backups.importBytes(bytes),
        throwsA(
          isA<BackupException>().having(
            (error) => error.message,
            'message',
            'That file isn’t a valid trickle backup.',
          ),
        ),
      );
      expect(
        (await database.select(database.feeds).get()).single.title,
        'Local title',
      );
    }
  });

  test(
    'large backups restore bodies, saved state, and reader settings beyond 50 MiB',
    () async {
      await database.customStatement(
        "INSERT INTO feeds(id,title,feed_url,created_at,updated_at) VALUES ('reader','Reader','https://example.test/reader',1,1)",
      );
      await database.customStatement('''
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<9000)
      INSERT INTO articles(id,feed_id,title,content_html,canonical_url,discovered_at,read_at,starred)
      SELECT 'a'||x,'reader','Article '||x,replace(hex(zeroblob(3000)),'0','x'),
        'https://example.test/article/'||x,x,CASE WHEN x=9000 THEN x ELSE NULL END,x=9000 FROM n
    ''');
      await database.customStatement(
        "UPDATE articles SET reader_html='<p>Saved offline article</p>', reader_fetched_at=100 WHERE id='a9000'",
      );
      await database
          .into(database.appSettings)
          .insert(
            AppSettingsCompanion.insert(
              key: 'reader_text_scale',
              value: '130',
              updatedAt: DateTime.utc(2026, 9, 8),
            ),
          );
      final directory = await Directory.systemTemp.createTemp(
        'trickle-large-backup-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/backup.zip');
      await backups.exportToFile(file);
      final zip = ZipDecoder().decodeBytes(await file.readAsBytes());
      expect(
        zip.files.fold<int>(0, (sum, entry) => sum + entry.size),
        greaterThan(50 * 1024 * 1024),
      );
      expect(
        zip.files.where((entry) => entry.name.startsWith('articles-')).length,
        greaterThan(1),
      );
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase.memory());
      final result = await BackupService(database).importFile(file);
      expect(result.articles, 9000);
      final last =
          await (database.select(database.articles)..where(
                (row) => row.canonicalUrl.equals(
                  'https://example.test/article/9000',
                ),
              ))
              .getSingle();
      expect(last.contentHtml, 'x' * 6000);
      expect(last.readerHtml, '<p>Saved offline article</p>');
      expect(last.readerFetchedAt, DateTime.fromMillisecondsSinceEpoch(100000));
      expect(last.starred, isTrue);
      expect(last.readAt, isNotNull);
      expect(
        (await database.select(database.appSettings).get()).single.value,
        '130',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a missing final backup chunk is rejected before changing the library',
    () async {
      final zip = ZipDecoder().decodeBytes(await backups.exportBytes());
      final incomplete = Archive();
      for (final entry in zip.files.where(
        (entry) => !entry.name.startsWith('feeds-'),
      )) {
        incomplete.addFile(
          ArchiveFile(entry.name, entry.size, entry.readBytes()!),
        );
      }
      await expectLater(
        backups.importBytes(ZipEncoder().encode(incomplete)),
        throwsA(isA<BackupException>()),
      );
      expect(
        (await database.select(database.feeds).get()).single.title,
        'Local title',
      );
      expect(await database.select(database.episodes).get(), isEmpty);
    },
  );

  test('picker restore round-trips an exported backup', () async {
    final bytes = await backups.exportBytes();
    await database.close();
    final restoredDatabase = AppDatabase.forTesting(NativeDatabase.memory());
    database = restoredDatabase;
    var reloads = 0;
    final restored = BackupService(
      restoredDatabase,
      pickFile: () async => XFile.fromData(
        Uint8List.fromList(bytes),
        name: 'trickle-backup.zip',
        mimeType: 'application/zip',
      ),
      onImported: () async => reloads++,
    );

    final result = await restored.pickAndImport();

    expect(result?.feeds, 1);
    expect(result?.episodes, 0);
    expect(result?.articles, 0);
    expect(reloads, 1);
    expect(
      (await restoredDatabase.select(restoredDatabase.feeds).get())
          .single
          .title,
      'Local title',
    );
  });

  test('reuses an active restore instead of reopening the picker', () async {
    final picker = Completer<XFile?>();
    var pickerCalls = 0;
    final service = BackupService(
      database,
      pickFile: () {
        pickerCalls++;
        return pickerCalls == 1 ? picker.future : Future.value();
      },
    );

    final first = service.pickAndImport();
    final second = service.pickAndImport();

    expect(identical(first, second), isTrue);
    expect(pickerCalls, 1);
    picker.complete(null);
    expect(await first, isNull);
    expect(await second, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(await service.pickAndImport(), isNull);
    expect(pickerCalls, 2);
  });

  test(
    'unreadable and oversized backups return specific import errors',
    () async {
      final pickerFailure = BackupService(
        database,
        pickFile: () => Future<XFile?>.error(StateError('picker failed')),
      );
      final readFailure = BackupService(
        database,
        pickFile: () async => XFile(
          '/definitely-missing/trickle-backup.zip',
          mimeType: 'application/zip',
        ),
      );

      await expectLater(
        pickerFailure.pickAndImport(),
        throwsA(
          isA<BackupException>().having(
            (error) => error.message,
            'message',
            'Couldn’t open the file picker.',
          ),
        ),
      );
      await expectLater(
        readFailure.pickAndImport(),
        throwsA(
          isA<BackupException>().having(
            (error) => error.message,
            'message',
            'Couldn’t read that backup file.',
          ),
        ),
      );
      final oversized = BackupService(
        database,
        pickFile: () async =>
            XFile.fromData(Uint8List(0), length: 3 * 1024 * 1024 * 1024),
      );
      await expectLater(
        oversized.pickAndImport(),
        throwsA(
          isA<BackupException>().having(
            (error) => error.message,
            'message',
            'Backup exceeds the 2 GiB size limit.',
          ),
        ),
      );
    },
  );

  test(
    'restore failure preserves the paused checkpoint and permits a retry',
    () async {
      final target = createPlaybackHarness();
      addTearDown(() => disposePlaybackHarness(target));
      final handler = target.handler;
      final now = DateTime.utc(2026, 7, 15);
      final feed = (await database.select(database.feeds).get()).single;
      await target.database.into(target.database.feeds).insert(feed);
      for (final db in [database, target.database]) {
        await db
            .into(db.episodes)
            .insert(
              EpisodesCompanion.insert(
                id: 'episode',
                feedId: feed.id,
                guid: const Value('episode-guid'),
                title: 'Episode',
                enclosureUrl: 'https://example.test/episode.mp3',
                discoveredAt: now,
              ),
            );
        await db
            .into(db.playbackProgresses)
            .insert(
              PlaybackProgressesCompanion.insert(
                episodeId: 'episode',
                positionMs: Value(identical(db, database) ? 60000 : 10000),
                updatedAt: identical(db, database) ? now : feed.createdAt,
              ),
            );
      }
      await handler.restoreLastPlayback();
      expect(await handler.positionStream.first, const Duration(seconds: 10));

      final bytes = await backups.exportBytes();
      final restored = BackupService(
        target.database,
        pickFile: () async => XFile.fromData(Uint8List.fromList(bytes)),
        applyRestore: handler.restoreLibrary,
      );
      await target.database.customStatement('''
        CREATE TEMP TRIGGER reject_restored_progress
        BEFORE INSERT ON playback_progresses
        BEGIN
          SELECT RAISE(FAIL, 'forced restore failure');
        END
      ''');
      await expectLater(restored.pickAndImport(), throwsA(isA<Exception>()));
      expect(handler.mediaItem.value?.id, 'episode');
      expect(handler.playbackState.value.playing, isFalse);
      expect(await handler.positionStream.first, const Duration(seconds: 10));
      expect(
        (await target.database.watchPlaybackProgressForEpisode('episode').first)
            ?.positionMs,
        10000,
      );
      await target.database.customStatement(
        'DROP TRIGGER reject_restored_progress',
      );
      await restored.pickAndImport();
      expect(handler.mediaItem.value?.id, 'episode');
      expect(handler.playbackState.value.playing, isFalse);
      expect(await handler.positionStream.first, const Duration(seconds: 60));
      await handler.disposeHandler();
      expect(
        (await target.database.watchPlaybackProgressForEpisode('episode').first)
            ?.positionMs,
        60000,
      );
    },
  );

  test(
    'restore preserves queued and staged order and blocks concurrent edits',
    () async {
      final target = createPlaybackHarness();
      addTearDown(() => disposePlaybackHarness(target));
      final (_, current, _) = await seedPlaybackQueue(target);
      await target.database
          .update(target.database.feeds)
          .write(const FeedsCompanion(autoQueue: Value(true)));
      await target.database
          .into(target.database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: 'staged',
              feedId: 'feed',
              title: 'Staged',
              enclosureUrl: 'https://example.test/staged.mp3',
              discoveredAt: DateTime.utc(2026, 7, 16),
            ),
          );
      await target.database.stageAutomaticQueueAdditions(['staged']);
      final handler = target.handler;
      final feed = (await database.feedById('local-feed'))!;
      const restoredEpisode = 'restored-episode';
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: restoredEpisode,
              feedId: feed.id,
              title: 'Restored',
              enclosureUrl: 'https://example.test/restored.mp3',
              discoveredAt: feed.createdAt,
            ),
          );
      await database
          .into(database.queueEntries)
          .insert(
            QueueEntriesCompanion.insert(
              id: 'restored-queue',
              episodeId: restoredEpisode,
              sortKey: 0,
              addedAt: feed.createdAt,
            ),
          );
      final bytes = await backups.exportBytes();
      final committed = Completer<void>();
      final resume = Completer<void>();
      final service = BackupService(
        target.database,
        applyRestore: (apply) => handler.restoreLibrary(() async {
          await apply();
          committed.complete();
          await resume.future;
        }),
      );
      final restore = service.importBytes(bytes);
      await committed.future;
      try {
        await expectLater(
          handler.updateQueue([current]),
          throwsA(isA<BackupException>()),
        );
        await expectLater(
          handler.removeQueueItem(current),
          throwsA(isA<BackupException>()),
        );
      } finally {
        resume.complete();
        await restore;
      }
      final queued = handler.queue.value;
      expect(queued, hasLength(5));
      expect(queued.skip(3).map((item) => item.title), ['Staged', 'Restored']);
      await handler.updateQueue(<MediaItem>[queued.last, current]);
      expect(
        (await target.database.watchQueuedEpisodes().first).map(
          (episode) => episode.title,
        ),
        ['Restored', current.title],
      );
    },
  );

  test(
    'post-restore reload failures report that the data was applied',
    () async {
      final bytes = await backups.exportBytes();
      final service = BackupService(
        database,
        pickFile: () async => XFile.fromData(
          Uint8List.fromList(bytes),
          name: 'trickle-backup.zip',
          mimeType: 'application/zip',
        ),
        onImported: () => Future<void>.error(StateError('reload failed')),
      );

      await expectLater(
        service.pickAndImport(),
        throwsA(
          isA<BackupException>().having(
            (error) => error.message,
            'message',
            'Backup restored, but playback state couldn’t reload. '
                'Restart trickle to finish.',
          ),
        ),
      );
      expect(await database.feedById('local-feed'), isA<Feed>());
    },
  );

  test(
    'restore rejects Nostr feeds without a matching profile identity',
    () async {
      final now = DateTime.utc(2026, 7, 26);
      final feed = Feed(
        id: 'orphan-nostr',
        title: 'Orphan profile',
        feedUrl:
            'nostr:npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6',
        kind: FeedKind.reader.index,
        protocol: FeedProtocol.nostr.index,
        subscribed: true,
        isPrivate: false,
        autoDownload: false,
        autoDownloadLimit: 3,
        notifications: false,
        introSkipMs: 0,
        outroSkipMs: 0,
        autoQueue: false,
        createdAt: now,
        updatedAt: now,
      );
      final payload = {
        'format': 'trickle-backup',
        'version': 2,
        'feeds': [feed.toJson()],
        'episodes': <Object?>[],
        'articles': <Object?>[],
        'articleAttachments': <Object?>[],
        'nostrProfiles': <Object?>[],
        'nostrRelays': <Object?>[],
        'progress': <Object?>[],
        'queue': <Object?>[],
        'bookmarks': <Object?>[],
        'settings': <Object?>[],
      };
      final archive = Archive()
        ..addFile(ArchiveFile.string('trickle.json', jsonEncode(payload)));

      final result = await backups.importBytes(ZipEncoder().encode(archive));

      expect(result.feeds, 0);
      expect(await database.feedById(feed.id), isNull);
    },
  );

  test(
    'restore follows a moved feed even when its old URL was reused',
    () async {
      final feed = (await database.feedById('local-feed'))!;
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: 'saved-episode',
              feedId: feed.id,
              guid: const Value('episode-guid'),
              title: 'Original show',
              enclosureUrl: 'https://cdn.example.com/original.mp3',
              discoveredAt: feed.createdAt,
              starred: const Value(true),
            ),
          );
      await database
          .into(database.playbackProgresses)
          .insert(
            PlaybackProgressesCompanion.insert(
              episodeId: 'saved-episode',
              positionMs: const Value(12000),
              updatedAt: feed.updatedAt,
            ),
          );
      final beforeMove = await backups.exportBytes();
      const newAddress = 'https://example.test/moved.xml';
      await database
          .update(database.feeds)
          .write(
            FeedsCompanion(
              feedUrl: const Value(newAddress),
              updatedAt: Value(feed.updatedAt.add(const Duration(days: 1))),
            ),
          );
      await database.delete(database.playbackProgresses).go();
      await database
          .update(database.episodes)
          .write(const EpisodesCompanion(starred: Value(false)));
      await backups.importBytes(beforeMove);
      expect(await database.select(database.feeds).get(), hasLength(1));

      await database
          .into(database.feeds)
          .insert(
            feed.copyWith(
              id: 'replacement',
              title: 'Different show',
              createdAt: feed.createdAt.add(const Duration(days: 2)),
            ),
          );
      await backups.importBytes(beforeMove);
      expect((await database.feedById(feed.id))?.feedUrl, newAddress);
      expect((await database.feedById('replacement'))?.title, 'Different show');
      final episode = await database.select(database.episodes).getSingle();
      expect(episode.id, 'saved-episode');
      expect(episode.starred, isTrue);
      final progress = await database
          .select(database.playbackProgresses)
          .getSingle();
      expect(progress.episodeId, episode.id);
      expect(progress.positionMs, 12000);

      final otherDevice = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(otherDevice.close);
      final restore = BackupService(otherDevice);
      await restore.importBytes(beforeMove);
      await restore.importBytes(await backups.exportBytes());
      expect((await otherDevice.feedById(feed.id))?.feedUrl, newAddress);
      expect(
        (await otherDevice.feedById('replacement'))?.feedUrl,
        feed.feedUrl,
      );
      expect(
        await otherDevice.select(otherDevice.episodes).get(),
        hasLength(1),
      );
    },
  );

  test('restore remaps identities and rejects orphan state', () async {
    final now = DateTime.utc(2026, 7, 14);
    final localFeed = (await database.select(database.feeds).get()).single;
    final importedFeed = localFeed.copyWith(
      id: 'foreign-feed',
      title: 'Restored title',
      protocol: 999,
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
      queueAutomationApplied: false,
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
        AppSetting(key: 'unknown', value: 'ignored', updatedAt: now).toJson(),
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
    expect(feeds.single.protocol, FeedProtocol.syndication.index);
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

  test(
    'restore never attaches cached reader text to a different article link',
    () async {
      final now = DateTime.utc(2026, 7, 16);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'reader',
              title: 'Reader',
              feedUrl: 'https://example.test/reader.xml',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.articles)
          .insert(
            ArticlesCompanion.insert(
              id: 'article',
              feedId: 'reader',
              guid: const Value('stable-guid'),
              title: 'Story',
              canonicalUrl: const Value('https://example.test/original'),
              readerHtml: const Value('<p>Obsolete cached text</p>'),
              readerFetchedAt: Value(now),
              discoveredAt: now,
              starred: const Value(true),
            ),
          );
      final backup = await backups.exportBytes();
      await database
          .update(database.articles)
          .write(
            const ArticlesCompanion(
              canonicalUrl: Value('https://example.test/corrected'),
              contentHtml: Value('<p>Corrected feed text</p>'),
              readerHtml: Value(null),
              readerFetchedAt: Value(null),
              starred: Value(false),
            ),
          );

      await backups.importBytes(backup);

      final article = await database.select(database.articles).getSingle();
      expect(article.canonicalUrl, 'https://example.test/corrected');
      expect(article.starred, isTrue);
      expect(article.readerHtml, isNull);
      expect(article.readerFetchedAt, isNull);
      expect(await database.search('obsolete cached'), isEmpty);
      expect(await database.search('corrected feed'), hasLength(1));
    },
  );

  test(
    'restoring and re-exporting keeps newer progress, saved text, and one bookmark',
    () async {
      final old = DateTime.utc(2026, 7, 15);
      final latest = old.add(const Duration(days: 1));
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'reader',
              title: 'Reader',
              feedUrl: 'https://example.test/reader.xml',
              createdAt: old,
              updatedAt: old,
            ),
          );
      await database
          .into(database.articles)
          .insert(
            ArticlesCompanion.insert(
              id: 'article',
              feedId: 'reader',
              title: 'Article',
              discoveredAt: old,
              readerHtml: const Value('<p>Old reader body</p>'),
              readerFetchedAt: Value(old),
              readAt: Value(old),
              starred: const Value(true),
            ),
          );
      for (final id in ['episode', 'staged']) {
        await database
            .into(database.episodes)
            .insert(
              EpisodesCompanion.insert(
                id: id,
                feedId: 'local-feed',
                title: id,
                enclosureUrl: 'https://example.test/$id.mp3',
                discoveredAt: old,
              ),
            );
      }
      await (database.update(database.feeds)
            ..where((row) => row.id.equals('local-feed')))
          .write(const FeedsCompanion(autoQueue: Value(true)));
      await database.stageAutomaticQueueAdditions(['staged']);
      await database
          .into(database.playbackProgresses)
          .insert(
            PlaybackProgressesCompanion.insert(
              episodeId: 'episode',
              positionMs: const Value(1000),
              updatedAt: old,
            ),
          );
      await database
          .into(database.bookmarks)
          .insert(
            BookmarksCompanion.insert(
              id: 'bookmark',
              episodeId: 'episode',
              positionMs: 1000,
              createdAt: old,
            ),
          );
      final original = await backups.exportBytes();

      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      final transferred = BackupService(other);
      await transferred.importBytes(original);
      final staged = (await other.watchQueuedEpisodes().first).single;
      expect(staged.title, 'staged');
      final reExported = await transferred.exportBytes();
      await other.delete(other.queueEntries).go();
      await other.stageAutomaticQueueAdditions([staged.id]);
      expect(await other.select(other.pendingQueueAdds).get(), isEmpty);
      await transferred.importBytes(reExported);
      await other
          .update(other.bookmarks)
          .write(const BookmarksCompanion(id: Value('legacy-remapped-id')));
      final legacyReExported = await transferred.exportBytes();

      await database
          .update(database.playbackProgresses)
          .write(
            PlaybackProgressesCompanion(
              positionMs: const Value(60000),
              completed: const Value(true),
              completedAt: Value(latest),
              updatedAt: Value(latest),
            ),
          );
      await (database.update(database.episodes)
            ..where((row) => row.id.equals('episode')))
          .write(const EpisodesCompanion(played: Value(true)));
      await database
          .update(database.articles)
          .write(
            ArticlesCompanion(
              readerHtml: const Value('<p>Latest offline body</p>'),
              readerFetchedAt: Value(latest),
              readAt: const Value(null),
            ),
          );
      await (database.update(
        database.feeds,
      )..where((row) => row.id.equals('reader'))).write(
        FeedsCompanion(category: const Value('News'), updatedAt: Value(latest)),
      );

      await backups.importBytes(original);
      await backups.importBytes(reExported);
      await backups.importBytes(legacyReExported);
      expect(
        (await database.select(database.bookmarks).getSingle()).id,
        'bookmark',
      );
      expect(
        (await database.select(database.playbackProgresses).getSingle())
            .positionMs,
        60000,
      );
      expect((await database.episodeById('episode'))?.played, isTrue);
      expect((await database.feedById('reader'))?.category, 'News');
      expect((await database.articleById('article'))?.readAt, isNull);
      expect(await database.search('latest offline'), hasLength(1));
      expect(await database.search('old reader'), isEmpty);

      await transferred.importBytes(await backups.exportBytes());
      expect(
        (await other.select(other.playbackProgresses).getSingle()).positionMs,
        60000,
      );
      expect((await other.watchQueuedEpisodes().first).single.title, 'staged');
      expect(await other.search('latest offline'), hasLength(1));
    },
  );

  test('restore keeps items without GUIDs that reuse a media URL', () async {
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
      queueAutomationApplied: false,
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
        episodeIdentity(
          guid: null,
          enclosureUrl: Uri.parse(mediaUrl),
          publishedAt: firstDate,
          title: 'Daily episode',
        ),
      ),
      stableContentId(
        localFeed.id,
        episodeIdentity(
          guid: null,
          enclosureUrl: Uri.parse(mediaUrl),
          publishedAt: secondDate,
          title: 'Daily episode',
        ),
      ),
    });
  });

  test(
    'restore keeps private episodes with different media selectors',
    () async {
      final store = PrivateFeedStore();
      final feed = (await database.select(database.feeds).getSingle()).copyWith(
        feedUrl: 'https://example.test/podcast.xml?token=private',
      );
      final date = DateTime.utc(2026, 10, 2);
      final payload = {
        'format': 'trickle-backup',
        'version': 1,
        'feeds': [feed.toJson()],
        'episodes': [
          for (final number in [41, 42])
            Episode(
              id: 'old-$number',
              feedId: feed.id,
              title: 'Daily episode',
              enclosureUrl:
                  'https://example.test/audio.mp3?episode=$number&token=media',
              discoveredAt: date,
              publishedAt: date,
              explicit: false,
              played: false,
              starred: false,
              automationApplied: true,
              queueAutomationApplied: false,
            ).toJson(),
        ],
        'progress': [
          PlaybackProgressesData(
            episodeId: 'old-42',
            positionMs: 18000,
            completed: false,
            updatedAt: date,
          ).toJson(),
        ],
      };
      final archive = Archive()
        ..addFile(ArchiveFile.string('trickle.json', jsonEncode(payload)));
      final bytes = ZipEncoder().encode(archive);
      final service = BackupService(database, privateFeeds: store);
      await service.importBytes(bytes);
      await service.importBytes(bytes);
      final episodes = await database.select(database.episodes).get();
      expect(episodes, hasLength(2));
      final progress = await database
          .select(database.playbackProgresses)
          .getSingle();
      expect(progress.positionMs, 18000);
      expect(
        (await store.readMediaUrl(
          progress.episodeId,
        ))?.queryParameters['episode'],
        '42',
      );
    },
  );

  test('restore normalizes a version 1 mixed feed to podcast-only', () async {
    final now = DateTime.utc(2026, 7, 19);
    final localFeed = (await database.select(database.feeds).get()).single;
    final importedFeed = localFeed.copyWith(
      id: 'legacy-mixed',
      feedUrl: 'https://example.com/legacy.xml',
      kind: 2,
    );
    final episode = Episode(
      id: 'legacy-episode',
      feedId: importedFeed.id,
      title: 'Playable',
      enclosureUrl: 'https://example.com/playable.mp3',
      discoveredAt: now,
      explicit: false,
      played: false,
      starred: false,
      automationApplied: true,
      queueAutomationApplied: false,
    );
    final article = Article(
      id: 'legacy-article',
      feedId: importedFeed.id,
      title: 'Accidental article copy',
      discoveredAt: now,
      contentFormat: ArticleContentFormat.html.index,
      mediaKind: ArticleMediaKind.none.index,
      starred: false,
    );
    final payload = {
      'format': 'trickle-backup',
      'version': 1,
      'feeds': [importedFeed.toJson()],
      'episodes': [episode.toJson()],
      'articles': [article.toJson()],
      'progress': <Object?>[],
      'queue': <Object?>[],
      'bookmarks': <Object?>[],
      'settings': <Object?>[],
    };
    final archive = Archive()
      ..addFile(ArchiveFile.string('trickle.json', jsonEncode(payload)));

    final result = await backups.importBytes(ZipEncoder().encode(archive));
    final restored = await database.feedByUrl(importedFeed.feedUrl);

    expect(restored?.kind, FeedKind.podcast.index);
    expect(result.episodes, 1);
    expect(result.articles, 0);
    expect(await database.select(database.articles).get(), isEmpty);
  });

  test('backup round-trips Nostr media and playback state', () async {
    final now = DateTime.utc(2026, 7, 26);
    const publicKey =
        '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';
    const eventId =
        '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e';
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'nostr-feed',
            title: 'Signal Author',
            feedUrl:
                'nostr:npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6',
            category: const Value('Technology'),
            kind: Value(FeedKind.reader.index),
            protocol: Value(FeedProtocol.nostr.index),
            subscribed: const Value(false),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.nostrProfiles)
        .insert(
          NostrProfilesCompanion.insert(
            feedId: 'nostr-feed',
            publicKey: publicKey,
          ),
        );
    await database
        .into(database.nostrRelays)
        .insert(
          NostrRelaysCompanion.insert(
            feedId: 'nostr-feed',
            url: 'wss://relay.example',
          ),
        );
    await database
        .into(database.articles)
        .insert(
          ArticlesCompanion.insert(
            id: 'nostr-article',
            feedId: 'nostr-feed',
            guid: const Value(eventId),
            title: 'Voice update',
            contentHtml: const Value('## Update'),
            canonicalUrl: const Value(
              'nostr:note10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qkz8z5',
            ),
            contentFormat: Value(ArticleContentFormat.markdown.index),
            sourceEventId: const Value(eventId),
            mediaKind: Value(ArticleMediaKind.audio.index),
            publishedAt: Value(now),
            discoveredAt: now,
            starred: const Value(true),
          ),
        );
    await database
        .into(database.articleAttachments)
        .insert(
          ArticleAttachmentsCompanion.insert(
            id: 'nostr-audio',
            articleId: 'nostr-article',
            position: 0,
            url: 'https://cdn.example/audio.opus',
            mimeType: const Value('audio/opus'),
            durationMs: const Value(12500),
          ),
        );
    await database
        .into(database.episodes)
        .insert(
          EpisodesCompanion.insert(
            id: 'nostr-audio',
            feedId: 'nostr-feed',
            guid: const Value('nostr-media:nostr-article'),
            title: 'Voice update',
            enclosureUrl: 'https://cdn.example/audio.opus',
            discoveredAt: now,
            automationApplied: const Value(true),
          ),
        );
    await database
        .into(database.playbackProgresses)
        .insert(
          PlaybackProgressesCompanion.insert(
            episodeId: 'nostr-audio',
            positionMs: const Value(5000),
            durationMs: const Value(12500),
            updatedAt: now,
          ),
        );

    final bytes = await backups.exportBytes();
    await database.close();
    final restoredDatabase = AppDatabase.forTesting(NativeDatabase.memory());
    database = restoredDatabase;
    final result = await BackupService(restoredDatabase).importBytes(bytes);

    expect(result.feeds, 2);
    final restoredFeed = await restoredDatabase.feedById('nostr-feed');
    expect(restoredFeed?.protocol, FeedProtocol.nostr.index);
    expect(restoredFeed?.subscribed, isFalse);
    expect(restoredFeed?.category, 'Technology');
    expect(
      (await restoredDatabase.select(restoredDatabase.nostrProfiles).get())
          .single
          .publicKey,
      publicKey,
    );
    final restoredArticle =
        (await restoredDatabase.select(restoredDatabase.articles).get())
            .where((article) => article.feedId == restoredFeed?.id)
            .single;
    final restoredAttachment =
        (await restoredDatabase
                .select(restoredDatabase.articleAttachments)
                .get())
            .single;
    final restoredEpisode =
        (await restoredDatabase.select(restoredDatabase.episodes).get())
            .where((episode) => episode.feedId == restoredFeed?.id)
            .single;
    final restoredProgress =
        (await restoredDatabase
                .select(restoredDatabase.playbackProgresses)
                .get())
            .single;
    expect(restoredAttachment.mimeType, 'audio/opus');
    expect(restoredAttachment.articleId, restoredArticle.id);
    expect(restoredEpisode.id, restoredAttachment.id);
    expect(restoredEpisode.guid, 'nostr-media:${restoredArticle.id}');
    expect(restoredProgress.episodeId, restoredAttachment.id);
    expect(restoredProgress.positionMs, 5000);

    // A newer edit removed its audio. An older backup may merge the saved
    // state, but not attach the previous revision's media to that edit.
    await (restoredDatabase.update(
      restoredDatabase.articles,
    )..where((row) => row.id.equals(restoredArticle.id))).write(
      ArticlesCompanion(
        sourceEventId: Value('f' * 64),
        title: const Value('Edited without audio'),
        starred: const Value(false),
        publishedAt: Value(now.add(const Duration(seconds: 1))),
      ),
    );
    await (restoredDatabase.delete(
      restoredDatabase.articleAttachments,
    )..where((row) => row.id.equals(restoredAttachment.id))).go();
    await (restoredDatabase.delete(
      restoredDatabase.episodes,
    )..where((row) => row.id.equals(restoredEpisode.id))).go();
    await BackupService(restoredDatabase).importBytes(bytes);
    final edited = await restoredDatabase.articleById(restoredArticle.id);
    expect(edited?.title, 'Edited without audio');
    expect(edited?.starred, isTrue);
    expect(
      await restoredDatabase.select(restoredDatabase.articleAttachments).get(),
      isEmpty,
    );
    expect(await restoredDatabase.episodeById(restoredEpisode.id), isNull);

    // A deletion learned after this backup must survive importing it again.
    await restoredDatabase
        .into(restoredDatabase.nostrDeletions)
        .insert(
          NostrDeletionsCompanion.insert(
            feedId: restoredFeed!.id,
            target: 'e:$eventId',
            deletedAt: now.add(const Duration(seconds: 1)),
          ),
        );
    await (restoredDatabase.delete(
      restoredDatabase.articles,
    )..where((row) => row.id.equals(restoredArticle.id))).go();
    final stale = await BackupService(restoredDatabase).importBytes(bytes);
    expect(stale.articles, 0);
    expect(
      await restoredDatabase.select(restoredDatabase.articles).get(),
      isEmpty,
    );
    expect(
      await restoredDatabase.select(restoredDatabase.articleAttachments).get(),
      isEmpty,
    );
    expect(await restoredDatabase.episodeById(restoredEpisode.id), isNull);
  });

  test(
    'restore matches private articles by link without mixing saved state',
    () async {
      final privateFeeds = PrivateFeedStore(
        storage: const FlutterSecureStorage(),
      );
      final feedUrl = Uri.parse('https://example.test/opaque-path/reader.xml');
      final credentialRef = await privateFeeds.save(
        PrivateFeedSecret(url: feedUrl, headers: const {}),
      );
      final now = DateTime.utc(2026, 7, 26);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'private-reader',
              title: 'Private reader',
              feedUrl: 'private://$credentialRef',
              isPrivate: const Value(true),
              credentialRef: Value(credentialRef),
              createdAt: now,
              updatedAt: now,
            ),
          );
      const articleId = 'article';
      await database
          .into(database.articles)
          .insert(
            ArticlesCompanion.insert(
              id: articleId,
              feedId: 'private-reader',
              title: 'Members only',
              canonicalUrl: const Value('https://example.test/story?token=old'),
              publishedAt: Value(now),
              discoveredAt: now,
              starred: const Value(true),
            ),
          );
      await database
          .into(database.articles)
          .insert(
            ArticlesCompanion.insert(
              id: 'second-article',
              feedId: 'private-reader',
              title: 'Members only',
              canonicalUrl: const Value('https://example.test/second-story'),
              publishedAt: Value(now),
              discoveredAt: now,
            ),
          );
      final service = BackupService(database, privateFeeds: privateFeeds);
      final bytes = await service.exportBytes();
      const latestUrl = 'https://example.test/story?token=new';
      await (database.update(
        database.articles,
      )..where((row) => row.id.equals(articleId))).write(
        ArticlesCompanion(
          canonicalUrl: const Value(latestUrl),
          starred: const Value(false),
          readAt: Value(now),
        ),
      );

      await service.importBytes(bytes);
      await service.importBytes(bytes);
      final restored = await database.select(database.articles).get();
      expect(
        restored.map((article) => article.id),
        unorderedEquals([articleId, 'second-article']),
      );
      final saved = restored.singleWhere((article) => article.id == articleId);
      expect(saved.canonicalUrl, latestUrl);
      expect(saved.readAt, isNotNull);
      expect(saved.starred, isTrue);
      expect(
        restored.singleWhere((article) => article.id != articleId).starred,
        isFalse,
      );

      await database.close();
      FlutterSecureStorage.setMockInitialValues({});
      database = AppDatabase.forTesting(NativeDatabase.memory());
      await BackupService(
        database,
        privateFeeds: privateFeeds,
      ).importBytes(bytes);
      expect(await database.select(database.articles).get(), hasLength(2));
      final restoredFeed = (await database.feedById('private-reader'))!;
      expect(restoredFeed.isPrivate, isTrue);
      expect(
        (await privateFeeds.read(restoredFeed.credentialRef!))?.url,
        feedUrl,
      );
    },
  );

  test(
    'tokenized backups merge into the matching private feed and restore on a new device',
    () async {
      final now = DateTime.utc(2026, 7, 26);
      final privateFeeds = PrivateFeedStore(
        storage: const FlutterSecureStorage(),
      );
      final feedUrl = Uri.parse('https://example.com/feed.xml?token=portable');
      final mediaUrl = Uri.parse(
        'https://cdn.example/audio.mp3?token=portable',
      );
      final credentialRef = await privateFeeds.save(
        PrivateFeedSecret(url: feedUrl, headers: const {}),
      );
      final otherCredentialRef = await privateFeeds.save(
        PrivateFeedSecret(
          url: feedUrl,
          headers: const {'Authorization': 'Bearer separate'},
        ),
      );
      for (final (id, ref) in [
        ('token-feed', credentialRef),
        ('other-access', otherCredentialRef),
      ]) {
        await database
            .into(database.feeds)
            .insert(
              FeedsCompanion.insert(
                id: id,
                title: 'Token podcast',
                feedUrl: 'private://$ref',
                kind: Value(FeedKind.podcast.index),
                isPrivate: const Value(true),
                credentialRef: Value(ref),
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      final episodeId = stableContentId(
        'token-feed',
        legacyPrivateEpisodeIdentity(
          enclosureUrl: mediaUrl,
          publishedAt: null,
          title: 'Private episode',
        ),
      );
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: episodeId,
              feedId: 'token-feed',
              title: 'Private episode',
              enclosureUrl: 'private-media://$episodeId',
              discoveredAt: now,
            ),
          );
      await privateFeeds.saveMediaUrl(episodeId, mediaUrl);
      await database
          .into(database.playbackProgresses)
          .insert(
            PlaybackProgressesCompanion.insert(
              episodeId: episodeId,
              positionMs: const Value(15000),
              updatedAt: now,
            ),
          );

      final bytes = await BackupService(
        database,
        privateFeeds: privateFeeds,
      ).exportBytes();
      final currentMedia = mediaUrl.replace(query: 'token=newer');
      await privateFeeds.saveMediaUrl(episodeId, currentMedia);
      await BackupService(
        database,
        privateFeeds: privateFeeds,
      ).importBytes(bytes);
      expect(await database.feedByUrl(feedUrl.toString()), isNull);
      expect(
        (await database.feedById('token-feed'))?.credentialRef,
        credentialRef,
      );
      expect(
        (await database.feedById('other-access'))?.credentialRef,
        otherCredentialRef,
      );
      expect(
        (await database.select(database.episodes).getSingle()).id,
        episodeId,
      );
      expect(await privateFeeds.readMediaUrl(episodeId), currentMedia);
      expect(
        (await database.select(database.playbackProgresses).getSingle())
            .positionMs,
        15000,
      );

      await database.close();
      database = AppDatabase.forTesting(NativeDatabase.memory());
      FlutterSecureStorage.setMockInitialValues({});
      final deviceStore = PrivateFeedStore();
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response<ResponseBody>(
                requestOptions: options,
                statusCode: 200,
                data: ResponseBody.fromString('''
          <rss version="2.0"><channel><title>Token podcast</title><item>
          <title>Private episode</title>
          <enclosure url="https://cdn.example/audio.mp3?token=refreshed" type="audio/mpeg"/>
          </item></channel></rss>
          ''', 200),
              ),
            ),
          ),
        );
      final network = SafeNetworkClient.forTesting(
        dio,
        addressValidator: (_) async {},
      );
      addTearDown(network.close);
      final repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: deviceStore,
      );
      final temporaryFeed = await repository.subscribe(
        'https://example.test/temporary.xml',
      );
      await repository.deleteFeed(temporaryFeed.id);
      final target = BackupService(
        database,
        privateFeeds: deviceStore,
        onImported: () async => repository.invalidatePrivateFeedIndex(),
      );
      // An older ZIP has the portable token URL, but no private marker.
      final archive = ZipDecoder().decodeBytes(bytes);
      final feedsChunk = archive.findFile('feeds-000000.json')!;
      final records = jsonDecode(utf8.decode(feedsChunk.readBytes()!)) as List;
      for (final record in records.cast<Map<String, dynamic>>()) {
        record.remove('portablePrivate');
      }
      final legacy = Archive();
      for (final entry in archive.files) {
        legacy.addFile(
          entry.name == feedsChunk.name
              ? ArchiveFile.string(feedsChunk.name, jsonEncode(records))
              : entry,
        );
      }
      final legacyBytes = ZipEncoder().encode(legacy);
      await database.customStatement('''
        CREATE TEMP TRIGGER reject_restored_progress
        BEFORE INSERT ON playback_progresses
        BEGIN
          SELECT RAISE(FAIL, 'forced restore failure');
        END
      ''');
      await expectLater(
        target.importBytes(legacyBytes),
        throwsA(isA<Exception>()),
      );
      expect(await database.feedById('token-feed'), isNull);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      await database.customStatement('DROP TRIGGER reject_restored_progress');
      final result = await target.importBytes(legacyBytes);
      expect(
        result.feeds,
        2,
        reason: 'The feed that needs an Authorization header is excluded',
      );

      final restored = (await database.feedById('token-feed'))!;
      final restoredEpisodeId = stableContentId(
        restored.id,
        episodeIdentity(
          guid: null,
          enclosureUrl: mediaUrl,
          publishedAt: null,
          title: 'Private episode',
        ),
      );
      expect(restored.isPrivate, isTrue);
      expect(await database.feedByUrl(feedUrl.toString()), isNull);
      expect((await deviceStore.read(restored.credentialRef!))?.url, feedUrl);
      expect(await repository.refreshFeed(restored), isTrue);
      expect((await repository.subscribe(feedUrl.toString())).id, restored.id);
      expect(
        (await database.select(database.episodes).getSingle()).id,
        restoredEpisodeId,
      );
      expect(
        (await deviceStore.readMediaUrl(
          restoredEpisodeId,
        ))?.queryParameters['token'],
        'refreshed',
      );
      final restoredProgress = await database
          .select(database.playbackProgresses)
          .getSingle();
      expect(restoredProgress.episodeId, restoredEpisodeId);
      expect(restoredProgress.positionMs, 15000);
    },
  );
}

extension on BackupService {
  Future<List<int>> exportBytes() async {
    final directory = await Directory.systemTemp.createTemp(
      'trickle-backup-test-',
    );
    try {
      final file = File('${directory.path}/backup.zip');
      await exportToFile(file);
      return await file.readAsBytes();
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<BackupResult> importBytes(List<int> bytes) async {
    final directory = await Directory.systemTemp.createTemp(
      'trickle-backup-test-',
    );
    try {
      final file = File('${directory.path}/backup.zip');
      await file.writeAsBytes(bytes);
      return await importFile(file);
    } finally {
      await directory.delete(recursive: true);
    }
  }
}
