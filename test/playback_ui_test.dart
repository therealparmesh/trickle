import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/playback_source_resolver.dart';
import 'package:trickle/data/repositories/settings_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/features/player/trickle_audio_handler.dart';
import 'package:trickle/presentation/playback_presentation.dart';

void main() {
  group('playback presentation', () {
    test('distinguishes new, partially played, and completed episodes', () {
      final now = DateTime.utc(2026, 7, 24);
      final episode = Episode(
        id: 'episode',
        feedId: 'feed',
        title: 'Episode',
        enclosureUrl: 'https://example.test/episode.mp3',
        durationMs: const Duration(minutes: 20).inMilliseconds,
        discoveredAt: now,
        explicit: false,
        played: false,
        starred: false,
        automationApplied: false,
      );
      final partial = PlaybackProgressesData(
        episodeId: episode.id,
        positionMs: const Duration(minutes: 5).inMilliseconds,
        durationMs: const Duration(minutes: 20).inMilliseconds,
        completed: false,
        updatedAt: now,
      );
      final completed = PlaybackProgressesData(
        episodeId: episode.id,
        positionMs: const Duration(minutes: 20).inMilliseconds,
        durationMs: const Duration(minutes: 20).inMilliseconds,
        completed: true,
        completedAt: now,
        updatedAt: now,
      );

      expect(
        episodeListeningState(episode, null),
        EpisodeListeningState.newEpisode,
      );
      expect(
        episodeListeningState(episode, partial),
        EpisodeListeningState.inProgress,
      );
      expect(episodeProgressFraction(episode, partial), 0.25);
      expect(
        episodeListeningState(episode, completed),
        EpisodeListeningState.played,
      );
      expect(episodeProgressFraction(episode, completed), isNull);
    });

    test('maps every engine state to one presentation phase', () {
      expect(
        playbackUiPhaseFor(processingState: null, playing: false),
        PlaybackUiPhase.loading,
      );
      expect(
        playbackUiPhaseFor(
          processingState: AudioProcessingState.loading,
          playing: false,
        ),
        PlaybackUiPhase.loading,
      );
      expect(
        playbackUiPhaseFor(
          processingState: AudioProcessingState.buffering,
          playing: true,
        ),
        PlaybackUiPhase.buffering,
      );
      expect(
        playbackUiPhaseFor(
          processingState: AudioProcessingState.error,
          playing: false,
        ),
        PlaybackUiPhase.error,
      );
      expect(
        playbackUiPhaseFor(
          processingState: AudioProcessingState.ready,
          playing: true,
        ),
        PlaybackUiPhase.playing,
      );
      expect(
        playbackUiPhaseFor(
          processingState: AudioProcessingState.ready,
          playing: false,
        ),
        PlaybackUiPhase.paused,
      );
    });

    test('uses distinct semantic copy and correct action states', () {
      final semantics = PlaybackUiPhase.values
          .map((phase) => phase.semanticStatus)
          .toSet();

      expect(semantics, hasLength(PlaybackUiPhase.values.length));
      expect(PlaybackUiPhase.loading.isBusy, isTrue);
      expect(PlaybackUiPhase.buffering.isBusy, isTrue);
      expect(PlaybackUiPhase.error.isBusy, isFalse);
      expect(PlaybackUiPhase.error.isError, isTrue);
      expect(
        PlaybackUiPhase.error.actionLabel(playing: false),
        'Retry playback',
      );
      expect(PlaybackUiPhase.buffering.actionLabel(playing: true), 'Pause');
      expect(PlaybackUiPhase.loading.canToggle(playing: false), isFalse);
    });
  });

  test('playback UI ignores buffer-only and unrelated state changes', () async {
    final states = StreamController<PlaybackState>.broadcast();
    final media = StreamController<MediaItem?>.broadcast();
    final container = ProviderContainer(
      overrides: [
        playbackStateProvider.overrideWith((_) => states.stream),
        currentMediaProvider.overrideWith((_) => media.stream),
      ],
    );
    final snapshots = <PlaybackUiSnapshot>[];
    final unrelatedSnapshots = <PlaybackItemUiSnapshot>[];
    final subscription = container.listen(
      playbackUiSnapshotProvider,
      (_, snapshot) => snapshots.add(snapshot),
      fireImmediately: true,
    );
    final unrelatedSubscription = container.listen(
      playbackItemUiSnapshotProvider('other-episode'),
      (_, snapshot) => unrelatedSnapshots.add(snapshot),
      fireImmediately: true,
    );
    addTearDown(() async {
      subscription.close();
      unrelatedSubscription.close();
      container.dispose();
      await states.close();
      await media.close();
    });

    media.add(const MediaItem(id: 'episode', title: 'Episode'));
    states.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: true,
        bufferedPosition: const Duration(seconds: 5),
      ),
    );
    await pumpEventQueue();
    final stableNotificationCount = snapshots.length;
    expect(unrelatedSnapshots, hasLength(1));

    states.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        playing: true,
        bufferedPosition: const Duration(minutes: 5),
      ),
    );
    await pumpEventQueue();
    expect(snapshots, hasLength(stableNotificationCount));

    states.add(
      PlaybackState(
        processingState: AudioProcessingState.ready,
        bufferedPosition: const Duration(minutes: 5),
      ),
    );
    await pumpEventQueue();
    expect(snapshots, hasLength(stableNotificationCount + 1));
    expect(snapshots.last.playing, isFalse);
    expect(unrelatedSnapshots, hasLength(1));
  });

  test('stale scrub cannot seek the newly selected episode', () async {
    final harness = _createPlaybackHarness();
    final handler = harness.handler;
    addTearDown(() => _disposePlaybackHarness(harness));
    const current = MediaItem(id: 'new-episode', title: 'New episode');
    handler.mediaItem.add(current);

    await handler.seekEpisode('old-episode', const Duration(minutes: 42));

    expect(handler.mediaItem.value, current);
    expect(handler.playbackState.value.updatePosition, Duration.zero);

    handler.mediaItem.add(null);
  });

  test('expired sleep timer clears when no player was initialized', () async {
    final harness = _createPlaybackHarness();
    final handler = harness.handler;
    addTearDown(() => _disposePlaybackHarness(harness));

    await handler.setSleepTimer(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      (await handler.sleepTimerStatusStream.first).mode,
      SleepTimerMode.off,
    );
  });

  test('a newer audio request supersedes a pending video request', () async {
    final harness = _createPlaybackHarness();
    final handler = harness.handler;
    final mediaIntents = <int>[];
    final subscription = handler.mediaPlaybackIntentStream.listen(
      mediaIntents.add,
    );
    addTearDown(() async {
      await subscription.cancel();
      await _disposePlaybackHarness(harness);
    });

    final videoIntent = handler.beginWebVideoPlayback();
    expect(handler.isWebVideoPlaybackCurrent(videoIntent), isTrue);

    await handler.play();

    expect(handler.isWebVideoPlaybackCurrent(videoIntent), isFalse);
    expect(mediaIntents, [videoIntent, isNot(videoIntent)]);
  });

  test('native queue publishes valid artwork and current controls', () async {
    final harness = _createPlaybackHarness();
    final database = harness.database;
    final handler = harness.handler;
    addTearDown(() => _disposePlaybackHarness(harness));
    final now = DateTime.utc(2026, 7, 22);
    for (final feed in [
      FeedsCompanion.insert(
        id: 'empty',
        title: 'No artwork',
        feedUrl: 'https://empty.test/feed',
        imageUrl: const Value('not a URL'),
        createdAt: now,
        updatedAt: now,
      ),
      FeedsCompanion.insert(
        id: 'private',
        title: 'Private artwork',
        feedUrl: 'private://private',
        imageUrl: const Value('https://private.test/secret.jpg?token=SECRET'),
        isPrivate: const Value(true),
        credentialRef: const Value('private'),
        createdAt: now,
        updatedAt: now,
      ),
      FeedsCompanion.insert(
        id: 'public',
        title: 'Public artwork',
        feedUrl: 'https://public.test/feed',
        imageUrl: const Value('https://public.test/art.jpg'),
        createdAt: now,
        updatedAt: now,
      ),
    ]) {
      await database.into(database.feeds).insert(feed);
    }
    for (final entry in const [
      ('empty-episode', 'empty', null),
      (
        'private-episode',
        'private',
        'https://private.test/episode.jpg?token=SECRET',
      ),
      ('public-episode', 'public', null),
    ]) {
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: entry.$1,
              feedId: entry.$2,
              title: entry.$1,
              enclosureUrl: 'https://example.test/${entry.$1}.mp3',
              imageUrl: Value(entry.$3),
              discoveredAt: now,
            ),
          );
      await database
          .into(database.queueEntries)
          .insert(
            QueueEntriesCompanion.insert(
              id: 'queue-${entry.$1}',
              episodeId: entry.$1,
              sortKey: entry.$2 == 'empty'
                  ? 0
                  : entry.$2 == 'private'
                  ? 1
                  : 2,
              addedAt: now,
            ),
          );
    }

    await handler.reloadQueueFromDatabase();

    expect(handler.queue.value[0].artUri, isNull);
    expect(
      handler.queue.value[1].artUri,
      Uri.parse('https://private.test/episode.jpg?token=SECRET'),
    );
    expect(
      handler.queue.value[2].artUri,
      Uri.parse('https://public.test/art.jpg'),
    );

    handler.mediaItem.add(handler.queue.value.first);
    await handler.updateQueue([handler.queue.value.first]);
    expect(
      handler.playbackState.value.controls,
      isNot(contains(MediaControl.skipToNext)),
    );
    await handler.addEpisodeToQueue('private-episode');
    expect(
      handler.playbackState.value.controls,
      contains(MediaControl.skipToNext),
    );
  });

  test('queue reload cannot replace a newer in-memory edit', () async {
    final harness = _createPlaybackHarness();
    final database = harness.database;
    final handler = harness.handler;
    addTearDown(() => _disposePlaybackHarness(harness));
    final now = DateTime.utc(2026, 8, 23);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.test/feed',
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final id in const ['stored', 'newer']) {
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: id,
              feedId: 'feed',
              title: id,
              enclosureUrl: 'https://example.test/$id.mp3',
              discoveredAt: now,
            ),
          );
    }
    await database
        .into(database.queueEntries)
        .insert(
          QueueEntriesCompanion.insert(
            id: 'stored-queue-entry',
            episodeId: 'stored',
            sortKey: 0,
            addedAt: now,
          ),
        );

    final reload = handler.reloadQueueFromDatabase();
    final update = handler.updateQueue(const [
      MediaItem(id: 'newer', title: 'newer'),
    ]);
    await Future.wait([reload, update]);

    expect(handler.queue.value.map((item) => item.id), ['newer']);
    expect(
      (await database.select(database.queueEntries).get()).single.episodeId,
      'newer',
    );
  });

  test('background queue additions survive handoff and merge once', () async {
    final harness = _createPlaybackHarness();
    final database = harness.database;
    final handler = harness.handler;
    addTearDown(() => _disposePlaybackHarness(harness));
    final now = DateTime.utc(2026, 9, 1);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.test/feed',
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final id in const ['current', 'first-pending', 'second-pending']) {
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: id,
              feedId: 'feed',
              title: id,
              enclosureUrl: 'https://example.test/$id.mp3',
              discoveredAt: now,
            ),
          );
    }
    await database
        .into(database.queueEntries)
        .insert(
          QueueEntriesCompanion.insert(
            id: 'current-entry',
            episodeId: 'current',
            sortKey: 0,
            addedAt: now,
          ),
        );
    await database.stageQueueAdditions(const [
      'first-pending',
      'second-pending',
      'first-pending',
    ]);

    // Simulate a foreground queue snapshot winning after the background
    // additions were merged but before the active handler acknowledged them.
    await database.mergePendingQueueAdditions();
    await database.batch((batch) {
      batch.deleteAll(database.queueEntries);
      batch.insert(
        database.queueEntries,
        QueueEntriesCompanion.insert(
          id: 'replacement-current-entry',
          episodeId: 'current',
          sortKey: 0,
          addedAt: now,
        ),
      );
    });

    await handler.reloadQueueFromDatabase();
    await handler.reloadQueueFromDatabase();

    expect(handler.queue.value.map((item) => item.id), [
      'current',
      'first-pending',
      'second-pending',
    ]);
    expect(await database.select(database.pendingQueueAdds).get(), isEmpty);
    expect(await database.select(database.queueEntries).get(), hasLength(3));
  });

  test('only a usable completed audio file bypasses streaming', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final adapter = _MediaAdapter();
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    final directory = await Directory.systemTemp.createTemp('trickle-audio-');
    addTearDown(() async {
      network.close();
      await database.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final emptyFile = File('${directory.path}/empty.mp3');
    await emptyFile.create();
    final now = DateTime.utc(2026, 7, 18);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.test/feed',
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
            enclosureUrl: 'https://example.test/audio.mp3',
            discoveredAt: now,
          ),
        );
    await database
        .into(database.mediaDownloads)
        .insert(
          MediaDownloadsCompanion.insert(
            episodeId: 'episode',
            taskId: 'task',
            status: Value(DownloadState.complete.index),
            filePath: Value(emptyFile.path),
            updatedAt: now,
          ),
        );

    final resolver = PlaybackSourceResolver(
      database,
      PrivateFeedStore(),
      network,
    );
    final episode = (await database.episodeById('episode'))!;

    final emptySource = await resolver.resolve(episode);
    await emptyFile.writeAsString('<html>expired download</html>');
    final webPageSource = await resolver.resolve(episode);
    await emptyFile.writeAsBytes(const [0x49, 0x44, 0x33, 0x04]);
    final localSource = await resolver.resolve(episode);

    expect(emptySource.isLocal, isFalse);
    expect(webPageSource.isLocal, isFalse);
    expect(localSource.isLocal, isTrue);
    expect(localSource.resource, emptyFile.path);
    expect(adapter.requests, 2);
  });
}

typedef _PlaybackHarness = ({
  AppDatabase database,
  SafeNetworkClient network,
  TrickleAudioHandler handler,
});

_PlaybackHarness _createPlaybackHarness() {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final network = SafeNetworkClient.forTesting(
    Dio(),
    addressValidator: (_) async {},
  );
  return (
    database: database,
    network: network,
    handler: TrickleAudioHandler(
      database: database,
      settings: SettingsRepository(database),
      sourceResolver: PlaybackSourceResolver(
        database,
        PrivateFeedStore(),
        network,
      ),
    ),
  );
}

Future<void> _disposePlaybackHarness(_PlaybackHarness harness) async {
  await harness.handler.disposeHandler();
  harness.network.close();
  await harness.database.close();
}

final class _MediaAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString('', HttpStatus.partialContent);
  }

  @override
  void close({bool force = false}) {}
}
