import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/features/player/trickle_audio_handler.dart';

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sleep timer respects loading, cancellation, and audio ownership',
    () async {
      const deadline = Duration(seconds: 3);
      final directory = await Directory.systemTemp.createTemp('trickle-sleep-');
      addTearDown(() => directory.delete(recursive: true));
      final muted = Completer<void>();
      final releaseMute = Completer<void>();
      final native = MockNativeAudio(
        directory.path,
        onVolume: (volume) async {
          if (volume != 0 || muted.isCompleted) return;
          muted.complete();
          await releaseMute.future;
        },
      );
      final cache = CacheManager(
        Config('test-sleep', repo: NonStoringObjectProvider()),
      );
      addTearDown(cache.dispose);
      final events = StreamController<AudioInterruptionEvent>(sync: true);
      addTearDown(events.close);
      final resolving = Completer<void>();
      final releaseLoad = Completer<void>();
      final harness = createPlaybackHarness(
        adapter: MockMediaAdapter(),
        artworkCache: cache,
        interruptionEvents: events.stream,
        addressValidator: (_) async {
          if (resolving.isCompleted) return;
          resolving.complete();
          await releaseLoad.future;
        },
      );
      addTearDown(() => disposePlaybackHarness(harness));
      final handler = harness.handler;
      await seedPlaybackQueue(harness);
      final opening = handler.play();
      try {
        await resolving.future.timeout(deadline);
        // Expiring while the first source is still opening must cancel its
        // pending autoplay even though no native player exists yet.
        await handler.setSleepTimer(Duration.zero);
        await handler.sleepTimerStatusStream
            .firstWhere((status) => status.mode == SleepTimerMode.off)
            .timeout(deadline);
      } finally {
        releaseLoad.complete();
        await opening.timeout(deadline);
      }
      expect(native.plays, 0);
      await handler.play();

      events.add(AudioInterruptionEvent(true, AudioInterruptionType.duck));
      await pumpEventQueue();
      final duckedVolume = native.volumes.last;
      expect(duckedVolume, lessThan(1));
      try {
        await runZoned(
          () => handler.setSleepTimer(AppConstants.sleepFade),
          zoneSpecification: ZoneSpecification(
            createTimer: (_, parent, zone, duration, callback) =>
                parent.createTimer(
                  zone,
                  duration == AppConstants.sleepFadeStepInterval
                      ? Duration.zero
                      : duration,
                  callback,
                ),
          ),
        );
        await muted.future.timeout(deadline);
        final cancellation = handler.setSleepTimer(null);
        releaseMute.complete();
        await cancellation.timeout(deadline);
      } finally {
        if (!releaseMute.isCompleted) releaseMute.complete();
      }

      await pumpEventQueue();
      expect(handler.playbackState.value.playing, isTrue);
      expect(native.volumes.last, duckedVolume);
      expect(
        (await handler.sleepTimerStatusStream.first).mode,
        SleepTimerMode.off,
      );

      events.add(AudioInterruptionEvent(false, AudioInterruptionType.duck));
      await pumpEventQueue();
      expect(native.volumes.last, 1);
      expect(handler.playbackState.value.playing, isTrue);

      // A timer expiring during video setup must not send a separate podcast
      // pause; the video handoff owns that native command.
      final video = handler.beginWebVideoPlayback();
      final pausesBeforeVideo = native.pauses;
      await handler.setSleepTimer(Duration.zero);
      await handler.sleepTimerStatusStream
          .firstWhere((status) => status.mode == SleepTimerMode.off)
          .timeout(deadline);
      expect(native.pauses, pausesBeforeVideo);
      expect(await handler.prepareWebVideoPlayback(video), isTrue);
      expect(native.pauses, pausesBeforeVideo + 1);
    },
  );
}
