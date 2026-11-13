import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a rejected native Play can be retried without losing position',
    () async {
      final directory = await Directory.systemTemp.createTemp('trickle-start-');
      addTearDown(() => directory.delete(recursive: true));
      final firstPlay = Completer<void>();
      final secondPlay = Completer<void>();
      final native = MockNativeAudio(
        directory.path,
        onPlay: (attempt) async {
          if (attempt == 1) await firstPlay.future;
          if (attempt == 2) await secondPlay.future;
        },
      );
      final cache = CacheManager(
        Config('test-start', repo: NonStoringObjectProvider()),
      );
      addTearDown(cache.dispose);
      final harness = createPlaybackHarness(
        adapter: MockMediaAdapter(),
        artworkCache: cache,
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final handler = harness.handler;
      final (current, _, _) = await seedPlaybackQueue(harness);

      await handler.seek(const Duration(seconds: 45));
      await handler.play();
      expect(native.plays, 1);
      await handler.pause();
      await handler.play();
      expect(native.plays, 2);
      await handler.play();
      expect(native.plays, 2);

      firstPlay.completeError(PlatformException(code: 'old-failure'));
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isTrue);
      expect(native.pauses, 1);

      secondPlay.completeError(PlatformException(code: 'play-failed'));
      await Future<void>.delayed(Duration.zero);
      final failed = handler.playbackState.value;
      expect(failed.processingState, AudioProcessingState.error);
      expect(failed.playing, isFalse);
      expect(handler.mediaItem.value?.id, current.id);
      expect(native.pauses, 2);

      await handler.play();
      expect(native.plays, 3);
      expect(handler.playbackState.value.playing, isTrue);
      expect(native.seeks.last.inSeconds, 45);
    },
  );
}
