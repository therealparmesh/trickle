import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/data/repositories/settings_repository.dart';

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('failed speed changes preserve the saved and playing speed', () async {
    final directory = await Directory.systemTemp.createTemp('trickle-speed-');
    addTearDown(() => directory.delete(recursive: true));
    final applyingSpeed = Completer<void>();
    final releaseSpeed = Completer<void>();
    final native = MockNativeAudio(
      directory.path,
      onSpeed: (speed) async {
        if (speed == 1.75) throw PlatformException(code: 'rejected');
        if (speed == 1.5 && !applyingSpeed.isCompleted) {
          applyingSpeed.complete();
          await releaseSpeed.future;
        }
      },
    );
    final cache = CacheManager(
      Config('test-speed', repo: NonStoringObjectProvider()),
    );
    addTearDown(cache.dispose);
    final harness = createPlaybackHarness(
      adapter: MockMediaAdapter(),
      artworkCache: cache,
    );
    addTearDown(() => disposePlaybackHarness(harness));
    final handler = harness.handler;
    final db = harness.database;
    final settings = SettingsRepository(db);
    final (_, next, _) = await seedPlaybackQueue(harness);
    await handler.setSpeed(1.25);
    await handler.play();
    expect(native.speeds.last, 1.25);

    await db.customStatement(
      'CREATE TRIGGER reject_speed BEFORE INSERT ON app_settings '
      "WHEN NEW.key = 'playback_speed' BEGIN SELECT RAISE(ABORT, 'Save failed'); END",
    );
    await expectLater(handler.setSpeed(2), throwsA(isA<Exception>()));
    expect(native.speeds.last, 1.25);
    await db.customStatement('DROP TRIGGER reject_speed');
    await handler.playQueuedEpisode(next.id);
    expect(native.speeds.last, 1.25);
    expect(handler.playbackState.value.speed, 1.25);

    await expectLater(
      handler.setSpeed(1.75),
      throwsA(isA<PlatformException>()),
    );
    expect(await settings.speed(), 125);
    expect(native.speeds.last, 1.25);
    expect(handler.playbackState.value.speed, 1.25);

    final changes = Future.wait([handler.setSpeed(1.5), handler.setSpeed(2)]);
    try {
      await applyingSpeed.future.timeout(const Duration(seconds: 3));
      expect(await settings.speed(), 125);
    } finally {
      releaseSpeed.complete();
      await changes;
    }
    expect(await settings.speed(), 200);
    expect(native.speeds.last, 2);
    expect(handler.playbackState.value.speed, 2);

    await handler.restoreLibrary(() => settings.setSpeed(150));
    expect(handler.playbackState.value.speed, 1.5);
    expect(handler.playbackState.value.playing, isFalse);
    await handler.play();
    expect(native.speeds.last, 1.5);
  });
}
