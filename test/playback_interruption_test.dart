import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_service/audio_service.dart';
import 'package:trickle/core/constants.dart';

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('podcasts resume only after a resumable system interruption', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final pauseTimeouts = <Timer>[];
    final pauseDeadline = Completer<void>();
    await runZoned(
      () => _exerciseInterruptions(pauseTimeouts, pauseDeadline),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration != AppConstants.androidInterruptionTimeout) {
            return parent.createTimer(zone, duration, callback);
          }
          final timer = parent.createTimer(zone, duration, callback);
          pauseTimeouts.add(timer);
          unawaited(
            pauseDeadline.future.then((_) {
              if (!timer.isActive) return;
              timer.cancel();
              zone.run(callback);
            }),
          );
          return timer;
        },
      ),
    );
  });
}

Future<void> _exerciseInterruptions(
  List<Timer> pauseTimeouts,
  Completer<void> pauseDeadline,
) async {
  final directory = await Directory.systemTemp.createTemp('trickle-focus-');
  addTearDown(() => directory.delete(recursive: true));
  final native = MockNativeAudio(directory.path);
  final cache = CacheManager(
    Config('test-focus', repo: NonStoringObjectProvider()),
  );
  addTearDown(cache.dispose);
  final events = StreamController<AudioInterruptionEvent>(sync: true);
  addTearDown(events.close);
  final resolving = Completer<void>();
  final finishResolving = Completer<void>();
  final harness = createPlaybackHarness(
    adapter: MockMediaAdapter(),
    artworkCache: cache,
    interruptionEvents: events.stream,
    addressValidator: (url) async {
      if (url.path == '/selected.mp3' && !resolving.isCompleted) {
        resolving.complete();
        await finishResolving.future;
      }
    },
  );
  addTearDown(() => disposePlaybackHarness(harness));
  final handler = harness.handler;
  final (_, selected, _) = await seedPlaybackQueue(harness);

  Future<void> event(bool begin, AudioInterruptionType type) async {
    events.add(AudioInterruptionEvent(begin, type));
    await Future<void>.delayed(Duration.zero);
  }

  await handler.play();
  await event(true, AudioInterruptionType.unknown);
  await event(true, AudioInterruptionType.unknown);
  expect(handler.playbackState.value.playing, isFalse);
  await event(false, AudioInterruptionType.pause);
  expect(handler.playbackState.value.playing, isTrue);
  expect(native.plays, 2);
  expect(native.loaded, ['/current.mp3']);

  await event(true, AudioInterruptionType.unknown);
  await event(false, AudioInterruptionType.unknown);
  expect(handler.playbackState.value.playing, isFalse);
  expect(native.plays, 2);

  await handler.play();
  await event(true, AudioInterruptionType.pause);
  events.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
  await handler.pause();
  await Future<void>.delayed(Duration.zero);
  expect(handler.playbackState.value.playing, isFalse);
  expect(native.plays, 3);

  final switching = handler.playQueuedEpisode(selected.id);
  await resolving.future;
  await event(true, AudioInterruptionType.unknown);
  finishResolving.complete();
  await switching;
  expect(handler.playbackState.value.playing, isFalse);
  await event(false, AudioInterruptionType.pause);
  expect(handler.playbackState.value.playing, isTrue);
  expect(handler.mediaItem.value?.id, selected.id);
  expect(native.plays, 4);

  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  await event(true, AudioInterruptionType.pause);
  expect(
    handler.playbackState.value.processingState,
    AudioProcessingState.buffering,
  );
  expect(handler.playbackState.value.playing, isTrue);
  expect(pauseTimeouts.last.isActive, isTrue);
  await event(false, AudioInterruptionType.pause);
  expect(native.plays, 5);
  expect(pauseTimeouts.last.isActive, isFalse);

  await event(true, AudioInterruptionType.pause);
  await event(true, AudioInterruptionType.unknown);
  expect(handler.playbackState.value.playing, isFalse);
  expect(pauseTimeouts.last.isActive, isFalse);

  await handler.play();
  await event(true, AudioInterruptionType.pause);
  await handler.pause();
  await event(false, AudioInterruptionType.pause);
  expect(handler.playbackState.value.playing, isFalse);
  expect(native.plays, 6);

  await handler.play();
  await event(true, AudioInterruptionType.pause);
  final paused = handler.playbackState.firstWhere((state) => !state.playing);
  pauseDeadline.complete();
  await paused;
  await event(false, AudioInterruptionType.pause);
  expect(handler.mediaItem.value?.id, selected.id);
  expect(native.plays, 7);
}
