import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/playback_source_resolver.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/repositories/settings_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/features/player/trickle_audio_handler.dart';
import 'package:trickle/features/video/video_session.dart';
import 'package:trickle/presentation/playback_presentation.dart';
import 'package:trickle/presentation/subscription_actions.dart';
import 'package:trickle/presentation/widgets/article_attachments.dart';
import 'package:trickle/presentation/widgets/video_player_host.dart';

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'unsubscribe finishes playback cleanup after leaving the screen',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final harness = createPlaybackHarness();
      final database = harness.database;
      final repository = FeedRepository(
        database: database,
        network: harness.network,
        privateFeeds: PrivateFeedStore(),
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          feedRepositoryProvider.overrideWithValue(repository),
          audioHandlerProvider.overrideWithValue(harness.handler),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await disposePlaybackHarness(harness);
      });
      final now = DateTime.utc(2026, 9, 21);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'feed',
              title: 'Feed',
              feedUrl: 'https://example.test/feed',
              kind: Value(FeedKind.podcast.index),
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
      final feed = (await database.feedById('feed'))!;
      harness.handler.mediaItem.add(
        const MediaItem(id: 'episode', title: 'Episode'),
      );
      late WidgetRef screenRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (_, ref, _) {
              screenRef = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      final removal = removeSubscription(screenRef, feed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await removal;
      expect(await database.feedById('feed'), isNull);
      expect(await database.episodeById('episode'), isNull);
      expect(harness.handler.mediaItem.value, isNull);
      expect(tester.takeException(), isNull);
      final disposal = harness.handler.disposeHandler();
      await tester.pumpAndSettle();
      await disposal;
    },
  );

  testWidgets(
    'removing or replacing a video closes its session in every presentation',
    (tester) async {
      final harness = createPlaybackHarness();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(harness.database),
          audioHandlerProvider.overrideWithValue(harness.handler),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await disposePlaybackHarness(harness);
      });
      final now = DateTime.utc(2026, 9, 21);
      await harness.database
          .into(harness.database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'feed',
              title: 'Feed',
              feedUrl: 'https://example.test/feed',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: VideoPlayerHost(child: SizedBox())),
        ),
      );
      for (final presentation in VideoPresentation.values) {
        const original = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
        final article = harness.database.articles;
        await harness.database
            .into(harness.database.articles)
            .insertOnConflictUpdate(
              ArticlesCompanion.insert(
                id: 'video',
                feedId: 'feed',
                title: 'Video',
                canonicalUrl: const Value(original),
                discoveredAt: now,
              ),
            );
        final intent = harness.handler.beginWebVideoPlayback();
        final notifier = container.read(videoSessionProvider.notifier);
        notifier.open(
          intentRevision: intent,
          articleId: 'video',
          title: 'Video',
          sourceUri: Uri.parse(original),
          playbackUri: Uri.parse('https://example.test/video.mp4'),
        );
        if (presentation == VideoPresentation.minimized) notifier.minimize();
        if (presentation == VideoPresentation.pictureInPicture) {
          notifier.enterPictureInPicture();
        }
        await tester.pumpAndSettle();
        expect(
          container.read(videoSessionProvider)?.presentation,
          presentation,
        );
        final current = harness.database.update(article)
          ..where((row) => row.id.equals('video'));
        await current.write(
          const ArticlesCompanion(
            canonicalUrl: Value('https://youtu.be/dQw4w9WgXcQ'),
          ),
        );
        await tester.pumpAndSettle();
        expect(container.read(videoSessionProvider)?.intentRevision, intent);
        if (presentation == VideoPresentation.expanded) {
          await (harness.database.delete(
            article,
          )..where((row) => row.id.equals('video'))).go();
        } else {
          await current.write(
            const ArticlesCompanion(
              canonicalUrl: Value(
                'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
              ),
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(container.read(videoSessionProvider), isNull);
        expect(harness.handler.isWebVideoPlaybackCurrent(intent), isFalse);
        expect(tester.takeException(), isNull);
      }
      const primary = 'https://example.test/primary.mp4';
      final fallback = Uri.parse('https://example.test/fallback.mp4');
      final post = await harness.database
          .into(harness.database.articles)
          .insertReturning(
            ArticlesCompanion.insert(
              id: 'post',
              feedId: 'feed',
              title: 'Post',
              discoveredAt: now,
            ),
          );
      final attachments = harness.database.articleAttachments;
      await harness.database
          .into(attachments)
          .insert(
            ArticleAttachmentsCompanion.insert(
              id: 'attachment',
              articleId: post.id,
              position: 0,
              url: primary,
            ),
          );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: VideoPlayerHost(
              child: Scaffold(body: ArticleAttachmentsView(article: post)),
            ),
          ),
        ),
      );
      final intent = harness.handler.beginWebVideoPlayback();
      container.read(videoSessionProvider.notifier)
        ..open(
          intentRevision: intent,
          articleId: post.id,
          title: 'Post',
          sourceUri: fallback,
          playbackUri: fallback,
          attachmentId: 'attachment',
        )
        ..minimize();
      await tester.pumpAndSettle();
      expect(container.read(videoSessionProvider)?.intentRevision, intent);
      expect(
        find.widgetWithText(FilledButton, 'Open video player'),
        findsOneWidget,
      );
      await (harness.database.delete(
        attachments,
      )..where((row) => row.id.equals('attachment'))).go();
      await tester.pumpAndSettle();
      expect(container.read(videoSessionProvider), isNull);
      expect(harness.handler.isWebVideoPlaybackCurrent(intent), isFalse);
      expect(find.widgetWithText(FilledButton, 'Play video'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      final disposal = harness.handler.disposeHandler();
      await tester.pumpAndSettle();
      await disposal;
    },
  );

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
        queueAutomationApplied: false,
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
      expect(
        episodeProgressFraction(episode.copyWith(played: true), partial),
        isNull,
      );
      expect(
        episodeListeningState(episode, partial.copyWith(positionMs: 0)),
        EpisodeListeningState.newEpisode,
      );
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

  test(
    'last unfinished audio restores paused and survives queue clearing but not removal',
    () async {
      final harness = createPlaybackHarness();
      final database = harness.database;
      final handler = harness.handler;
      addTearDown(() => disposePlaybackHarness(harness));
      final now = DateTime.utc(2026, 9, 21);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'feed',
              title: 'Feed',
              feedUrl: 'https://example.test/feed',
              kind: Value(FeedKind.podcast.index),
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (final (id, played, completed, position, age) in [
        ('old', false, false, 30000, 3),
        ('latest', false, false, 5000, 2),
        ('played', true, false, 40000, 1),
        ('completed', false, true, 60000, 0),
      ]) {
        await database
            .into(database.episodes)
            .insert(
              EpisodesCompanion.insert(
                id: id,
                feedId: 'feed',
                title: id,
                enclosureUrl: 'https://example.test/$id.mp3',
                durationMs: const Value(60000),
                played: Value(played),
                discoveredAt: now,
              ),
            );
        await database
            .into(database.playbackProgresses)
            .insert(
              PlaybackProgressesCompanion.insert(
                episodeId: id,
                positionMs: Value(position),
                durationMs: const Value(60000),
                completed: Value(completed),
                updatedAt: now.subtract(Duration(minutes: age)),
              ),
            );
      }
      await handler.restoreLastPlayback();
      expect(handler.mediaItem.value?.id, 'latest');
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(await handler.positionStream.first, const Duration(seconds: 5));
      await handler.seek(const Duration(seconds: 8));
      await handler.clearQueue();
      expect(handler.mediaItem.value?.id, 'latest');
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 8),
      );
      await handler.setEpisodePlayed('latest', false);
      expect(handler.mediaItem.value, isNull);
      expect(
        (await database.watchPlaybackProgressForEpisode('latest').first)
            ?.positionMs,
        0,
      );
      await handler.restoreLastPlayback();
      expect(handler.mediaItem.value?.id, 'old');
      await handler.removeEpisodesFromLibrary(['old']);
      await (database.delete(
        database.episodes,
      )..where((row) => row.id.equals('old'))).go();
      expect(handler.mediaItem.value, isNull);
      await handler.restoreLastPlayback();
      expect(handler.mediaItem.value, isNull);
    },
  );

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
    final harness = createPlaybackHarness();
    final handler = harness.handler;
    addTearDown(() => disposePlaybackHarness(harness));
    const current = MediaItem(id: 'new-episode', title: 'New episode');
    handler.mediaItem.add(current);

    await handler.seekEpisode('old-episode', const Duration(minutes: 42));

    expect(handler.mediaItem.value, current);
    expect(handler.playbackState.value.updatePosition, Duration.zero);

    handler.mediaItem.add(null);
  });

  test('expired sleep timer clears when no player was initialized', () async {
    final harness = createPlaybackHarness();
    final handler = harness.handler;
    addTearDown(() => disposePlaybackHarness(harness));

    await handler.setSleepTimer(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      (await handler.sleepTimerStatusStream.first).mode,
      SleepTimerMode.off,
    );
  });

  test('a newer audio request supersedes a pending video request', () async {
    final harness = createPlaybackHarness();
    final handler = harness.handler;
    final mediaIntents = <int>[];
    final subscription = handler.mediaPlaybackIntentStream.listen(
      mediaIntents.add,
    );
    addTearDown(() async {
      await subscription.cancel();
      await disposePlaybackHarness(harness);
    });

    final videoIntent = handler.beginWebVideoPlayback();
    expect(handler.isWebVideoPlaybackCurrent(videoIntent), isTrue);

    await handler.play();

    expect(handler.isWebVideoPlaybackCurrent(videoIntent), isFalse);
    expect(mediaIntents, [videoIntent, isNot(videoIntent)]);
  });

  test('native queue publishes valid artwork and current controls', () async {
    final harness = createPlaybackHarness();
    final database = harness.database;
    final handler = harness.handler;
    addTearDown(() => disposePlaybackHarness(harness));
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

  test(
    'an add during queue reload keeps the stored and new episodes',
    () async {
      final harness = createPlaybackHarness();
      final database = harness.database;
      final handler = harness.handler;
      addTearDown(() => disposePlaybackHarness(harness));
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
      final add = handler.addEpisodeToQueue('newer');
      await Future.wait([reload, add]);

      expect(handler.queue.value.map((item) => item.id), ['stored', 'newer']);
      expect(
        (await database.watchQueuedEpisodes().first).map(
          (episode) => episode.id,
        ),
        ['stored', 'newer'],
      );
    },
  );

  test(
    'queue edits skip a deleted episode without losing valid entries',
    () async {
      final harness = createPlaybackHarness();
      addTearDown(() => disposePlaybackHarness(harness));
      final (current, deleted, other) = await seedPlaybackQueue(harness);
      final database = harness.database;
      final handler = harness.handler;
      await (database.delete(
        database.episodes,
      )..where((row) => row.id.equals(deleted.id))).go();

      // A second queue edit can arrive while the first write is still pending.
      final stale = handler.updateQueue([deleted, current, other]);
      final latest = handler.updateQueue([other, deleted, current]);
      await Future.wait([stale, latest]);
      expect(handler.queue.value.map((item) => item.id), [
        other.id,
        current.id,
      ]);
      await handler.reloadQueueFromDatabase();
      expect(handler.queue.value.map((item) => item.id), [
        other.id,
        current.id,
      ]);
    },
  );

  test('subscription cleanup preserves an unloaded queue', () async {
    final harness = createPlaybackHarness();
    addTearDown(() => disposePlaybackHarness(harness));
    final (current, _, other) = await seedPlaybackQueue(harness);
    final database = harness.database;
    // Use a fresh handler that has not restored the persisted queue yet.
    final handler = TrickleAudioHandler(
      database: database,
      settings: SettingsRepository(database),
      sourceResolver: PlaybackSourceResolver(
        database,
        PrivateFeedStore(),
        harness.network,
      ),
    );
    addTearDown(handler.disposeHandler);
    await (database.delete(
      database.episodes,
    )..where((row) => row.id.equals(current.id))).go();
    await handler.removeEpisodesFromLibrary([current.id]);
    await handler.reloadQueueFromDatabase();
    expect(handler.queue.value.map((item) => item.id), ['selected', other.id]);
  });

  test('a failed episode load cannot erase its saved position', () async {
    final harness = createPlaybackHarness(
      addressValidator: (_) async {
        throw StateError('Network unavailable');
      },
    );
    addTearDown(() => disposePlaybackHarness(harness));
    final (_, selected, _) = await seedPlaybackQueue(harness);
    await harness.database
        .into(harness.database.playbackProgresses)
        .insert(
          PlaybackProgressesCompanion.insert(
            episodeId: selected.id,
            positionMs: const Value(55000),
            updatedAt: DateTime.utc(2026, 9, 21),
          ),
        );

    await expectLater(
      harness.handler.playQueuedEpisode(selected.id),
      throwsStateError,
    );
    await harness.handler.stop();
    // A second stop after the error clears still has no loaded position.
    await harness.handler.stop();

    final progress = await harness.database
        .watchPlaybackProgressForEpisode(selected.id)
        .first;
    expect(progress?.positionMs, 55000);
  });

  test(
    'a video opened during a podcast load leaves the right episode ready to resume',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'trickle-player-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final native = MockNativeAudio(directory.path);
      final cache = CacheManager(
        Config('test-player', repo: NonStoringObjectProvider()),
      );
      addTearDown(cache.dispose);
      final resolvingSelected = Completer<void>();
      final finishResolving = Completer<void>();
      final harness = createPlaybackHarness(
        adapter: MockMediaAdapter(),
        artworkCache: cache,
        addressValidator: (url) async {
          if (url.path == '/selected.mp3' && !resolvingSelected.isCompleted) {
            resolvingSelected.complete();
            await finishResolving.future;
          }
        },
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final handler = harness.handler;
      final (_, selected, _) = await seedPlaybackQueue(harness);
      await harness.database
          .into(harness.database.playbackProgresses)
          .insert(
            PlaybackProgressesCompanion.insert(
              episodeId: selected.id,
              positionMs: const Value(55000),
              updatedAt: DateTime.utc(2026, 9, 21),
            ),
          );

      await handler.play();
      expect(native.loaded, ['/current.mp3']);

      final switching = handler.playQueuedEpisode(selected.id);
      await resolvingSelected.future;
      await native.emit(position: const Duration(seconds: 20));
      expect(await handler.positionStream.first, Duration.zero);
      expect(handler.mediaItem.value?.duration, isNull);

      final intent = handler.beginWebVideoPlayback();
      finishResolving.complete();
      expect(await handler.prepareWebVideoPlayback(intent), isTrue);
      await switching;
      await handler.endWebVideoPlayback(intent);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(handler.playbackState.value.playing, isFalse);

      await handler.play();
      expect(native.loaded, ['/current.mp3', '/selected.mp3']);
      expect(native.seeks, [const Duration(seconds: 55)]);

      // A fully loaded podcast stays paused in the native player while video
      // owns the session, so returning to it doesn't reopen the media.
      final secondIntent = handler.beginWebVideoPlayback();
      expect(await handler.prepareWebVideoPlayback(secondIntent), isTrue);
      await handler.endWebVideoPlayback(secondIntent);
      await handler.play();
      expect(native.loaded, ['/current.mp3', '/selected.mp3']);

      await handler.clearQueue();
      await handler.seekEpisode(selected.id, const Duration(seconds: 40));
      await handler.setSpeed(1.25);
      await Future<void>.delayed(Duration.zero);
      expect(await handler.positionStream.first, const Duration(seconds: 40));
      await handler.play();
      expect(native.seeks.last, const Duration(seconds: 40));
    },
  );

  test(
    'clearing Up next drops staged entries but keeps later additions',
    () async {
      final harness = createPlaybackHarness();
      addTearDown(() => disposePlaybackHarness(harness));
      final (current, selected, staged) = await seedPlaybackQueue(harness);
      await harness.handler.updateQueue([current]);
      await harness.database
          .update(harness.database.feeds)
          .write(const FeedsCompanion(autoQueue: Value(true)));
      await harness.database.stageAutomaticQueueAdditions([staged.id]);

      final addBeforeClear = harness.handler.addEpisodeToQueue(staged.id);
      final clear = harness.handler.clearQueue();
      final add = harness.handler.addEpisodeToQueue(selected.id);
      await Future.wait([addBeforeClear, clear, add]);
      await harness.handler.reloadQueueFromDatabase();

      expect(harness.handler.queue.value.single.id, selected.id);
      expect(
        (await harness.database
                .select(harness.database.queueEntries)
                .getSingle())
            .episodeId,
        selected.id,
      );
    },
  );

  test(
    'queue navigation follows the selected episode across reordering',
    () async {
      final requests = <String>[];
      final harness = createPlaybackHarness(
        addressValidator: (url) async {
          requests.add(url.path);
          throw StateError('Stop before loading a native player');
        },
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final (current, selected, other) = await seedPlaybackQueue(harness);

      final playback = expectLater(
        harness.handler.skipToQueueItem(1),
        throwsStateError,
      );
      await harness.handler.updateQueue([current, other, selected]);
      await playback;

      expect(requests, ['/selected.mp3']);
      expect(harness.handler.mediaItem.value?.id, selected.id);
    },
  );

  test('a stale reorder cannot discard an episode added to Up next', () async {
    final harness = createPlaybackHarness();
    addTearDown(() => disposePlaybackHarness(harness));
    final (current, selected, added) = await seedPlaybackQueue(harness);
    final handler = harness.handler;
    await handler.updateQueue([current, selected]);
    final displayed = handler.queue.value;
    await handler.addEpisodeToQueue(added.id);

    await handler.reorderQueue(displayed, 0, 1);
    expect(handler.queue.value.map((item) => item.id), [
      current.id,
      selected.id,
      added.id,
    ]);

    await handler.reorderQueue(handler.queue.value, 0, 1);
    expect(
      (await harness.database.watchQueuedEpisodes().first).map(
        (item) => item.id,
      ),
      [selected.id, current.id, added.id],
    );
  });

  test('a failed queue edit leaves the queue visible and reloadable', () async {
    final harness = createPlaybackHarness();
    addTearDown(() => disposePlaybackHarness(harness));
    final (current, selected, staged) = await seedPlaybackQueue(harness);
    final database = harness.database;
    final handler = harness.handler;
    await handler.updateQueue([current, selected]);
    await database
        .update(database.feeds)
        .write(const FeedsCompanion(autoQueue: Value(true)));
    await database.customStatement(
      'CREATE TRIGGER reject_queue_edit BEFORE DELETE ON queue_entries '
      "BEGIN SELECT RAISE(ABORT, 'Queue edit rejected'); END",
    );

    await expectLater(
      handler.removeQueueItem(selected),
      throwsA(isA<Exception>()),
    );
    expect(handler.queue.value.map((item) => item.id), [
      current.id,
      selected.id,
    ]);
    await database.stageAutomaticQueueAdditions([staged.id]);
    await handler.reloadQueueFromDatabase();

    expect(handler.queue.value.map((item) => item.id), [
      current.id,
      selected.id,
      staged.id,
    ]);
    expect(await database.select(database.pendingQueueAdds).get(), isEmpty);
  });

  test('a staged addition cannot requeue a manually removed episode', () async {
    final harness = createPlaybackHarness();
    addTearDown(() => disposePlaybackHarness(harness));
    final (current, selected, other) = await seedPlaybackQueue(harness);
    final database = harness.database;
    final handler = harness.handler;
    await handler.updateQueue([current]);
    await database
        .update(database.feeds)
        .write(const FeedsCompanion(autoQueue: Value(true)));
    await database.stageAutomaticQueueAdditions([selected.id, other.id]);

    await handler.addEpisodeToQueue(selected.id);
    await handler.removeQueueItem(selected);
    await handler.reloadQueueFromDatabase();

    expect(handler.queue.value.map((item) => item.id), [current.id, other.id]);
  });

  test(
    'removing the playing queue entry leaves a newer playback choice alone',
    () async {
      final requests = <String>[];
      final harness = createPlaybackHarness(
        addressValidator: (url) async {
          requests.add(url.path);
          throw StateError('Stop before loading a native player');
        },
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final (current, selected, other) = await seedPlaybackQueue(harness);

      final removal = harness.handler.removeQueueItem(current);
      final playback = expectLater(
        harness.handler.playQueuedEpisode(other.id),
        throwsStateError,
      );
      await Future.wait([removal, playback]);

      expect(requests, ['/other.mp3']);
      expect(harness.handler.mediaItem.value?.id, other.id);
      expect(harness.handler.queue.value.map((item) => item.id), [
        selected.id,
        other.id,
      ]);
    },
  );

  test('background queue additions survive handoff and merge once', () async {
    final harness = createPlaybackHarness();
    final database = harness.database;
    final handler = harness.handler;
    addTearDown(() => disposePlaybackHarness(harness));
    final now = DateTime.utc(2026, 9, 1);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.test/feed',
            autoQueue: const Value(true),
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
    await database.stageAutomaticQueueAdditions(const [
      'first-pending',
      'episode-removed-during-refresh',
      'second-pending',
      'first-pending',
    ]);

    // A failed handoff must leave neither half committed.
    await database.customStatement(
      'CREATE TRIGGER reject_queue_handoff BEFORE DELETE ON pending_queue_adds '
      "BEGIN SELECT RAISE(ABORT, 'Queue handoff rejected'); END",
    );
    await expectLater(
      handler.reloadQueueFromDatabase(),
      throwsA(isA<Exception>()),
    );
    expect(
      (await database.select(database.queueEntries).getSingle()).episodeId,
      'current',
    );
    expect(
      await database.select(database.pendingQueueAdds).get(),
      hasLength(2),
    );
    await database.customStatement('DROP TRIGGER reject_queue_handoff');

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

  test(
    'download playback rebases valid paths and repairs missing files',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final adapter = MockMediaAdapter();
      final network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = adapter,
        addressValidator: (_) async {},
      );
      final directory = await Directory.systemTemp.createTemp('trickle-audio-');
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => directory.path,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathProvider, null);
        network.close();
        await database.close();
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final localFile = File('${directory.path}/media/episode-task.mp3');
      await localFile.create(recursive: true);
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
              filePath: const Value(
                '/old-container/Library/Application Support/media/episode-task.mp3',
              ),
              updatedAt: now,
            ),
          );

      final resolver = PlaybackSourceResolver(
        database,
        PrivateFeedStore(),
        network,
      );
      final episode = (await database.episodeById('episode'))!;

      await localFile.writeAsBytes(const [0x49, 0x44, 0x33, 0x04]);
      final localSource = await resolver.resolve(episode);

      expect(localSource.isLocal, isTrue);
      expect(localSource.resource, localFile.path);
      await database
          .update(database.mediaDownloads)
          .write(
            const MediaDownloadsCompanion(
              filePath: Value('media/episode-task.mp3'),
            ),
          );
      expect((await resolver.resolve(episode)).resource, localFile.path);
      expect(adapter.requests, 0);

      for (final missing in [true, false]) {
        if (missing) {
          await localFile.delete();
        } else {
          await localFile.writeAsString('<html>expired download</html>');
        }
        await database
            .update(database.mediaDownloads)
            .write(
              MediaDownloadsCompanion(
                status: Value(DownloadState.complete.index),
                bytesDownloaded: const Value(100),
                totalBytes: const Value(100),
              ),
            );
        expect((await resolver.resolve(episode)).isLocal, isFalse);
        final row = await database.select(database.mediaDownloads).getSingle();
        expect(row.status, DownloadState.failed.index);
        expect(row.bytesDownloaded, 0);
        expect(row.totalBytes, isNull);
        expect(row.filePath, 'media/episode-task.mp3');
      }
      expect(adapter.requests, 2);

      final old = await database.select(database.mediaDownloads).getSingle();
      await database
          .update(database.mediaDownloads)
          .write(
            MediaDownloadsCompanion(
              taskId: const Value('replacement'),
              status: Value(DownloadState.complete.index),
              filePath: const Value('media/replacement.mp3'),
              bytesDownloaded: const Value(200),
              totalBytes: const Value(200),
            ),
          );
      await database.markDownloadFileUnavailable(old);
      final replacement = await database
          .select(database.mediaDownloads)
          .getSingle();
      expect(replacement.status, DownloadState.complete.index);
      expect(replacement.bytesDownloaded, 200);
    },
  );
}
