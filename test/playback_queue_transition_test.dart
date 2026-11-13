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
    'completion can be retried and keeps playback active for Up next',
    () async {
      final directory = await Directory.systemTemp.createTemp('trickle-next-');
      addTearDown(() => directory.delete(recursive: true));
      final native = MockNativeAudio(directory.path);
      final cache = CacheManager(
        Config('test-next', repo: NonStoringObjectProvider()),
      );
      addTearDown(cache.dispose);
      final resolving = Completer<void>();
      final finishResolving = Completer<void>();
      final harness = createPlaybackHarness(
        adapter: MockMediaAdapter(),
        artworkCache: cache,
        addressValidator: (url) async {
          if (url.path == '/selected.mp3' && !resolving.isCompleted) {
            resolving.complete();
            await finishResolving.future;
          }
        },
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final handler = harness.handler;
      final (current, selected, _) = await seedPlaybackQueue(harness);
      await handler.play();
      final database = harness.database;
      const checkpoint = Duration(seconds: 45);
      const duration = Duration(minutes: 2);
      await handler.seek(checkpoint);
      await database.customStatement(
        'CREATE TRIGGER reject_completion BEFORE DELETE ON queue_entries '
        "BEGIN SELECT RAISE(ABORT, 'Completion rejected'); END",
      );
      await native.emit(
        position: duration,
        processingState: ProcessingState.completed,
      );
      final error = await handler.playbackState
          .firstWhere(
            (state) => state.processingState == AudioProcessingState.error,
          )
          .timeout(const Duration(seconds: 3));
      expect(error.playing, isFalse);
      expect(handler.mediaItem.value?.id, current.id);
      expect(handler.queue.value.first.id, current.id);
      expect((await database.episodeById(current.id))!.played, isFalse);

      await database.customStatement('DROP TRIGGER reject_completion');
      await handler.play();
      expect(native.seeks.last, checkpoint);
      expect(handler.playbackState.value.playing, isTrue);
      final states = <PlaybackState>[];
      final subscription = handler.playbackState.listen(states.add);
      addTearDown(subscription.cancel);

      await native.emit(
        position: duration,
        processingState: ProcessingState.completed,
      );
      await resolving.future.timeout(const Duration(seconds: 3));
      try {
        expect(handler.mediaItem.value?.id, selected.id);
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.loading,
        );
        expect(handler.playbackState.value.playing, isTrue);
        expect(states.where((state) => !state.playing), isEmpty);
        await handler.pause();
        expect(handler.playbackState.value.playing, isFalse);
      } finally {
        finishResolving.complete();
      }
      await handler.playbackState.firstWhere(
        (state) => state.processingState == AudioProcessingState.ready,
      );
      expect(native.loaded, ['/current.mp3', '/current.mp3', '/selected.mp3']);
      expect(native.plays, 2);
      expect((await database.episodeById(current.id))!.played, isTrue);
      expect(
        handler.queue.value.map((item) => item.id),
        isNot(contains(current.id)),
      );

      await handler.play();
      expect(native.plays, 3);
      expect(handler.playbackState.value.playing, isTrue);
    },
  );
}
