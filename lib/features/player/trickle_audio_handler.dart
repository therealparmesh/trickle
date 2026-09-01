import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:drift/drift.dart';
import 'package:just_audio/just_audio.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/playback_rules.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/playback_source_resolver.dart';
import '../../data/repositories/settings_repository.dart';

enum SleepTimerMode { off, timed, endOfEpisode }

final class SleepTimerStatus {
  const SleepTimerStatus._(this.mode, this.endsAt);

  const SleepTimerStatus.off() : this._(SleepTimerMode.off, null);

  const SleepTimerStatus.endOfEpisode()
    : this._(SleepTimerMode.endOfEpisode, null);

  SleepTimerStatus.timed(DateTime endsAt)
    : this._(SleepTimerMode.timed, endsAt);

  final SleepTimerMode mode;
  final DateTime? endsAt;

  bool get isActive => mode != SleepTimerMode.off;
}

final class TrickleAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  static const playbackErrorMessage = 'This episode couldn’t be played.';
  static const _podcastAudioSessionConfiguration =
      AudioSessionConfiguration.speech();
  static const _videoAudioSessionConfiguration = AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playback,
    avAudioSessionMode: AVAudioSessionMode.moviePlayback,
    androidAudioAttributes: AndroidAudioAttributes(
      contentType: AndroidAudioContentType.movie,
      usage: AndroidAudioUsage.media,
    ),
    androidWillPauseWhenDucked: true,
  );

  TrickleAudioHandler({
    required AppDatabase database,
    required SettingsRepository settings,
    required PlaybackSourceResolver sourceResolver,
  }) : _database = database,
       _settings = settings,
       _sourceResolver = sourceResolver;

  final AppDatabase _database;
  final SettingsRepository _settings;
  final PlaybackSourceResolver _sourceResolver;
  AudioPlayer? _player;
  final Uuid _uuid = const Uuid();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final StreamController<Duration> _positionEvents =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<Duration> _durationEvents =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<SleepTimerStatus> _sleepStatusEvents =
      StreamController<SleepTimerStatus>.broadcast(sync: true);
  final StreamController<int> _mediaPlaybackIntentEvents =
      StreamController<int>.broadcast(sync: true);

  AudioSession? _session;
  Future<void>? _initialization;
  bool _audioServiceInitialized = false;
  Timer? _checkpointTimer;
  Timer? _playbackRecoveryTimer;
  Timer? _sleepTimer;
  Timer? _sleepStatusTicker;
  bool _sleepAtEnd = false;
  SleepTimerStatus _sleepStatus = const SleepTimerStatus.off();
  int _sleepGeneration = 0;
  int _interruptionResumeGeneration = 0;
  int? _pendingInterruptionResumeGeneration;
  Future<void> _interruptionPause = Future<void>.value();
  bool _duckedForInterruption = false;
  final Set<String> _completionsInFlight = {};
  Future<void> _completionTail = Future<void>.value();
  bool _loadingMedia = false;
  bool _changingPlayerSource = false;
  bool _repeatOne = false;
  int _speedPercent = AppConstants.defaultSpeed;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  AudioProcessingState _processingState = AudioProcessingState.idle;
  int _currentOutroSkipMs = 0;
  bool _disposed = false;
  Future<void> _playerOperationTail = Future<void>.value();
  Future<void> _queueOperationTail = Future<void>.value();
  Future<void> _progressOperationTail = Future<void>.value();
  Future<void> _sessionOperationTail = Future<void>.value();
  ({int generation, Future<void> future})? _playbackRecovery;
  int _queueRevision = 0;
  Map<String, int> _queueIndexes = const {};
  int _structuralQueueRevision = 0;
  int _persistedStructuralQueueRevision = 0;
  int _episodeSelectionGeneration = 0;
  String? _pendingEpisodeSelectionId;
  int _loadGeneration = 0;
  int? _pendingLoadGeneration;
  String? _pendingLoadEpisodeId;
  int? _playIntentGeneration;
  bool _playRequested = false;
  bool _playbackRecoveryAvailable = false;
  bool _currentItemStarted = false;
  int _mediaIntentRevision = 0;
  int _transportRevision = 0;
  int? _webVideoIntentRevision;

  Stream<Duration> get positionStream async* {
    yield _position;
    yield* _positionEvents.stream;
  }

  Stream<Duration> get durationStream async* {
    yield _effectiveDuration;
    yield* _durationEvents.stream;
  }

  Duration get _effectiveDuration => effectivePlaybackDuration(
    nativeDuration: _duration,
    fallbackDuration: mediaItem.value?.duration,
  );

  Stream<SleepTimerStatus> get sleepTimerStatusStream async* {
    yield _sleepStatus;
    yield* _sleepStatusEvents.stream;
  }

  Stream<int> get mediaPlaybackIntentStream =>
      _mediaPlaybackIntentEvents.stream;

  Future<void> initialize() async {
    final active = _initialization;
    if (active != null) return active;
    if (_player != null) return;
    final future = _initializePlayer();
    _initialization = future;
    try {
      await future;
    } on Object {
      if (_player == null) _initialization = null;
      rethrow;
    }
  }

  Future<void> _initializePlayer() async {
    if (_disposed) throw StateError('Audio handler has been disposed.');
    if (!_audioServiceInitialized) {
      await AudioService.init(
        builder: () => this,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.parmscript.trickle.playback',
          androidNotificationChannelName: 'Playback',
          androidNotificationIcon: 'drawable/ic_stat_trickle',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          notificationColor: AppConstants.cyan,
        ),
      );
      _audioServiceInitialized = true;
    }
    _throwIfDisposed();
    final player = AudioPlayer(
      handleInterruptions: false,
      handleAudioSessionActivation: false,
      useProxyForRequestHeaders: false,
    );
    try {
      _throwIfDisposed();
      final session = await AudioSession.instance;
      _throwIfDisposed();
      await session.configure(_podcastAudioSessionConfiguration);
      _throwIfDisposed();
      _speedPercent = await _settings.speed();
      _throwIfDisposed();

      _player = player;
      _session = session;
      _subscriptions.addAll([
        player.playingStream.listen((playing) {
          if (playing && !_loadingMedia && mediaItem.value != null) {
            _currentItemStarted = true;
          }
          _broadcastState(playing: playing);
          if (playing) {
            _playbackRecoveryTimer?.cancel();
            _startCheckpointing();
          } else {
            _checkpointTimer?.cancel();
            _schedulePlaybackRecovery();
          }
        }),
        player.positionStream.listen((position) {
          _position = position;
          _positionEvents.add(position);
          if (shouldHandleOutroSkip(
            loadingMedia: _loadingMedia,
            playbackStarted: _currentItemStarted,
            position: position,
            duration: _effectiveDuration,
            outro: Duration(milliseconds: _currentOutroSkipMs),
          )) {
            _runDetached(_handleCompletion());
          }
        }),
        player.durationStream.listen((duration) {
          if (duration == null) return;
          _duration = duration;
          _durationEvents.add(_effectiveDuration);
          final current = mediaItem.value;
          if (current != null &&
              current.duration != duration &&
              duration > Duration.zero) {
            final updated = current.copyWith(duration: duration);
            mediaItem.add(updated);
            final items = [...queue.value];
            final index = items.indexWhere((item) => item.id == updated.id);
            if (index >= 0) {
              items[index] = updated;
              _publishQueue(items, structural: false);
            }
          }
          _broadcastState();
        }),
        player.bufferedPositionStream.listen((buffered) {
          _buffered = buffered;
          _broadcastState();
        }),
        player.processingStateStream.listen((state) {
          if (_processingState == AudioProcessingState.error) return;
          _processingState = switch (state) {
            ProcessingState.idle =>
              mediaItem.value == null
                  ? AudioProcessingState.idle
                  : _processingState,
            ProcessingState.loading => AudioProcessingState.loading,
            ProcessingState.buffering => AudioProcessingState.buffering,
            ProcessingState.ready => AudioProcessingState.ready,
            ProcessingState.completed => AudioProcessingState.completed,
          };
          if (shouldHandlePlayerCompletion(
            completed: state == ProcessingState.completed,
            loadingMedia: _loadingMedia,
            hasMedia: mediaItem.value != null,
            playbackStarted: _currentItemStarted,
            position: _position,
            duration: _effectiveDuration,
          )) {
            _runDetached(_handleCompletion());
          }
          _broadcastState();
        }),
        player.errorStream.listen((_) {
          // setUrl/setFilePath reports load failures through its returned
          // future. Ignore the matching stream event so an outgoing source
          // cannot put a newer in-flight selection into an error state.
          if (!_loadingMedia &&
              !_changingPlayerSource &&
              _webVideoIntentRevision == null) {
            _setPlaybackError();
          }
        }),
        session.interruptionEventStream.listen((event) {
          if (event.begin) {
            switch (event.type) {
              case AudioInterruptionType.duck:
                _duckedForInterruption = true;
                _runDetached(
                  _serializePlayerOperation(() async {
                    if (!_disposed) await player.setVolume(0.3);
                  }),
                );
              case AudioInterruptionType.pause:
                if (shouldResumeAfterInterruption(
                  playing: playbackState.value.playing,
                  playRequested: _playIntentGeneration == _loadGeneration
                      ? _playRequested
                      : null,
                )) {
                  final generation = ++_interruptionResumeGeneration;
                  _pendingInterruptionResumeGeneration = generation;
                  _interruptionPause = _pauseCurrent().catchError(
                    (Object _) {},
                  );
                } else {
                  _cancelPendingInterruptionResume();
                  _interruptionPause = _pauseCurrent().catchError(
                    (Object _) {},
                  );
                }
              case AudioInterruptionType.unknown:
                _cancelPendingInterruptionResume();
                _interruptionPause = _pauseCurrent().catchError((Object _) {});
            }
          } else {
            if (_duckedForInterruption) {
              _duckedForInterruption = false;
              _runDetached(
                _serializePlayerOperation(() async {
                  if (!_disposed) await player.setVolume(1);
                }),
              );
            }
            final resumeGeneration = event.type == AudioInterruptionType.pause
                ? _pendingInterruptionResumeGeneration
                : null;
            _pendingInterruptionResumeGeneration = null;
            if (resumeGeneration != null) {
              _runDetached(_resumeAfterInterruption(resumeGeneration));
            }
          }
        }),
        session.becomingNoisyEventStream.listen((_) {
          _cancelPendingInterruptionResume();
          _runDetached(_pauseCurrent());
        }),
      ]);
    } on Object {
      if (identical(_player, player)) _player = null;
      _session = null;
      await player.dispose();
      rethrow;
    }
  }

  int beginWebVideoPlayback() {
    _cancelPendingInterruptionResume();
    _episodeSelectionGeneration++;
    _pendingEpisodeSelectionId = null;
    _clearLoadPlaybackIntent();
    _disarmPlaybackRecovery();
    _loadGeneration++;
    _transportRevision++;
    final intent = ++_mediaIntentRevision;
    _webVideoIntentRevision = intent;
    if (!_disposed && !_mediaPlaybackIntentEvents.isClosed) {
      _mediaPlaybackIntentEvents.add(intent);
    }
    return intent;
  }

  bool isWebVideoPlaybackCurrent(int intent) =>
      !_disposed &&
      _webVideoIntentRevision == intent &&
      _mediaIntentRevision == intent;

  Future<bool> prepareWebVideoPlayback(int intent) async {
    if (!isWebVideoPlaybackCurrent(intent)) return false;
    await _serializePlayerOperation(() async {
      if (isWebVideoPlaybackCurrent(intent)) await _player?.pause();
    });
    if (!isWebVideoPlaybackCurrent(intent)) return false;
    try {
      await _persistProgress();
    } on Object {
      // Playback ownership must still switch if a checkpoint cannot be saved.
    }
    if (!isWebVideoPlaybackCurrent(intent)) return false;
    try {
      await initialize();
      if (isWebVideoPlaybackCurrent(intent)) {
        await _configureWebVideoSession(intent, activate: true);
      }
    } on Object {
      // Foreground WebView playback can still start without explicit focus.
    }
    return isWebVideoPlaybackCurrent(intent);
  }

  Future<bool> activateWebVideoAudioSession(int intent) async {
    if (!isWebVideoPlaybackCurrent(intent)) return false;
    await initialize();
    return _configureWebVideoSession(intent, activate: true);
  }

  Future<void> suspendWebVideoAudioSession(int intent) async {
    final session = _session;
    if (session == null || !isWebVideoPlaybackCurrent(intent)) return;
    await _queueSessionOperation(() async {
      if (!isWebVideoPlaybackCurrent(intent)) return false;
      return session.setActive(false);
    });
  }

  Future<void> endWebVideoPlayback(int intent) async {
    if (!isWebVideoPlaybackCurrent(intent)) return;
    _webVideoIntentRevision = null;
    final session = _session;
    if (session == null) return;
    await _queueSessionOperation(() async {
      if (_mediaIntentRevision != intent || _webVideoIntentRevision != null) {
        return false;
      }
      await session.configure(_podcastAudioSessionConfiguration);
      final nativePlaybackActive = _player?.playing == true || _playRequested;
      return session.setActive(nativePlaybackActive);
    });
  }

  Future<void> playEpisode(String episodeId) async {
    final intent = _beginAudioPlaybackIntent();
    final generation = ++_episodeSelectionGeneration;
    _pendingEpisodeSelectionId = episodeId;
    try {
      await _persistProgress();
      final item = await _mediaItemForEpisode(episodeId);
      if (item == null ||
          generation != _episodeSelectionGeneration ||
          !_isAudioPlaybackIntentCurrent(intent)) {
        return;
      }
      var items = [...queue.value];
      items.removeWhere((candidate) => candidate.id == episodeId);
      final currentIndex = _currentQueueIndex(items);
      final insertAt = currentIndex < 0
          ? 0
          : math.min(currentIndex, items.length);
      items.insert(insertAt, item);
      _publishQueue(items);
      await _persistQueue();
      if (generation != _episodeSelectionGeneration ||
          !_isAudioPlaybackIntentCurrent(intent)) {
        return;
      }
      await _load(item, autoPlay: true);
    } finally {
      if (generation == _episodeSelectionGeneration) {
        _pendingEpisodeSelectionId = null;
      }
    }
  }

  Future<void> playStandaloneEpisode(String episodeId) async {
    final intent = _beginAudioPlaybackIntent();
    final generation = ++_episodeSelectionGeneration;
    _pendingEpisodeSelectionId = episodeId;
    try {
      await _persistProgress();
      final episode = await _database.episodeById(episodeId);
      if (episode == null ||
          generation != _episodeSelectionGeneration ||
          !_isAudioPlaybackIntentCurrent(intent)) {
        return;
      }
      final feed = await _database.feedById(episode.feedId);
      if (generation != _episodeSelectionGeneration ||
          !_isAudioPlaybackIntentCurrent(intent)) {
        return;
      }
      await _load(_mediaItem(episode, feed, standalone: true), autoPlay: true);
    } finally {
      if (generation == _episodeSelectionGeneration) {
        _pendingEpisodeSelectionId = null;
      }
    }
  }

  Future<void> playNextEpisode(String episodeId) async {
    final item = await _mediaItemForEpisode(episodeId);
    if (item == null) return;
    final items = [...queue.value]
      ..removeWhere((entry) => entry.id == episodeId);
    final currentIndex = _currentQueueIndex(items);
    items.insert(math.min(currentIndex + 1, items.length), item);
    _publishQueue(items);
    await _persistQueue();
  }

  Future<void> addEpisodeToQueue(String episodeId) async {
    await addEpisodesToQueue([episodeId]);
  }

  Future<void> addEpisodesToQueue(Iterable<String> episodeIds) async {
    final requestedIds = episodeIds.toSet();
    if (requestedIds.isEmpty) return;
    final existingIds = queue.value.map((item) => item.id).toSet();
    requestedIds.removeAll(existingIds);
    if (requestedIds.isEmpty) return;

    final itemsById = <String, MediaItem>{};
    final ids = requestedIds.toList(growable: false);
    for (
      var start = 0;
      start < ids.length;
      start += AppDatabase.safeVariableBatchSize
    ) {
      final end = math.min(
        start + AppDatabase.safeVariableBatchSize,
        ids.length,
      );
      final chunk = ids.sublist(start, end);
      final query = _database.select(_database.episodes).join([
        leftOuterJoin(
          _database.feeds,
          _database.feeds.id.equalsExp(_database.episodes.feedId),
        ),
      ])..where(_database.episodes.id.isIn(chunk));
      for (final row in await query.get()) {
        final episode = row.readTable(_database.episodes);
        itemsById[episode.id] = _mediaItem(
          episode,
          row.readTableOrNull(_database.feeds),
        );
      }
    }

    final current = queue.value;
    final currentIds = current.map((item) => item.id).toSet();
    final additions = <MediaItem>[];
    for (final id in ids) {
      final item = itemsById[id];
      if (!currentIds.contains(id) && item != null) additions.add(item);
    }
    if (additions.isEmpty) return;
    _publishQueue([...current, ...additions]);
    await _persistQueue();
  }

  @override
  Future<void> play() async {
    _cancelPendingInterruptionResume();
    final intent = _beginAudioPlaybackIntent();
    if (mediaItem.value == null && queue.value.isEmpty) {
      await reloadQueueFromDatabase();
      if (!_isAudioPlaybackIntentCurrent(intent)) return;
    }
    final generation = _loadGeneration;
    _armPlaybackRecovery();
    _setPlayIntent(generation, requested: true);
    if (_isLoadPending(generation)) return;
    await _playCurrent(
      expectedLoadGeneration: generation,
      expectedTransportRevision: intent.transport,
    );
  }

  Future<void> _playCurrent({
    int? interruptionResumeGeneration,
    required int expectedLoadGeneration,
    required int expectedTransportRevision,
  }) async {
    if (!_canActivatePlayback(
      expectedLoadGeneration,
      expectedTransportRevision,
      interruptionResumeGeneration,
    )) {
      return;
    }
    if (mediaItem.value == null && queue.value.isNotEmpty) {
      await _load(queue.value.first, autoPlay: true);
      return;
    }
    final current = mediaItem.value;
    if (current == null) return;
    if (_processingState == AudioProcessingState.error &&
        interruptionResumeGeneration == null) {
      await _load(current, autoPlay: true);
      return;
    }
    if (_processingState == AudioProcessingState.error) return;
    await initialize();
    if (!_canActivatePlayback(
      expectedLoadGeneration,
      expectedTransportRevision,
      interruptionResumeGeneration,
    )) {
      return;
    }
    var activated = false;
    try {
      activated = await _configurePodcastSession(
        activate: true,
        expectedTransportRevision: expectedTransportRevision,
      );
    } on Object {
      // The bounded recovery below reconfigures the podcast session once.
    }
    if (!activated) {
      await recoverPlaybackIfNeeded();
      return;
    }
    if (!_canActivatePlayback(
      expectedLoadGeneration,
      expectedTransportRevision,
      interruptionResumeGeneration,
    )) {
      return;
    }
    await _serializePlayerOperation(() async {
      if (_canActivatePlayback(
        expectedLoadGeneration,
        expectedTransportRevision,
        interruptionResumeGeneration,
      )) {
        // just_audio's play future completes when playback later pauses or
        // ends, so only starting it belongs in the serialized operation.
        _startPlayer(_player!, expectedLoadGeneration);
      }
    });
  }

  @override
  Future<void> pause() async {
    _cancelPendingInterruptionResume();
    await _pauseCurrent();
  }

  Future<void> _pauseCurrent() async {
    if (_disposed) return;
    _transportRevision++;
    _disarmPlaybackRecovery();
    _setPlayIntent(_loadGeneration, requested: false);
    final player = _player;
    if (player == null) return;
    await _serializePlayerOperation(player.pause);
    await _persistProgress();
  }

  @override
  Future<void> stop() async {
    _cancelPendingInterruptionResume();
    final transport = ++_transportRevision;
    _episodeSelectionGeneration++;
    _pendingEpisodeSelectionId = null;
    _clearLoadPlaybackIntent();
    _disarmPlaybackRecovery();
    _loadGeneration++;
    _currentItemStarted = false;
    final progress = _persistProgress();
    await _serializePlayerOperation(() async => _player?.stop());
    try {
      await progress;
    } on Object {
      // Stopping playback must not depend on a successful checkpoint.
    }
    if (transport != _transportRevision) return;
    _checkpointTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepAtEnd = false;
    _sleepGeneration++;
    _setSleepStatus(const SleepTimerStatus.off());
    _processingState = AudioProcessingState.idle;
    _broadcastState(playing: false);
    await _setPodcastSessionActive(false, expectedTransportRevision: transport);
  }

  @override
  Future<void> seek(Duration position) {
    final episodeId = mediaItem.value?.id;
    if (episodeId == null) return Future<void>.value();
    return seekEpisode(episodeId, position);
  }

  Future<void> seekEpisode(String episodeId, Duration position) async {
    if (mediaItem.value?.id != episodeId) return;
    final generation = _loadGeneration;
    if (_isLoadPending(generation)) return;
    await initialize();
    if (generation != _loadGeneration ||
        _isLoadPending(generation) ||
        mediaItem.value?.id != episodeId) {
      return;
    }
    final duration = _effectiveDuration;
    final safe = position < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && position > duration
        ? duration
        : position;
    await _serializePlayerOperation(() async {
      if (generation != _loadGeneration ||
          _isLoadPending(generation) ||
          mediaItem.value?.id != episodeId) {
        return;
      }
      await _player!.seek(safe);
    });
    if (generation != _loadGeneration || mediaItem.value?.id != episodeId) {
      return;
    }
    _position = safe;
    _broadcastState();
    await _persistProgress();
  }

  @override
  Future<void> rewind() => seek(_position - AppConstants.rewind);

  @override
  Future<void> fastForward() => seek(_position + AppConstants.forward);

  @override
  Future<void> skipToPrevious() async {
    final intent = _beginAudioPlaybackIntent();
    _episodeSelectionGeneration++;
    if (_position > AppConstants.playbackPositionThreshold) {
      await seek(Duration.zero);
      return;
    }
    final index = _currentQueueIndex(queue.value);
    if (index > 0) {
      await _persistProgress();
      if (!_isAudioPlaybackIntentCurrent(intent)) return;
      await _load(queue.value[index - 1], autoPlay: true);
      return;
    }
    await seek(Duration.zero);
  }

  @override
  Future<void> skipToNext() async {
    final intent = _beginAudioPlaybackIntent();
    _episodeSelectionGeneration++;
    await _persistProgress(markPlayedIfNearEnd: true);
    if (!_isAudioPlaybackIntentCurrent(intent)) return;
    final items = [...queue.value];
    final index = _currentQueueIndex(items);
    if (index < 0 || index + 1 >= items.length) {
      return;
    }
    await _load(items[index + 1], autoPlay: true);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final intent = _beginAudioPlaybackIntent();
    _episodeSelectionGeneration++;
    if (index < 0 || index >= queue.value.length) return;
    if (queue.value[index].id == mediaItem.value?.id) return;
    await _persistProgress(markPlayedIfNearEnd: true);
    if (!_isAudioPlaybackIntentCurrent(intent)) return;
    await _load(queue.value[index], autoPlay: true);
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    if (queue.value.any((entry) => entry.id == mediaItem.id)) return;
    _publishQueue([...queue.value, mediaItem]);
    await _persistQueue();
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final oldItems = [...queue.value];
    final oldIndex = oldItems.indexWhere((item) => item.id == mediaItem.id);
    final wasCurrent = this.mediaItem.value?.id == mediaItem.id;
    _publishQueue(oldItems.where((entry) => entry.id != mediaItem.id).toList());
    await _persistQueue();
    if (wasCurrent) {
      _episodeSelectionGeneration++;
      await _persistProgress();
      if (queue.value.isNotEmpty) {
        final nextIndex = oldIndex.clamp(0, queue.value.length - 1);
        await _load(
          queue.value[nextIndex],
          autoPlay: playbackState.value.playing,
        );
      } else {
        await stop();
        this.mediaItem.add(null);
      }
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    final seen = <String>{};
    _publishQueue(
      queue.where((item) => seen.add(item.id)).toList(growable: false),
    );
    await _persistQueue();
  }

  Future<void> clearQueue() async {
    _episodeSelectionGeneration++;
    await stop();
    _publishQueue(const []);
    mediaItem.add(null);
    await _persistQueue();
  }

  @override
  Future<void> setSpeed(double speed) async {
    final percent = (speed * 100).round();
    if (!AppConstants.allowedSpeeds.contains(percent)) return;
    _speedPercent = percent;
    await _settings.setSpeed(percent);
    await _serializePlayerOperation(() async {
      await _player?.setSpeed(percent / 100);
    });
    _broadcastState();
  }

  Future<void> setSleepTimer(
    Duration? duration, {
    bool endOfEpisode = false,
  }) async {
    _sleepTimer?.cancel();
    final generation = ++_sleepGeneration;
    _sleepAtEnd = endOfEpisode;
    if (duration != null) {
      _setSleepStatus(
        SleepTimerStatus.timed(DateTime.now().toUtc().add(duration)),
      );
      final delay = duration > AppConstants.sleepFade
          ? duration - AppConstants.sleepFade
          : Duration.zero;
      _sleepTimer = Timer(delay, () => _runDetached(_fadeAndPause(generation)));
    } else if (endOfEpisode) {
      _setSleepStatus(const SleepTimerStatus.endOfEpisode());
    } else {
      _setSleepStatus(const SleepTimerStatus.off());
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeatOne = repeatMode == AudioServiceRepeatMode.one;
    await _serializePlayerOperation(() async {
      await _player?.setLoopMode(_repeatOne ? LoopMode.one : LoopMode.off);
    });
    _broadcastState();
  }

  Future<void> _markEpisodePlayed(
    String id, {
    required Duration position,
    required Duration duration,
  }) {
    final completedDuration = completedProgressDuration(
      position: position,
      knownDuration: duration,
    );
    return _serializeProgressOperation(() async {
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await (_database.update(_database.episodes)
              ..where((row) => row.id.equals(id)))
            .write(const EpisodesCompanion(played: Value(true)));
        await _database
            .into(_database.playbackProgresses)
            .insertOnConflictUpdate(
              PlaybackProgressesCompanion.insert(
                episodeId: id,
                positionMs: Value(completedDuration.inMilliseconds),
                durationMs: Value(completedDuration.inMilliseconds),
                completed: const Value(true),
                completedAt: Value(now),
                updatedAt: now,
              ),
            );
      });
    });
  }

  Future<void> setEpisodePlayed(String episodeId, bool played) async {
    var episodeFound = false;
    await _serializeProgressOperation(() async {
      final episode = await _database.episodeById(episodeId);
      if (episode == null) return;
      episodeFound = true;
      final now = DateTime.now().toUtc();
      final currentDuration = _effectiveDuration;
      final durationMs =
          mediaItem.value?.id == episodeId && currentDuration > Duration.zero
          ? currentDuration.inMilliseconds
          : episode.durationMs;
      await _database.transaction(() async {
        await (_database.update(_database.episodes)
              ..where((row) => row.id.equals(episodeId)))
            .write(EpisodesCompanion(played: Value(played)));
        await _database
            .into(_database.playbackProgresses)
            .insertOnConflictUpdate(
              PlaybackProgressesCompanion.insert(
                episodeId: episodeId,
                positionMs: Value(played ? durationMs ?? 0 : 0),
                durationMs: Value(durationMs),
                completed: Value(played),
                completedAt: Value(played ? now : null),
                updatedAt: now,
              ),
            );
      });
    });
    final currentIsPlaying =
        mediaItem.value?.id == episodeId && playbackState.value.playing;
    if (played && episodeFound && !currentIsPlaying) {
      customEvent.add({'type': 'completed', 'episodeId': episodeId});
    }
  }

  Future<void> _load(
    MediaItem item, {
    required bool autoPlay,
    bool allowPlaybackRecovery = true,
  }) {
    if (_disposed) {
      return Future<void>.error(StateError('Audio handler has been disposed.'));
    }
    _cancelPendingInterruptionResume();
    final generation = ++_loadGeneration;
    _pendingLoadGeneration = generation;
    _pendingLoadEpisodeId = item.id;
    if (autoPlay && allowPlaybackRecovery) {
      _armPlaybackRecovery();
    } else if (!autoPlay) {
      _disarmPlaybackRecovery();
    }
    _setPlayIntent(generation, requested: autoPlay);
    return _prepareLoad(item, generation: generation);
  }

  Future<void> _prepareLoad(MediaItem item, {required int generation}) async {
    _throwIfDisposed();
    _playbackRecoveryTimer?.cancel();
    _loadingMedia = true;
    _currentItemStarted = false;
    _currentOutroSkipMs = 0;
    final replacingItem = mediaItem.value?.id != item.id;
    try {
      await _serializePlayerOperation(() async {
        if (generation == _loadGeneration) await _player?.pause();
      });
      if (generation != _loadGeneration) return;
      _processingState = AudioProcessingState.loading;
      mediaItem.add(item);
      if (replacingItem) {
        _position = Duration.zero;
        _duration = item.duration ?? Duration.zero;
        _buffered = Duration.zero;
        _positionEvents.add(_position);
        _durationEvents.add(_duration);
      }
      _broadcastState(playing: false);
      final episode = await _database.episodeById(item.id);
      if (episode == null) {
        throw StateError('The selected episode is no longer available.');
      }
      if (generation != _loadGeneration) return;
      final resolved = await Future.wait<Object?>([
        _sourceResolver.resolve(episode),
        _database.feedById(episode.feedId),
        (_database.select(
          _database.playbackProgresses,
        )..where((row) => row.episodeId.equals(item.id))).getSingleOrNull(),
      ]);
      if (generation != _loadGeneration) return;
      final source = resolved[0] as PlaybackSource;
      final feed = resolved[1] as Feed?;
      final progress = resolved[2] as PlaybackProgressesData?;
      _currentOutroSkipMs = feed?.outroSkipMs ?? 0;
      await initialize();
      if (generation != _loadGeneration || _disposed) return;
      await _serializePlayerOperation(() async {
        if (generation != _loadGeneration || _disposed) return;
        final player = _player!;
        _changingPlayerSource = true;
        try {
          if (source.isLocal) {
            await player.setFilePath(source.resource);
          } else {
            await player.setUrl(
              source.resource,
              headers: source.headers.isEmpty ? null : source.headers,
            );
          }
        } finally {
          _changingPlayerSource = false;
        }
        if (generation != _loadGeneration) {
          await player.stop();
          return;
        }
        await player.setSpeed(_speedPercent / 100);
        final effectiveDuration = _effectiveDuration > Duration.zero
            ? _effectiveDuration
            : Duration(milliseconds: progress?.durationMs ?? 0);
        if (progress != null &&
            progress.positionMs >=
                AppConstants.playbackPositionThreshold.inMilliseconds &&
            !progress.completed &&
            !isPlaybackComplete(
              Duration(milliseconds: progress.positionMs),
              effectiveDuration,
            )) {
          await player.seek(Duration(milliseconds: progress.positionMs));
        } else {
          final intro = Duration(milliseconds: feed?.introSkipMs ?? 0);
          if (intro > Duration.zero &&
              (effectiveDuration <= Duration.zero ||
                  intro < effectiveDuration)) {
            await player.seek(intro);
          }
        }
      });
      if (generation != _loadGeneration) return;
      _loadingMedia = false;
      if (_pendingLoadGeneration == generation) {
        _pendingLoadGeneration = null;
        _pendingLoadEpisodeId = null;
      }
      _processingState = AudioProcessingState.ready;
      if (_isPlayRequested(generation)) {
        await _playCurrent(
          expectedLoadGeneration: generation,
          expectedTransportRevision: _transportRevision,
        );
      }
      _broadcastState();
    } on Object {
      if (_disposed || generation != _loadGeneration) return;
      _setPlaybackError();
      rethrow;
    } finally {
      if (generation == _loadGeneration) _loadingMedia = false;
      if (_pendingLoadGeneration == generation &&
          generation == _loadGeneration) {
        _pendingLoadGeneration = null;
        _pendingLoadEpisodeId = null;
      }
    }
  }

  Future<void> _handleCompletion() {
    final item = mediaItem.value;
    if (item == null || !_completionsInFlight.add(item.id)) {
      return Future<void>.value();
    }
    final intent = (media: _mediaIntentRevision, transport: _transportRevision);
    final position = _position;
    final duration = _effectiveDuration;
    final previous = _completionTail;
    final operation = () async {
      try {
        await previous;
      } on Object {
        // A failed completion must not block a later episode from finishing.
      }
      await _completeEpisode(
        item,
        intent: intent,
        position: position,
        duration: duration,
      );
    }();
    _completionTail = operation.catchError((Object _) {});
    return operation.whenComplete(() => _completionsInFlight.remove(item.id));
  }

  Future<void> _completeEpisode(
    MediaItem completed, {
    required ({int media, int transport}) intent,
    required Duration position,
    required Duration duration,
  }) async {
    await _markEpisodePlayed(
      completed.id,
      position: position,
      duration: duration,
    );
    customEvent.add({'type': 'completed', 'episodeId': completed.id});

    if (mediaItem.value?.id != completed.id) {
      await _removeCompletedQueueItem(completed.id);
      return;
    }
    if (!_completionIntentIsCurrent(completed.id, intent)) {
      await _removeCompletedQueueItem(completed.id);
      return;
    }
    if (completed.extras?['standalone'] == true) {
      await _finishCompletedEpisode(completed.id, intent);
      return;
    }
    if (_sleepAtEnd) {
      _sleepAtEnd = false;
      _setSleepStatus(const SleepTimerStatus.off());
      await _removeCompletedQueueItem(completed.id);
      if (_completionIntentIsCurrent(completed.id, intent)) {
        await _finishCompletedEpisode(completed.id, intent);
      }
      return;
    }
    if (_repeatOne) {
      await seek(Duration.zero);
      if (_completionIntentIsCurrent(completed.id, intent)) await play();
      return;
    }

    final completedIndex = await _removeCompletedQueueItem(completed.id);
    if (!_completionIntentIsCurrent(completed.id, intent)) return;
    final items = queue.value;
    if (items.isEmpty) {
      await _finishCompletedEpisode(completed.id, intent);
      return;
    }
    final nextIndex = completedIndex == null || completedIndex >= items.length
        ? 0
        : completedIndex;
    await _load(items[nextIndex], autoPlay: true);
  }

  Future<int?> _removeCompletedQueueItem(String episodeId) async {
    final items = [...queue.value];
    final index = items.indexWhere((item) => item.id == episodeId);
    if (index >= 0) {
      items.removeAt(index);
      _publishQueue(items);
      await _persistQueue();
    }
    await reloadQueueFromDatabase();
    return index < 0 ? null : index;
  }

  bool _completionIntentIsCurrent(
    String episodeId,
    ({int media, int transport}) intent,
  ) =>
      mediaItem.value?.id == episodeId &&
      _mediaIntentRevision == intent.media &&
      _transportRevision == intent.transport &&
      _webVideoIntentRevision == null;

  Future<void> _finishCompletedEpisode(
    String episodeId,
    ({int media, int transport}) intent,
  ) async {
    if (!_completionIntentIsCurrent(episodeId, intent)) return;
    _disarmPlaybackRecovery();
    _setPlayIntent(_loadGeneration, requested: false);
    await _serializePlayerOperation(() async {
      if (_completionIntentIsCurrent(episodeId, intent)) {
        await _player?.pause();
      }
    });
    if (!_completionIntentIsCurrent(episodeId, intent)) return;
    _currentItemStarted = false;
    mediaItem.add(null);
    _processingState = AudioProcessingState.completed;
    _broadcastState(playing: false);
    await _setPodcastSessionActive(false, expectedMediaIntent: intent.media);
  }

  Future<void> _fadeAndPause(int generation) async {
    final player = _player;
    if (player == null) {
      if (generation == _sleepGeneration) {
        _sleepAtEnd = false;
        _setSleepStatus(const SleepTimerStatus.off());
      }
      return;
    }
    try {
      for (var step = AppConstants.sleepFadeSteps; step >= 0; step--) {
        if (generation != _sleepGeneration) return;
        await _serializePlayerOperation(() async {
          if (!_disposed && generation == _sleepGeneration) {
            await player.setVolume(step / AppConstants.sleepFadeSteps);
          }
        });
        if (step > 0) {
          await Future<void>.delayed(AppConstants.sleepFadeStepInterval);
        }
      }
      await pause();
    } finally {
      if (!_disposed) {
        try {
          await _serializePlayerOperation(() => player.setVolume(1));
        } on Object {
          // The timer state must still settle if the native player is gone.
        }
      }
      if (generation == _sleepGeneration) {
        _sleepAtEnd = false;
        _setSleepStatus(const SleepTimerStatus.off());
      }
    }
  }

  void _setSleepStatus(SleepTimerStatus status) {
    _sleepStatusTicker?.cancel();
    _sleepStatus = status;
    if (!_disposed && !_sleepStatusEvents.isClosed) {
      _sleepStatusEvents.add(status);
    }
    if (status.mode == SleepTimerMode.timed) {
      _sleepStatusTicker = Timer.periodic(AppConstants.sleepStatusUpdate, (_) {
        if (_disposed || _sleepStatusEvents.isClosed) return;
        _sleepStatusEvents.add(_sleepStatus);
      });
    }
  }

  void _startCheckpointing() {
    _checkpointTimer?.cancel();
    _checkpointTimer = Timer.periodic(
      AppConstants.progressCheckpoint,
      (_) => _runDetached(_persistProgress()),
    );
  }

  Future<void> _persistProgress({bool markPlayedIfNearEnd = false}) {
    final id = mediaItem.value?.id;
    if (id == null) return Future<void>.value();
    final position = _position;
    final duration = _effectiveDuration;
    return _serializeProgressOperation(() async {
      final existing = await (_database.select(
        _database.playbackProgresses,
      )..where((row) => row.episodeId.equals(id))).getSingleOrNull();
      final becameComplete =
          markPlayedIfNearEnd && isPlaybackComplete(position, duration);
      final completed = existing?.completed == true || becameComplete;
      final now = DateTime.now().toUtc();
      await _database.transaction(() async {
        await _database
            .into(_database.playbackProgresses)
            .insertOnConflictUpdate(
              PlaybackProgressesCompanion.insert(
                episodeId: id,
                positionMs: Value(position.inMilliseconds),
                durationMs: Value(
                  duration > Duration.zero
                      ? duration.inMilliseconds
                      : existing?.durationMs,
                ),
                completed: Value(completed),
                completedAt: Value(
                  existing?.completedAt ?? (becameComplete ? now : null),
                ),
                updatedAt: now,
              ),
            );
        if (completed) {
          await (_database.update(_database.episodes)
                ..where((row) => row.id.equals(id)))
              .write(const EpisodesCompanion(played: Value(true)));
        }
      });
      if (becameComplete && existing?.completed != true) {
        customEvent.add({'type': 'completed', 'episodeId': id});
      }
    });
  }

  Future<T> _serializeProgressOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _progressOperationTail;
    _progressOperationTail = () async {
      try {
        await previous;
      } on Object {
        // A failed checkpoint must not prevent later progress from persisting.
      }
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  int _currentQueueIndex(List<MediaItem> items) {
    final currentId = mediaItem.value?.id;
    return currentId == null
        ? -1
        : items.indexWhere((item) => item.id == currentId);
  }

  Future<MediaItem?> _mediaItemForEpisode(String episodeId) async {
    final episode = await _database.episodeById(episodeId);
    if (episode == null) return null;
    final feed = await _database.feedById(episode.feedId);
    return _mediaItem(episode, feed);
  }

  MediaItem _mediaItem(Episode episode, Feed? feed, {bool standalone = false}) {
    final artworkUrl = (episode.imageUrl ?? feed?.imageUrl)?.trim();
    final artworkUri = artworkUrl == null || artworkUrl.isEmpty
        ? null
        : Uri.tryParse(artworkUrl);
    final articleId = episode.guid?.startsWith('nostr-media:') == true
        ? episode.guid!.substring('nostr-media:'.length)
        : null;
    return MediaItem(
      id: episode.id,
      title: episode.title,
      album: feed?.title,
      artist: feed?.author,
      duration: episode.durationMs == null
          ? null
          : Duration(milliseconds: episode.durationMs!),
      artUri:
          artworkUri?.scheme == 'https' && artworkUri?.host.isNotEmpty == true
          ? artworkUri
          : null,
      displayDescription: episode.description,
      playable: true,
      extras: {
        'feedId': episode.feedId,
        'explicit': episode.explicit,
        if (articleId?.isNotEmpty == true) 'articleId': articleId,
        if (standalone) 'standalone': true,
      },
    );
  }

  Future<void> _restoreQueue() async {
    if (_structuralQueueRevision != _persistedStructuralQueueRevision) return;
    final revision = _queueRevision;
    final pendingAdditions = await _database.mergePendingQueueAdditions();
    if (revision != _queueRevision ||
        _structuralQueueRevision != _persistedStructuralQueueRevision) {
      return;
    }
    final query = _database.select(_database.queueEntries).join([
      innerJoin(
        _database.episodes,
        _database.episodes.id.equalsExp(_database.queueEntries.episodeId),
      ),
      leftOuterJoin(
        _database.feeds,
        _database.feeds.id.equalsExp(_database.episodes.feedId),
      ),
    ])..orderBy([OrderingTerm.asc(_database.queueEntries.sortKey)]);
    final rows = await query.get();
    final items = [
      for (final row in rows)
        _mediaItem(
          row.readTable(_database.episodes),
          row.readTableOrNull(_database.feeds),
        ),
    ];
    // A foreground action may have changed Up Next while the database query was
    // in flight. Its later persisted snapshot must remain visible.
    if (revision != _queueRevision ||
        _structuralQueueRevision != _persistedStructuralQueueRevision) {
      return;
    }
    _queueIndexes = {
      for (var index = 0; index < items.length; index++) items[index].id: index,
    };
    queue.add(items);
    await _database.acknowledgePendingQueueAdditions(pendingAdditions);
  }

  Future<void> reloadQueueFromDatabase() {
    return _serializeQueueOperation(() async {
      await _restoreQueue();
      _broadcastState();
    });
  }

  Future<void> reloadSettingsFromDatabase() async {
    _speedPercent = await _settings.speed();
    await _serializePlayerOperation(() async {
      await _player?.setSpeed(_speedPercent / 100);
    });
    _broadcastState();
  }

  Future<void> removeEpisodesFromLibrary(Iterable<String> episodeIds) async {
    final removed = episodeIds.toSet();
    if (removed.isEmpty) return;
    final currentId = mediaItem.value?.id;
    final affectsPlayback = removedEpisodesAffectPlayback(
      removedEpisodeIds: removed,
      currentEpisodeId: currentId,
      pendingSelectionEpisodeId: _pendingEpisodeSelectionId,
      pendingLoadEpisodeId: _pendingLoadEpisodeId,
    );
    if (affectsPlayback) {
      _episodeSelectionGeneration++;
      _pendingEpisodeSelectionId = null;
    }
    final removesPendingLoad = removed.contains(_pendingLoadEpisodeId);
    if (removesPendingLoad && !removed.contains(currentId)) {
      _clearLoadPlaybackIntent();
      _loadGeneration++;
    }
    if (currentId != null && removed.contains(currentId)) {
      await stop();
      if (mediaItem.value?.id == currentId) mediaItem.add(null);
    }
    _publishQueue(
      queue.value
          .where((item) => !removed.contains(item.id))
          .toList(growable: false),
    );
    await _persistQueue();
  }

  Future<void> _persistQueue() {
    final now = DateTime.now().toUtc();
    final revision = _structuralQueueRevision;
    final entries = <QueueEntriesCompanion>[
      for (var index = 0; index < queue.value.length; index++)
        QueueEntriesCompanion.insert(
          id: _uuid.v4(),
          episodeId: queue.value[index].id,
          sortKey: index * 1024,
          addedAt: now,
        ),
    ];
    _broadcastState();
    return _serializeQueueOperation(() async {
      await _database.batch((batch) {
        batch.deleteAll(_database.queueEntries);
        if (entries.isNotEmpty) {
          batch.insertAll(_database.queueEntries, entries);
        }
      });
      if (revision > _persistedStructuralQueueRevision) {
        _persistedStructuralQueueRevision = revision;
      }
    });
  }

  void _publishQueue(List<MediaItem> items, {bool structural = true}) {
    _queueRevision++;
    if (structural) _structuralQueueRevision++;
    _queueIndexes = {
      for (var index = 0; index < items.length; index++) items[index].id: index,
    };
    queue.add(items);
  }

  Future<void> _serializeQueueOperation(Future<void> Function() operation) {
    final previous = _queueOperationTail;
    final next = () async {
      try {
        await previous;
      } on Object {
        // A failed write must not prevent a later queue snapshot from winning.
      }
      await operation();
    }();
    _queueOperationTail = next;
    return next;
  }

  Future<void> _resumeAfterInterruption(int generation) async {
    try {
      await _interruptionPause;
    } on Object {
      return;
    }
    if (!_resumeIsStillAllowed(generation)) return;
    final loadGeneration = _loadGeneration;
    _armPlaybackRecovery();
    _setPlayIntent(loadGeneration, requested: true);
    if (_isLoadPending(loadGeneration)) return;
    await _playCurrent(
      interruptionResumeGeneration: generation,
      expectedLoadGeneration: loadGeneration,
      expectedTransportRevision: _transportRevision,
    );
  }

  bool _isLoadPending(int generation) =>
      generation == _loadGeneration && _pendingLoadGeneration == generation;

  bool _isPlayRequested(int generation) =>
      _playIntentGeneration == generation && _playRequested;

  bool _canActivatePlayback(
    int generation,
    int transportRevision,
    int? interruptionResumeGeneration,
  ) {
    return !_disposed &&
        generation == _loadGeneration &&
        transportRevision == _transportRevision &&
        _webVideoIntentRevision == null &&
        !_isLoadPending(generation) &&
        _isPlayRequested(generation) &&
        _resumeIsStillAllowed(interruptionResumeGeneration);
  }

  void _setPlayIntent(int generation, {required bool requested}) {
    if (generation != _loadGeneration) return;
    _playIntentGeneration = generation;
    _playRequested = requested;
  }

  void _clearLoadPlaybackIntent() {
    _pendingLoadGeneration = null;
    _pendingLoadEpisodeId = null;
    _playIntentGeneration = null;
    _playRequested = false;
    _loadingMedia = false;
  }

  ({int media, int transport}) _beginAudioPlaybackIntent() {
    _cancelPendingInterruptionResume();
    final media = ++_mediaIntentRevision;
    _webVideoIntentRevision = null;
    final transport = ++_transportRevision;
    if (!_disposed && !_mediaPlaybackIntentEvents.isClosed) {
      _mediaPlaybackIntentEvents.add(media);
    }
    return (media: media, transport: transport);
  }

  bool _isAudioPlaybackIntentCurrent(({int media, int transport}) intent) =>
      !_disposed &&
      _mediaIntentRevision == intent.media &&
      _transportRevision == intent.transport &&
      _webVideoIntentRevision == null;

  void _armPlaybackRecovery() {
    _playbackRecoveryTimer?.cancel();
    _playbackRecoveryAvailable = true;
  }

  void _disarmPlaybackRecovery() {
    _playbackRecoveryTimer?.cancel();
    _playbackRecoveryTimer = null;
    _playbackRecoveryAvailable = false;
  }

  void _schedulePlaybackRecovery() {
    _playbackRecoveryTimer?.cancel();
    final generation = _loadGeneration;
    final episodeId = mediaItem.value?.id;
    if (episodeId == null || !_needsPlaybackRecovery(generation, episodeId)) {
      _playbackRecoveryTimer = null;
      return;
    }
    _playbackRecoveryTimer = Timer(AppConstants.shortOperationTimeout, () {
      _playbackRecoveryTimer = null;
      if (_needsPlaybackRecovery(generation, episodeId)) {
        _runDetached(recoverPlaybackIfNeeded());
      }
    });
  }

  /// Repairs a requested podcast session after an unexpected native stop.
  ///
  /// The guard is also called when the app returns to the foreground. It does
  /// nothing after a user pause, during a load, or at the end of an episode.
  Future<void> recoverPlaybackIfNeeded() {
    final generation = _loadGeneration;
    final active = _playbackRecovery;
    if (active != null && active.generation == generation) {
      return active.future;
    }
    final episodeId = mediaItem.value?.id;
    if (episodeId == null || !_needsPlaybackRecovery(generation, episodeId)) {
      return Future<void>.value();
    }
    final recovery = _recoverPlayback(generation, episodeId);
    _playbackRecovery = (generation: generation, future: recovery);
    return recovery.whenComplete(() {
      if (identical(_playbackRecovery?.future, recovery)) {
        _playbackRecovery = null;
      }
    });
  }

  bool _needsPlaybackRecovery(int generation, String episodeId) {
    final player = _player;
    if (player == null ||
        generation != _loadGeneration ||
        mediaItem.value?.id != episodeId ||
        _isLoadPending(generation)) {
      return false;
    }
    return shouldRecoverUnexpectedPlaybackStop(
      playRequested: _isPlayRequested(generation),
      playerPlaying: player.playing,
      loadingMedia: _loadingMedia,
      handlingCompletion: _completionsInFlight.contains(episodeId),
      terminalState:
          _processingState == AudioProcessingState.completed ||
          _processingState == AudioProcessingState.error,
      position: _position,
      duration: _effectiveDuration,
    );
  }

  Future<void> _recoverPlayback(int generation, String episodeId) async {
    if (!_playbackRecoveryAvailable) {
      _setPlaybackError();
      return;
    }
    _playbackRecoveryAvailable = false;
    _playbackRecoveryTimer?.cancel();
    final player = _player!;
    final transport = _transportRevision;
    try {
      if (player.processingState == ProcessingState.idle) {
        final current = mediaItem.value;
        if (current != null) {
          await _load(current, autoPlay: true, allowPlaybackRecovery: false);
        }
        return;
      }
      final activated = await _configurePodcastSession(
        activate: true,
        expectedTransportRevision: transport,
      );
      if (transport != _transportRevision ||
          !_needsPlaybackRecovery(generation, episodeId)) {
        return;
      }
      if (!activated) {
        if (!_playbackRecoveryAvailable) _setPlaybackError();
        return;
      }
      await _serializePlayerOperation(() async {
        if (transport == _transportRevision &&
            _needsPlaybackRecovery(generation, episodeId)) {
          _startPlayer(player, generation);
        }
      });
    } on Object {
      if (!_playbackRecoveryAvailable &&
          _needsPlaybackRecovery(generation, episodeId)) {
        _setPlaybackError();
      }
      rethrow;
    }
  }

  void _startPlayer(AudioPlayer player, int generation) {
    unawaited(
      player.play().catchError((Object _) {
        final episodeId = mediaItem.value?.id;
        if (episodeId != null &&
            _needsPlaybackRecovery(generation, episodeId)) {
          _setPlaybackError();
        }
      }),
    );
    _schedulePlaybackRecovery();
  }

  bool _resumeIsStillAllowed(int? generation) {
    return generation == null ||
        (!_disposed && generation == _interruptionResumeGeneration);
  }

  void _cancelPendingInterruptionResume() {
    _pendingInterruptionResumeGeneration = null;
    _interruptionResumeGeneration++;
  }

  void _setPlaybackError() {
    if (_disposed) return;
    _disarmPlaybackRecovery();
    _cancelPendingInterruptionResume();
    _setPlayIntent(_loadGeneration, requested: false);
    _currentItemStarted = false;
    _checkpointTimer?.cancel();
    _processingState = AudioProcessingState.error;
    _broadcastState(playing: false);
    _runDetached(
      _setPodcastSessionActive(
        false,
        expectedMediaIntent: _mediaIntentRevision,
        expectedTransportRevision: _transportRevision,
      ),
    );
  }

  Future<bool> _setPodcastSessionActive(
    bool active, {
    int? expectedMediaIntent,
    int? expectedTransportRevision,
  }) {
    final session = _session;
    if (session == null) return Future<bool>.value(true);
    return _queueSessionOperation(() {
      if (!_podcastSessionIntentIsCurrent(
        expectedMediaIntent: expectedMediaIntent,
        expectedTransportRevision: expectedTransportRevision,
      )) {
        return Future<bool>.value(false);
      }
      return session.setActive(active);
    });
  }

  Future<bool> _configurePodcastSession({
    required bool activate,
    required int expectedTransportRevision,
  }) {
    final session = _session;
    if (session == null) return Future<bool>.value(true);
    return _queueSessionOperation(() async {
      if (!_podcastSessionIntentIsCurrent(
        expectedTransportRevision: expectedTransportRevision,
      )) {
        return false;
      }
      await session.configure(_podcastAudioSessionConfiguration);
      if (!_podcastSessionIntentIsCurrent(
        expectedTransportRevision: expectedTransportRevision,
      )) {
        return false;
      }
      return session.setActive(activate);
    });
  }

  Future<bool> _configureWebVideoSession(int intent, {required bool activate}) {
    final session = _session;
    if (session == null) return Future<bool>.value(true);
    return _queueSessionOperation(() async {
      if (!isWebVideoPlaybackCurrent(intent)) return false;
      await session.configure(_videoAudioSessionConfiguration);
      if (!isWebVideoPlaybackCurrent(intent)) return false;
      return session.setActive(activate);
    });
  }

  bool _podcastSessionIntentIsCurrent({
    int? expectedMediaIntent,
    int? expectedTransportRevision,
  }) {
    if (expectedMediaIntent == null && expectedTransportRevision == null) {
      return true;
    }
    return _webVideoIntentRevision == null &&
        (expectedMediaIntent == null ||
            expectedMediaIntent == _mediaIntentRevision) &&
        (expectedTransportRevision == null ||
            expectedTransportRevision == _transportRevision);
  }

  Future<T> _serializePlayerOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _playerOperationTail;
    _playerOperationTail = () async {
      try {
        await previous;
      } on Object {
        // A failed player call must not block the next transport command.
      }
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  Future<T> _queueSessionOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _sessionOperationTail;
    _sessionOperationTail = () async {
      try {
        await previous;
      } on Object {
        // A failed activation must not block the next transport command.
      }
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('Audio handler has been disposed.');
  }

  void _broadcastState({bool? playing}) {
    if (_disposed) return;
    final isPlaying = _processingState == AudioProcessingState.error
        ? false
        : playing ?? _player?.playing ?? false;
    final currentId = mediaItem.value?.id;
    final currentIndex = currentId == null
        ? -1
        : _queueIndexes[currentId] ?? -1;
    final hasNext = currentIndex >= 0 && currentIndex + 1 < queue.value.length;
    final controls = <MediaControl>[
      MediaControl.rewind,
      isPlaying ? MediaControl.pause : MediaControl.play,
      MediaControl.fastForward,
      if (hasNext) MediaControl.skipToNext,
    ];
    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        androidCompactActionIndices: hasNext
            ? const [0, 1, 3]
            : const [0, 1, 2],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekBackward,
          MediaAction.seekForward,
          MediaAction.setSpeed,
        },
        processingState: _processingState,
        playing: isPlaying,
        errorCode: _processingState == AudioProcessingState.error ? 1 : null,
        errorMessage: _processingState == AudioProcessingState.error
            ? playbackErrorMessage
            : null,
        updatePosition: _position,
        bufferedPosition: _buffered,
        speed: _speedPercent / 100,
        queueIndex: currentIndex,
        repeatMode: _repeatOne
            ? AudioServiceRepeatMode.one
            : AudioServiceRepeatMode.none,
      ),
    );
  }

  void _runDetached(Future<void> operation) {
    unawaited(operation.catchError((Object _) {}));
  }

  Future<void> disposeHandler() async {
    if (_disposed) return;
    _disposed = true;
    _cancelPendingInterruptionResume();
    _episodeSelectionGeneration++;
    _clearLoadPlaybackIntent();
    _loadGeneration++;
    _mediaIntentRevision++;
    _transportRevision++;
    _webVideoIntentRevision = null;
    try {
      await _persistProgress();
    } on Object {
      // Persistence failure must not leak native playback resources.
    }
    _checkpointTimer?.cancel();
    _playbackRecoveryTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepStatusTicker?.cancel();
    _sleepGeneration++;
    final initialization = _initialization;
    if (initialization != null) {
      try {
        await initialization;
      } on Object {
        // Initialization observes disposal and releases any partial player.
      }
    }
    try {
      await _playerOperationTail;
    } on Object {
      // A failed player call does not prevent its resources being released.
    }
    try {
      await _interruptionPause;
    } on Object {
      // A failed interruption pause does not prevent disposal.
    }
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } on Object {
        // Continue releasing the remaining subscriptions and player.
      }
    }
    try {
      await _completionTail;
    } on Object {
      // Completion persistence cannot prevent disposal.
    }
    try {
      await _queueOperationTail;
    } on Object {
      // The handler can still finish disposal if the final queue write failed.
    }
    try {
      await _setPodcastSessionActive(false);
      await _sessionOperationTail;
    } on Object {
      // Native session failures must not prevent player disposal.
    }
    try {
      await _player?.dispose();
    } on Object {
      // Streams still need to close if the native player rejects disposal.
    } finally {
      _player = null;
      _session = null;
      await _positionEvents.close();
      await _durationEvents.close();
      await _sleepStatusEvents.close();
      await _mediaPlaybackIntentEvents.close();
    }
  }
}
