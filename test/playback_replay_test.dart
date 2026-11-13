import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/repositories/playback_source_resolver.dart';
import 'package:trickle/data/repositories/settings_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/features/player/trickle_audio_handler.dart';

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an unfinished replay resumes without losing completion on failed load',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'trickle-replay-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var rejectLoad = true;
      final native = MockNativeAudio(
        directory.path,
        onLoad: (_) async {
          if (rejectLoad) throw PlatformException(code: 'replay-load-failed');
        },
      );
      final cache = CacheManager(
        Config('test-replay', repo: NonStoringObjectProvider()),
      );
      addTearDown(cache.dispose);
      final harness = createPlaybackHarness(
        adapter: MockMediaAdapter(),
        artworkCache: cache,
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final handler = harness.handler;
      final database = harness.database;
      final (_, episode, _) = await seedPlaybackQueue(harness);
      await database
          .update(database.feeds)
          .write(FeedsCompanion(kind: Value(FeedKind.podcast.index)));
      await handler.setEpisodePlayed(episode.id, true);

      await expectLater(
        handler.playEpisode(episode.id),
        throwsA(isA<Exception>()),
      );
      expect((await database.episodeById(episode.id))!.played, isTrue);

      rejectLoad = false;
      await handler.play();
      await handler.pause();
      expect((await database.episodeById(episode.id))!.played, isTrue);
      await handler.play();
      const position = Duration(seconds: 45);
      await native.emit(position: position);
      await handler.pause();
      final checkpoint = await database
          .watchPlaybackProgressForEpisode(episode.id)
          .first;
      final savedPosition = Duration(milliseconds: checkpoint!.positionMs);
      expect(savedPosition.inSeconds, position.inSeconds);
      expect(checkpoint.completed, isFalse);
      expect(checkpoint.completedAt, isNull);
      expect(
        (await database.watchInProgressEpisodes().first).single.id,
        episode.id,
      );

      await handler.stop();
      await handler.play();
      expect(native.seeks.last, savedPosition);

      final reopened = TrickleAudioHandler(
        database: database,
        settings: SettingsRepository(database),
        sourceResolver: PlaybackSourceResolver(
          database,
          PrivateFeedStore(),
          harness.network,
        ),
      );
      addTearDown(reopened.disposeHandler);
      await reopened.restoreLastPlayback();
      expect(reopened.mediaItem.value?.id, episode.id);
      expect(reopened.playbackState.value.playing, isFalse);
      expect(reopened.playbackState.value.updatePosition, savedPosition);

      await native.emit(
        position: const Duration(minutes: 2),
        processingState: ProcessingState.completed,
      );
      final finished = await database
          .watchPlaybackProgressForEpisode(episode.id)
          .firstWhere((row) => row?.completed == true)
          .timeout(const Duration(seconds: 3));
      expect(finished?.completedAt, isNotNull);
      expect(await database.watchInProgressEpisodes().first, isEmpty);
    },
  );
}
