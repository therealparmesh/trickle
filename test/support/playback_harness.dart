import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/playback_source_resolver.dart';
import 'package:trickle/data/repositories/settings_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/features/player/trickle_audio_handler.dart';

typedef PlaybackHarness = ({
  AppDatabase database,
  SafeNetworkClient network,
  TrickleAudioHandler handler,
});

PlaybackHarness createPlaybackHarness({
  HttpClientAdapter? adapter,
  BaseCacheManager? artworkCache,
  Stream<AudioInterruptionEvent>? interruptionEvents,
  Future<void> Function(Uri)? addressValidator,
}) {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final dio = Dio();
  if (adapter != null) dio.httpClientAdapter = adapter;
  final network = SafeNetworkClient.forTesting(
    dio,
    addressValidator: addressValidator ?? (_) async {},
  );
  return (
    database: database,
    network: network,
    handler: TrickleAudioHandler(
      database: database,
      settings: SettingsRepository(database),
      artworkCache: artworkCache,
      interruptionEvents: interruptionEvents,
      sourceResolver: PlaybackSourceResolver(
        database,
        PrivateFeedStore(),
        network,
      ),
    ),
  );
}

Future<(MediaItem, MediaItem, MediaItem)> seedPlaybackQueue(
  PlaybackHarness harness,
) async {
  final database = harness.database;
  final now = DateTime.utc(2026, 9, 21);
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
  const current = MediaItem(id: 'current', title: 'Current');
  const selected = MediaItem(id: 'selected', title: 'Selected');
  const other = MediaItem(id: 'other', title: 'Other');
  for (final item in [current, selected, other]) {
    await database
        .into(database.episodes)
        .insert(
          EpisodesCompanion.insert(
            id: item.id,
            feedId: 'feed',
            title: item.title,
            enclosureUrl: 'https://example.test/${item.id}.mp3',
            discoveredAt: now,
          ),
        );
  }
  await harness.handler.updateQueue([current, selected, other]);
  harness.handler.mediaItem.add(current);
  return (current, selected, other);
}

Future<void> disposePlaybackHarness(PlaybackHarness harness) async {
  await harness.handler.disposeHandler();
  harness.network.close();
  await harness.database.close();
}

final class MockNativeAudio {
  MockNativeAudio(
    String cacheDirectory, {
    Future<void> Function(int)? onPlay,
    Future<void> Function(String)? onLoad,
    Future<void> Function(double)? onVolume,
    Future<void> Function(double)? onSpeed,
  }) {
    _mock('plugins.flutter.io/path_provider', (_) async => cacheDirectory);
    for (final channel in const [
      'com.ryanheise.audio_service.client.methods',
      'com.ryanheise.audio_service.handler.methods',
      'com.ryanheise.audio_session',
    ]) {
      _mock(channel, (_) async => null);
    }
    _mock('com.ryanheise.just_audio.methods', (call) async {
      if (call.method == 'init') {
        final id = call.arguments['id'];
        final eventChannel = _eventChannel =
            'com.ryanheise.just_audio.events.$id';
        _mock(eventChannel, (_) async => null);
        _mock('com.ryanheise.just_audio.data.$id', (_) async => null);
        _mock('com.ryanheise.just_audio.methods.$id', (call) async {
          if (call.method == 'play') {
            plays++;
            if (onPlay != null) await onPlay(plays);
          }
          if (call.method == 'pause') pauses++;
          if (call.method == 'setSpeed') {
            final speed = call.arguments['speed'] as double;
            await onSpeed?.call(speed);
            speeds.add(speed);
          }
          if (call.method == 'setVolume') {
            final volume = call.arguments['volume'] as double;
            volumes.add(volume);
            await onVolume?.call(volume);
          }
          if (call.method == 'load') {
            final source = call.arguments['audioSource']['children'][0];
            final path = Uri.parse(source['uri'] as String).path;
            loaded.add(path);
            if (onLoad != null) await onLoad(path);
            await _emit(eventChannel);
            return {'duration': _duration.inMicroseconds};
          }
          if (call.method == 'seek') {
            final position = Duration(
              microseconds: call.arguments['position'] as int,
            );
            seeks.add(position);
            await _emit(eventChannel, position: position);
          }
          return <String, Object?>{};
        });
      }
      return <String, Object?>{};
    });
  }

  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  static const _duration = Duration(minutes: 2);
  late String _eventChannel;
  final loaded = <String>[];
  final seeks = <Duration>[];
  final volumes = <double>[];
  final speeds = <double>[];
  int plays = 0;
  int pauses = 0;

  void _mock(String channel, Future<Object?> Function(MethodCall) handler) {
    final methodChannel = MethodChannel(channel);
    _messenger.setMockMethodCallHandler(methodChannel, handler);
    addTearDown(() => _messenger.setMockMethodCallHandler(methodChannel, null));
  }

  Future<void> emit({
    Duration position = Duration.zero,
    ProcessingState processingState = ProcessingState.ready,
  }) => _emit(
    _eventChannel,
    position: position,
    processingState: processingState,
  );

  Future<void> _emit(
    String channel, {
    Duration position = Duration.zero,
    ProcessingState processingState = ProcessingState.ready,
  }) async {
    await _messenger.handlePlatformMessage(
      channel,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'processingState': processingState.index,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
        'updatePosition': position.inMicroseconds,
        'bufferedPosition': _duration.inMicroseconds,
        'duration': _duration.inMicroseconds,
        'currentIndex': 0,
      }),
      null,
    );
    await Future<void>.delayed(Duration.zero);
  }
}

final class MockMediaAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString('', HttpStatus.partialContent);
  }

  @override
  void close({bool force = false}) {}
}
