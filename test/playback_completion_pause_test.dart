import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pausing a finishing episode does not replay it or start Up next',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'trickle-finish-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final native = MockNativeAudio(directory.path);
      final cache = CacheManager(
        Config('test-finish', repo: NonStoringObjectProvider()),
      );
      addTearDown(cache.dispose);
      final harness = createPlaybackHarness(
        adapter: MockMediaAdapter(),
        artworkCache: cache,
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final handler = harness.handler;
      final database = harness.database;
      final (current, selected, other) = await seedPlaybackQueue(harness);
      await handler.play();

      final started = Completer<void>();
      final release = Completer<void>();
      final transaction = database.transaction(() async {
        started.complete();
        await release.future;
      });
      await started.future;
      const duration = Duration(minutes: 2);
      const deadline = Duration(seconds: 3);
      late final Future<void> canceledResume;
      try {
        await native.emit(
          position: duration,
          processingState: ProcessingState.completed,
        );
        await handler.pause().timeout(deadline);
        expect(handler.playbackState.value.playing, isFalse);
        canceledResume = handler.play();
        await handler.pause().timeout(deadline);
      } finally {
        release.complete();
        await transaction;
      }

      await canceledResume.timeout(deadline);
      await handler.mediaItem
          .firstWhere((item) => item == null)
          .timeout(deadline);
      expect(native.loaded, ['/current.mp3']);
      expect((await database.episodeById(current.id))!.played, isTrue);
      expect(handler.queue.value.map((item) => item.id), [
        selected.id,
        other.id,
      ]);

      await handler.play();
      expect(native.loaded, ['/current.mp3', '/selected.mp3']);
      expect(handler.playbackState.value.playing, isTrue);

      // Native completion can also arrive just after the user pauses.
      await handler.pause();
      await native.emit(
        position: duration,
        processingState: ProcessingState.completed,
      );
      await handler.mediaItem
          .firstWhere((item) => item == null)
          .timeout(deadline);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.completed,
      );
      expect(handler.playbackState.value.playing, isFalse);
      expect(native.loaded, ['/current.mp3', '/selected.mp3']);
      expect(handler.queue.value.single.id, other.id);

      // Repeat must not consume a queued episode; an end-of-episode timer
      // still wins over Repeat.
      await handler.play();
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      await native.emit(
        position: duration,
        processingState: ProcessingState.completed,
      );
      await database
          .watchPlaybackProgressForEpisode(other.id)
          .firstWhere((progress) => progress?.positionMs == 0)
          .timeout(
            deadline,
            onTimeout: () =>
                throw StateError('Repeat did not checkpoint its seek'),
          );
      expect(native.seeks.last, Duration.zero);
      expect(handler.mediaItem.value?.id, other.id);
      expect(handler.queue.value.single.id, other.id);
      expect(handler.playbackState.value.playing, isTrue);
      expect((await database.episodeById(other.id))!.played, isFalse);
      await handler.setSleepTimer(null, endOfEpisode: true);
      await native.emit(
        position: duration,
        processingState: ProcessingState.completed,
      );
      await handler.mediaItem
          .firstWhere((item) => item == null)
          .timeout(
            deadline,
            onTimeout: () =>
                throw StateError('End-of-episode timer did not stop playback'),
          );
      expect(handler.queue.value, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );
}
