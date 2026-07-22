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

  AudioSession? _session;
  Future<void>? _initialization;
  bool _audioServiceInitialized = false;
  Timer? _checkpointTimer;
  Timer? _sleepTimer;
  Timer? _sleepStatusTicker;
  bool _sleepAtEnd = false;
  SleepTimerStatus _sleepStatus = const SleepTimerStatus.off();
  int _sleepGeneration = 0;
  int _interruptionResumeGeneration = 0;
  int? _pendingInterruptionResumeGeneration;
  Future<void> _interruptionPause = Future<void>.value();
  bool _duckedForInterruption = false;
  bool _handlingCompletion = false;
  bool _loadingMedia = false;
  bool _repeatOne = false;
  int _speedPercent = AppConstants.defaultSpeed;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  AudioProcessingState _processingState = AudioProcessingState.idle;
  int _currentOutroSkipMs = 0;
  bool _disposed = false;
  Future<void> _loadTail = Future<void>.value();
  Future<void> _queueOperationTail = Future<void>.value();
  Future<void> _progressOperationTail = Future<void>.value();
  int _episodeSelectionGeneration = 0;
  String? _pendingEpisodeSelectionId;
  int _loadGeneration = 0;
  int? _pendingLoadGeneration;
  String? _pendingLoadEpisodeId;
  int? _playIntentGeneration;
  bool _playRequested = false;
  bool _currentItemStarted = false;

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
      await session.configure(AudioSessionConfiguration.speech());
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
            _startCheckpointing();
          } else {
            _checkpointTimer?.cancel();
          }
        }),
        player.positionStream.listen((position) {
          _position = position;
          _positionEvents.add(position);
          if (!_handlingCompletion &&
              shouldHandleOutroSkip(
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
              queue.add(items);
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
        player.errorStream.listen((_) => _setPlaybackError()),
        session.interruptionEventStream.listen((event) {
          if (event.begin) {
            switch (event.type) {
              case AudioInterruptionType.duck:
                _duckedForInterruption = true;
                _runDetached(player.setVolume(0.3));
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
              _runDetached(player.setVolume(1));
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

  /// Activates the app's playback session before WebKit starts video audio.
  Future<void> activateWebVideoAudioSession() async {
    await initialize();
    await _session?.setActive(true);
  }

  Future<void> playEpisode(String episodeId) async {
    final generation = ++_episodeSelectionGeneration;
    _pendingEpisodeSelectionId = episodeId;
    try {
      await _persistProgress();
      final item = await _mediaItemForEpisode(episodeId);
      if (item == null || generation != _episodeSelectionGeneration) return;
      var items = [...queue.value];
      items.removeWhere((candidate) => candidate.id == episodeId);
      final currentIndex = _currentQueueIndex(items);
      final insertAt = currentIndex < 0
          ? 0
          : math.min(currentIndex, items.length);
      items.insert(insertAt, item);
      queue.add(items);
      await _persistQueue();
      if (generation != _episodeSelectionGeneration) return;
      await _load(item, autoPlay: true);
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
    queue.add(items);
    await _persistQueue();
  }

  Future<void> addEpisodeToQueue(String episodeId) async {
    final item = await _mediaItemForEpisode(episodeId);
    if (item == null || queue.value.any((entry) => entry.id == episodeId)) {
      return;
    }
    queue.add([...queue.value, item]);
    await _persistQueue();
  }

  @override
  Future<void> play() async {
    _cancelPendingInterruptionResume();
    final generation = _loadGeneration;
    _setPlayIntent(generation, requested: true);
    if (_isLoadPending(generation)) return;
    await _playCurrent(expectedLoadGeneration: generation);
  }

  Future<void> _playCurrent({
    int? interruptionResumeGeneration,
    required int expectedLoadGeneration,
  }) async {
    if (!_canActivatePlayback(
      expectedLoadGeneration,
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
      interruptionResumeGeneration,
    )) {
      return;
    }
    if (await _session?.setActive(true) == false) {
      _broadcastState(playing: false);
      return;
    }
    if (!_canActivatePlayback(
      expectedLoadGeneration,
      interruptionResumeGeneration,
    )) {
      await _session?.setActive(false);
      return;
    }
    final player = _player!;
    // just_audio's play future completes when playback later pauses or ends.
    // Do not hold the load queue or UI action open for the entire episode.
    _runDetached(player.play());
  }

  @override
  Future<void> pause() async {
    _cancelPendingInterruptionResume();
    await _pauseCurrent();
  }

  Future<void> _pauseCurrent() async {
    _setPlayIntent(_loadGeneration, requested: false);
    final player = _player;
    if (player == null) return;
    await player.pause();
    await _persistProgress();
  }

  @override
  Future<void> stop() async {
    _cancelPendingInterruptionResume();
    _clearLoadPlaybackIntent();
    _loadGeneration++;
    _currentItemStarted = false;
    await _persistProgress();
    await _player?.stop();
    _checkpointTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepAtEnd = false;
    _sleepGeneration++;
    _setSleepStatus(const SleepTimerStatus.off());
    _processingState = AudioProcessingState.idle;
    _broadcastState(playing: false);
    await _session?.setActive(false);
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
    await _player!.seek(safe);
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
    _episodeSelectionGeneration++;
    if (_position > AppConstants.playbackPositionThreshold) {
      await seek(Duration.zero);
      return;
    }
    final index = _currentQueueIndex(queue.value);
    if (index > 0) {
      await _persistProgress();
      await _load(queue.value[index - 1], autoPlay: true);
      return;
    }
    await seek(Duration.zero);
  }

  @override
  Future<void> skipToNext() async {
    _episodeSelectionGeneration++;
    await _persistProgress(markPlayedIfNearEnd: true);
    final items = [...queue.value];
    final index = _currentQueueIndex(items);
    if (index < 0 || index + 1 >= items.length) {
      await pause();
      return;
    }
    await _load(items[index + 1], autoPlay: true);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _episodeSelectionGeneration++;
    if (index < 0 || index >= queue.value.length) return;
    await _persistProgress(markPlayedIfNearEnd: true);
    await _load(queue.value[index], autoPlay: true);
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    if (queue.value.any((entry) => entry.id == mediaItem.id)) return;
    queue.add([...queue.value, mediaItem]);
    await _persistQueue();
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final oldItems = [...queue.value];
    final oldIndex = oldItems.indexWhere((item) => item.id == mediaItem.id);
    final wasCurrent = this.mediaItem.value?.id == mediaItem.id;
    queue.add(oldItems.where((entry) => entry.id != mediaItem.id).toList());
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
    this.queue.add(
      queue.where((item) => seen.add(item.id)).toList(growable: false),
    );
    await _persistQueue();
    _broadcastState();
  }

  Future<void> clearQueue() async {
    _episodeSelectionGeneration++;
    await stop();
    queue.add(const []);
    mediaItem.add(null);
    await _persistQueue();
  }

  @override
  Future<void> setSpeed(double speed) async {
    final percent = (speed * 100).round();
    if (!AppConstants.allowedSpeeds.contains(percent)) return;
    _speedPercent = percent;
    await _settings.setSpeed(percent);
    final player = _player;
    if (player != null) await player.setSpeed(percent / 100);
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
    final player = _player;
    if (player != null) {
      await player.setLoopMode(_repeatOne ? LoopMode.one : LoopMode.off);
    }
    _broadcastState();
  }

  Future<String?> _markCurrentPlayed() {
    final id = mediaItem.value?.id;
    if (id == null) return Future<String?>.value();
    final duration = completedProgressDuration(
      position: _position,
      knownDuration: _effectiveDuration,
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
                positionMs: Value(duration.inMilliseconds),
                durationMs: Value(duration.inMilliseconds),
                completed: const Value(true),
                completedAt: Value(now),
                updatedAt: now,
              ),
            );
      });
      return id;
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
    if (played && episodeFound) {
      customEvent.add({'type': 'completed', 'episodeId': episodeId});
    }
  }

  Future<void> _load(MediaItem item, {required bool autoPlay}) {
    if (_disposed) {
      return Future<void>.error(StateError('Audio handler has been disposed.'));
    }
    _cancelPendingInterruptionResume();
    final generation = ++_loadGeneration;
    _pendingLoadGeneration = generation;
    _pendingLoadEpisodeId = item.id;
    _setPlayIntent(generation, requested: autoPlay);
    final completer = Completer<void>();
    final previous = _loadTail;
    _loadTail = () async {
      try {
        await previous;
      } on Object {
        // A later user selection must still load after an earlier failure.
      }
      try {
        if (generation == _loadGeneration) {
          await _performLoad(item, generation: generation);
        }
        completer.complete();
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (_pendingLoadGeneration == generation) {
          _pendingLoadGeneration = null;
          _pendingLoadEpisodeId = null;
        }
      }
    }();
    return completer.future;
  }

  Future<void> _performLoad(MediaItem item, {required int generation}) async {
    _throwIfDisposed();
    _loadingMedia = true;
    _currentItemStarted = false;
    _currentOutroSkipMs = 0;
    final replacingItem = mediaItem.value?.id != item.id;
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
    try {
      if (replacingItem) await _player?.pause();
      if (generation != _loadGeneration) return;
      final episode = await _database.episodeById(item.id);
      if (episode == null) {
        throw StateError('The selected episode is no longer available.');
      }
      if (generation != _loadGeneration) return;
      final source = await _sourceResolver.resolve(episode);
      if (generation != _loadGeneration) return;
      final feed = await _database.feedById(episode.feedId);
      if (generation != _loadGeneration) return;
      _currentOutroSkipMs = feed?.outroSkipMs ?? 0;
      await initialize();
      if (generation != _loadGeneration || _disposed) return;
      final player = _player!;
      if (source.isLocal) {
        await player.setFilePath(source.resource);
      } else {
        await player.setUrl(
          source.resource,
          headers: source.headers.isEmpty ? null : source.headers,
        );
      }
      if (generation != _loadGeneration) {
        await player.stop();
        return;
      }
      await player.setSpeed(_speedPercent / 100);
      final progress = await (_database.select(
        _database.playbackProgresses,
      )..where((row) => row.episodeId.equals(item.id))).getSingleOrNull();
      if (generation != _loadGeneration) {
        await player.stop();
        return;
      }
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
            (effectiveDuration <= Duration.zero || intro < effectiveDuration)) {
          await player.seek(intro);
        }
      }
      if (generation != _loadGeneration) return;
      _loadingMedia = false;
      if (_pendingLoadGeneration == generation) {
        _pendingLoadGeneration = null;
        _pendingLoadEpisodeId = null;
      }
      _processingState = AudioProcessingState.ready;
      if (_isPlayRequested(generation)) {
        await _playCurrent(expectedLoadGeneration: generation);
      }
      _broadcastState();
    } on Object {
      if (!_disposed && generation == _loadGeneration) {
        _setPlaybackError();
      }
      rethrow;
    } finally {
      _loadingMedia = false;
      if (_pendingLoadGeneration == generation) {
        _pendingLoadGeneration = null;
      }
    }
  }

  Future<void> _handleCompletion() async {
    if (_handlingCompletion) return;
    _handlingCompletion = true;
    try {
      final completedId = await _markCurrentPlayed();
      if (completedId != null) {
        customEvent.add({'type': 'completed', 'episodeId': completedId});
      }
      if (completedId == null) return;
      if (mediaItem.value?.id != completedId) {
        final items = [...queue.value]
          ..removeWhere((item) => item.id == completedId);
        queue.add(items);
        await _persistQueue();
        return;
      }
      if (_sleepAtEnd) {
        _sleepAtEnd = false;
        _setSleepStatus(const SleepTimerStatus.off());
        final items = [...queue.value];
        final index = _currentQueueIndex(items);
        if (index >= 0) {
          items.removeAt(index);
          queue.add(items);
          await _persistQueue();
        }
        await pause();
        mediaItem.add(null);
        _processingState = AudioProcessingState.completed;
        _broadcastState(playing: false);
        return;
      }
      if (_repeatOne) {
        await seek(Duration.zero);
        await play();
        return;
      }
      final items = [...queue.value];
      final index = _currentQueueIndex(items);
      if (index >= 0) {
        items.removeAt(index);
        queue.add(items);
        await _persistQueue();
      }
      if (index >= 0 && index < items.length) {
        await _load(items[index], autoPlay: true);
      } else if (items.isNotEmpty) {
        await _load(items.first, autoPlay: true);
      } else {
        await pause();
        mediaItem.add(null);
        _processingState = AudioProcessingState.completed;
        _broadcastState(playing: false);
      }
    } finally {
      _handlingCompletion = false;
    }
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
        await player.setVolume(step / AppConstants.sleepFadeSteps);
        if (step > 0) {
          await Future<void>.delayed(AppConstants.sleepFadeStepInterval);
        }
      }
      await pause();
    } finally {
      try {
        await player.setVolume(1);
      } on Object {
        // The timer state must still settle if the native player is gone.
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

  MediaItem _mediaItem(Episode episode, Feed? feed) {
    return MediaItem(
      id: episode.id,
      title: episode.title,
      album: feed?.title,
      artist: feed?.author,
      duration: episode.durationMs == null
          ? null
          : Duration(milliseconds: episode.durationMs!),
      artUri: Uri.tryParse(episode.imageUrl ?? feed?.imageUrl ?? ''),
      displayDescription: episode.description,
      playable: true,
      extras: {'feedId': episode.feedId, 'explicit': episode.explicit},
    );
  }

  Future<void> _restoreQueue() async {
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
    queue.add(items);
  }

  Future<void> reloadQueueFromDatabase() {
    return _serializeQueueOperation(() async {
      await _restoreQueue();
      _broadcastState();
    });
  }

  Future<void> reloadSettingsFromDatabase() async {
    _speedPercent = await _settings.speed();
    final player = _player;
    if (player != null) {
      await player.setSpeed(_speedPercent / 100);
    }
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
      mediaItem.add(null);
    }
    queue.add(
      queue.value
          .where((item) => !removed.contains(item.id))
          .toList(growable: false),
    );
    await _persistQueue();
    _broadcastState();
  }

  Future<void> _persistQueue() {
    final now = DateTime.now().toUtc();
    final entries = <QueueEntriesCompanion>[
      for (var index = 0; index < queue.value.length; index++)
        QueueEntriesCompanion.insert(
          id: _uuid.v4(),
          episodeId: queue.value[index].id,
          sortKey: index * 1024,
          addedAt: now,
        ),
    ];
    return _serializeQueueOperation(() async {
      await _database.batch((batch) {
        batch.deleteAll(_database.queueEntries);
        if (entries.isNotEmpty) {
          batch.insertAll(_database.queueEntries, entries);
        }
      });
    });
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
    _setPlayIntent(loadGeneration, requested: true);
    if (_isLoadPending(loadGeneration)) return;
    await _playCurrent(
      interruptionResumeGeneration: generation,
      expectedLoadGeneration: loadGeneration,
    );
  }

  bool _isLoadPending(int generation) =>
      generation == _loadGeneration && _pendingLoadGeneration == generation;

  bool _isPlayRequested(int generation) =>
      _playIntentGeneration == generation && _playRequested;

  bool _canActivatePlayback(int generation, int? interruptionResumeGeneration) {
    return !_disposed &&
        generation == _loadGeneration &&
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
    _currentItemStarted = false;
    _checkpointTimer?.cancel();
    _processingState = AudioProcessingState.error;
    _broadcastState(playing: false);
    final player = _player;
    if (player != null) _runDetached(player.pause());
    final session = _session;
    if (session != null) {
      _runDetached(() async {
        await session.setActive(false);
      }());
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('Audio handler has been disposed.');
  }

  void _broadcastState({bool? playing}) {
    if (_disposed) return;
    final isPlaying = _processingState == AudioProcessingState.error
        ? false
        : playing ?? _player?.playing ?? false;
    final controls = <MediaControl>[
      MediaControl.rewind,
      isPlaying ? MediaControl.pause : MediaControl.play,
      MediaControl.fastForward,
      MediaControl.skipToNext,
    ];
    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        androidCompactActionIndices: const [0, 1, 3],
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
        queueIndex: _currentQueueIndex(queue.value),
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
    try {
      await _persistProgress();
    } on Object {
      // Persistence failure must not leak native playback resources.
    }
    _checkpointTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepStatusTicker?.cancel();
    final initialization = _initialization;
    if (initialization != null) {
      try {
        await initialization;
      } on Object {
        // Initialization observes disposal and releases any partial player.
      }
    }
    try {
      await _loadTail;
    } on Object {
      // A failed load does not prevent its player resources being released.
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
      await _queueOperationTail;
    } on Object {
      // The handler can still finish disposal if the final queue write failed.
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
    }
  }
}
