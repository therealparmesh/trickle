import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:trickle/core/constants.dart';

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a stalled native load does not block pause, stop, or another episode',
    () async {
      final directory = await Directory.systemTemp.createTemp('trickle-load-');
      addTearDown(() => directory.delete(recursive: true));
      var stalled = Completer<void>();
      var finishStalledLoad = Completer<void>();
      var stalledPath = '/current.mp3';
      final native = MockNativeAudio(
        directory.path,
        onLoad: (path) async {
          if (path == stalledPath) {
            stalled.complete();
            await finishStalledLoad.future;
          }
        },
      );
      final cache = CacheManager(
        Config('test-load', repo: NonStoringObjectProvider()),
      );
      addTearDown(cache.dispose);
      final harness = createPlaybackHarness(
        adapter: MockMediaAdapter(),
        artworkCache: cache,
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final handler = harness.handler;
      final (_, selected, other) = await seedPlaybackQueue(harness);
      const testDeadline = Duration(seconds: 3);

      final original = handler.play();
      await stalled.future;
      try {
        await handler.pause().timeout(testDeadline);
        await handler.stop().timeout(testDeadline);
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.idle,
        );

        await original.timeout(testDeadline);
        await handler.playQueuedEpisode(selected.id).timeout(testDeadline);
        expect(handler.mediaItem.value?.id, selected.id);
        expect(handler.playbackState.value.playing, isTrue);
      } finally {
        finishStalledLoad.complete();
        await original;
      }
      expect(native.loaded, ['/current.mp3', '/selected.mp3']);
      expect(native.plays, 1);
      expect(handler.mediaItem.value?.id, selected.id);

      stalledPath = '/other.mp3';
      stalled = Completer<void>();
      finishStalledLoad = Completer<void>();
      final superseded = handler.playQueuedEpisode(other.id);
      await stalled.future;
      try {
        await handler.playQueuedEpisode(selected.id).timeout(testDeadline);
        await superseded.timeout(testDeadline);
        expect(handler.mediaItem.value?.id, selected.id);
        expect(native.plays, 2);
      } finally {
        finishStalledLoad.complete();
        await superseded;
      }

      stalled = Completer<void>();
      finishStalledLoad = Completer<void>();
      try {
        await expectLater(
          runZoned(
            () => handler.playQueuedEpisode(other.id),
            zoneSpecification: ZoneSpecification(
              createTimer: (_, parent, zone, duration, callback) =>
                  parent.createTimer(
                    zone,
                    duration == AppConstants.audioSourceLoadTimeout
                        ? const Duration(milliseconds: 50)
                        : duration,
                    callback,
                  ),
            ),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.error,
        );
        expect(handler.mediaItem.value?.id, other.id);
        stalledPath = '';
        await handler.play().timeout(testDeadline);
        expect(handler.playbackState.value.playing, isTrue);
      } finally {
        finishStalledLoad.complete();
      }

      final loadsBeforeRecovery = native.loaded.length;
      const position = Duration(seconds: 43);
      await native.emit(position: position);
      await native.emit(processingState: ProcessingState.idle);
      await handler.recoverPlaybackIfNeeded();
      expect(native.loaded.length, loadsBeforeRecovery + 1);

      expect(native.loaded.last, '/other.mp3');
      expect(native.seeks.last.inSeconds, position.inSeconds);
      expect(handler.playbackState.value.playing, isTrue);

      await native.emit(processingState: ProcessingState.idle);
      await handler.recoverPlaybackIfNeeded();
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
      expect(native.loaded.length, loadsBeforeRecovery + 1);

      await handler.play();
      const manuallyResumedPosition = Duration(seconds: 57);
      await native.emit(position: manuallyResumedPosition);
      await native.emit(processingState: ProcessingState.idle);
      await handler.pause();
      await handler.recoverPlaybackIfNeeded();
      expect(native.loaded.length, loadsBeforeRecovery + 2);
      expect(handler.playbackState.value.playing, isFalse);

      await handler.play();
      expect(native.loaded.length, loadsBeforeRecovery + 3);
      expect(native.seeks.last.inSeconds, manuallyResumedPosition.inSeconds);
      expect(handler.playbackState.value.playing, isTrue);
    },
  );
}
