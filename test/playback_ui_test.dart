import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/playback_source_resolver.dart';
import 'package:trickle/data/repositories/settings_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/features/player/trickle_audio_handler.dart';
import 'package:trickle/presentation/pages/player_page.dart';

void main() {
  group('playback presentation', () {
    test('maps every engine state to one presentation phase', () {
      expect(playbackUiPhaseFor(null), PlaybackUiPhase.loading);
      expect(
        playbackUiPhaseFor(
          PlaybackState(processingState: AudioProcessingState.loading),
        ),
        PlaybackUiPhase.loading,
      );
      expect(
        playbackUiPhaseFor(
          PlaybackState(
            processingState: AudioProcessingState.buffering,
            playing: true,
          ),
        ),
        PlaybackUiPhase.buffering,
      );
      expect(
        playbackUiPhaseFor(
          PlaybackState(
            processingState: AudioProcessingState.error,
            playing: false,
          ),
        ),
        PlaybackUiPhase.error,
      );
      expect(
        playbackUiPhaseFor(
          PlaybackState(
            processingState: AudioProcessingState.ready,
            playing: true,
          ),
        ),
        PlaybackUiPhase.playing,
      );
      expect(
        playbackUiPhaseFor(
          PlaybackState(processingState: AudioProcessingState.ready),
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

    test('never presents a raw engine error or private URL', () {
      const raw =
          'https://user:secret@example.test/audio.mp3 failed with errno 13';
      final state = PlaybackState(
        processingState: AudioProcessingState.error,
        errorCode: 13,
        errorMessage: raw,
      );
      final phase = playbackUiPhaseFor(state);

      expect(phase, PlaybackUiPhase.error);
      expect(phase.semanticStatus, isNot(contains('secret')));
      expect(phase.semanticStatus, isNot(contains('http')));
      expect(TrickleAudioHandler.playbackErrorMessage, isNot(contains('http')));
      expect(
        TrickleAudioHandler.playbackErrorMessage,
        isNot(contains('errno')),
      );
    });
  });

  test('stale scrub cannot seek the newly selected episode', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final network = SafeNetworkClient.forTesting(
      Dio(),
      addressValidator: (_) async {},
    );
    final handler = TrickleAudioHandler(
      database: database,
      settings: SettingsRepository(database),
      sourceResolver: PlaybackSourceResolver(
        database,
        PrivateFeedStore(),
        network,
      ),
    );
    const current = MediaItem(id: 'new-episode', title: 'New episode');
    handler.mediaItem.add(current);

    await handler.seekEpisode('old-episode', const Duration(minutes: 42));

    expect(handler.mediaItem.value, current);
    expect(handler.playbackState.value.updatePosition, Duration.zero);

    handler.mediaItem.add(null);
    await handler.disposeHandler();
    network.close();
    await database.close();
  });

  test('expired sleep timer clears when no player was initialized', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final network = SafeNetworkClient.forTesting(
      Dio(),
      addressValidator: (_) async {},
    );
    final handler = TrickleAudioHandler(
      database: database,
      settings: SettingsRepository(database),
      sourceResolver: PlaybackSourceResolver(
        database,
        PrivateFeedStore(),
        network,
      ),
    );

    await handler.setSleepTimer(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      (await handler.sleepTimerStatusStream.first).mode,
      SleepTimerMode.off,
    );

    await handler.disposeHandler();
    network.close();
    await database.close();
  });
}
