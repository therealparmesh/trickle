import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/core/errors.dart';
import 'package:trickle/core/feed_identity.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/services/backup_service.dart';

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

  test('invalid archives return a safe, actionable backup error', () async {
    await expectLater(
      backups.importBytes(const [0, 1, 2, 3]),
      throwsA(
        isA<BackupException>().having(
          (error) => error.message,
          'message',
          'That file isn’t a valid trickle backup.',
        ),
      ),
    );
  });

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

  test('picker and file read failures return specific backup errors', () async {
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
  });

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

  test('version 2 backup round-trips Nostr media and playback state', () async {
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
  });

  test(
    'tokenized private feeds export without secure-store metadata',
    () async {
      final now = DateTime.utc(2026, 7, 26);
      final privateFeeds = PrivateFeedStore(
        storage: const FlutterSecureStorage(),
      );
      final credentialRef = await privateFeeds.save(
        PrivateFeedSecret(
          url: Uri.parse('https://example.com/feed.xml?token=portable'),
          headers: const {},
        ),
      );
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'token-feed',
              title: 'Token podcast',
              feedUrl: 'private://$credentialRef',
              kind: Value(FeedKind.podcast.index),
              isPrivate: const Value(true),
              credentialRef: Value(credentialRef),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: 'private-episode',
              feedId: 'token-feed',
              title: 'Private episode',
              enclosureUrl: 'private-media://private-episode',
              discoveredAt: now,
            ),
          );
      await privateFeeds.saveMediaUrl(
        'private-episode',
        Uri.parse('https://cdn.example/audio.mp3?token=portable'),
      );

      final bytes = await BackupService(
        database,
        privateFeeds: privateFeeds,
      ).exportBytes();
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase.memory());
      await BackupService(database).importBytes(bytes);

      final restored = await database.feedByUrl(
        'https://example.com/feed.xml?token=portable',
      );
      expect(restored?.isPrivate, isFalse);
      expect(restored?.credentialRef, isNull);
      expect(
        (await database.select(database.episodes).get())
            .where((episode) => episode.feedId == restored?.id)
            .single
            .enclosureUrl,
        'https://cdn.example/audio.mp3?token=portable',
      );
    },
  );
}
