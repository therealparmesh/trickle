import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:drift/drift.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:just_audio/just_audio.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
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

final class TrickleAudioHandler extends BaseAudioHandler with SeekHandler {
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
    BaseCacheManager? artworkCache,
    Stream<AudioInterruptionEvent>? interruptionEvents,
  }) : _database = database,
       _settings = settings,
       _sourceResolver = sourceResolver,
       _artworkCache = artworkCache,
       _interruptionEvents = interruptionEvents;

  final AppDatabase _database;
  final SettingsRepository _settings;
  final PlaybackSourceResolver _sourceResolver;
  final BaseCacheManager? _artworkCache;
  final Stream<AudioInterruptionEvent>? _interruptionEvents;
  AudioPlayer? _player;
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
  Timer? _androidInterruptionTimer;
  Timer? _sleepTimer;
  Timer? _sleepStatusTicker;
  bool _sleepAtEnd = false;
  double _sleepVolume = 1;
  SleepTimerStatus _sleepStatus = const SleepTimerStatus.off();
  int _sleepGeneration = 0;
  int _interruptionResumeGeneration = 0;
  int? _pendingInterruptionResumeGeneration;
  Future<void> _interruptionPause = Future<void>.value();
  bool _duckedForInterruption = false;
  final Set<String> _completionsInFlight = {};
  Future<void> _completionTail = Future<void>.value();
  String? _loadedEpisodeId;
  bool _repeatOne = false;
  int _speedPercent = AppConstants.defaultSpeed;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  AudioProcessingState _processingState = AudioProcessingState.idle;
  int _currentOutroSkipMs = 0;
  bool _disposed = false;
  bool _restoringLibrary = false;
  Future<void> _playerOperationTail = Future<void>.value();
  Future<void> _queueOperationTail = Future<void>.value();
  Future<void> _progressOperationTail = Future<void>.value();
  Future<void> _sessionOperationTail = Future<void>.value();
  ({int generation, int transport, Future<void> future})? _playbackRecovery;
  Map<String, int> _queueIndexes = const {};
  int _playbackResolutionGeneration = 0;
  int _episodeSelectionGeneration = 0;
  String? _pendingEpisodeSelectionId;
  int _loadGeneration = 0;
  Completer<void>? _cancelNativeLoad;
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

  bool get _loadingMedia => _pendingLoadEpisodeId != null;

  bool get _hasCurrentSource =>
      !_disposed &&
      _loadedEpisodeId != null &&
      _loadedEpisodeId == mediaItem.value?.id;

  Stream<SleepTimerStatus> get sleepTimerStatusStream async* {
    yield _sleepStatus;
    yield* _sleepStatusEvents.stream;
  }

  Stream<int> get mediaPlaybackIntentStream =>
      _mediaPlaybackIntentEvents.stream;

  Future<void> restoreLastPlayback() async {
    if (mediaItem.value != null || _disposed) return;
    final intent = _mediaIntentRevision;
    final rows =
        await (_database.select(_database.playbackProgresses).join([
                innerJoin(
                  _database.episodes,
                  _database.episodes.id.equalsExp(
                    _database.playbackProgresses.episodeId,
                  ),
                ),
                innerJoin(
                  _database.feeds,
                  _database.feeds.id.equalsExp(_database.episodes.feedId),
                ),
              ])
              ..where(
                _database.playbackProgresses.completed.equals(false) &
                    _database.playbackProgresses.positionMs.isBiggerThanValue(
                      0,
                    ) &
                    _database.episodes.played.equals(false),
              )
              ..orderBy([
                OrderingTerm.desc(_database.playbackProgresses.updatedAt),
                OrderingTerm.asc(_database.episodes.id),
              ])
              ..limit(1))
            .get();
    if (_disposed ||
        intent != _mediaIntentRevision ||
        mediaItem.value != null ||
        rows.isEmpty) {
      return;
    }
    final row = rows.single;
    final episode = row.readTable(_database.episodes);
    final feed = row.readTable(_database.feeds);
    final progress = row.readTable(_database.playbackProgresses);
    mediaItem.add(
      _mediaItem(
        episode,
        feed,
        standalone: feed.kind != FeedKind.podcast.index,
      ),
    );
    _position = Duration(milliseconds: progress.positionMs);
    _duration = Duration(
      milliseconds: progress.durationMs ?? episode.durationMs ?? 0,
    );
    _positionEvents.add(_position);
    _durationEvents.add(_duration);
    _processingState = AudioProcessingState.idle;
    _broadcastState(playing: false);
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
        cacheManager: _artworkCache,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.parmscript.trickle.playback',
          androidNotificationChannelName: 'Playback',
          androidNotificationIcon: 'drawable/ic_stat_trickle',
          androidNotificationOngoing: true,
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
      await _serializePlayerOperation(() async {
        final speed = await _settings.speed();
        _throwIfDisposed();
        _speedPercent = speed;
        _player = player;
        _session = session;
      });
      _throwIfDisposed();
      _subscriptions.addAll([
        player.playingStream.listen((_) {
          if (!_hasCurrentSource) return;
          final playing = player.playing;
          if (playing) {
            _currentItemStarted = true;
            _androidInterruptionTimer?.cancel();
            _playbackRecoveryTimer?.cancel();
            _startCheckpointing();
          } else {
            _checkpointTimer?.cancel();
            _schedulePlaybackRecovery();
          }
          _broadcastState(playing: playing);
        }),
        player.positionStream.listen((_) {
          if (!_hasCurrentSource ||
              player.processingState == ProcessingState.idle) {
            return;
          }
          final position = player.position;
          _position = position;
          _positionEvents.add(position);
          if (player.playing &&
              shouldHandleOutroSkip(
                playbackStarted: _currentItemStarted,
                position: position,
                duration: _effectiveDuration,
                outro: Duration(milliseconds: _currentOutroSkipMs),
              )) {
            _handleCompletion();
          }
        }),
        player.durationStream.listen((_) {
          if (!_hasCurrentSource) return;
          _updateNativeDuration(player.duration);
          _broadcastState();
        }),
        player.bufferedPositionStream.listen((_) {
          if (!_hasCurrentSource) return;
          _buffered = player.playbackEvent.bufferedPosition;
          _broadcastState();
        }),
        player.processingStateStream.listen((_) {
          if (!_hasCurrentSource) return;
          final state = player.processingState;
          if (state == ProcessingState.idle) {
            _checkpointTimer?.cancel();
            _schedulePlaybackRecovery();
          }
          _processingState = switch (state) {
            ProcessingState.idle => _processingState,
            ProcessingState.loading => AudioProcessingState.loading,
            ProcessingState.buffering => AudioProcessingState.buffering,
            ProcessingState.ready => AudioProcessingState.ready,
            ProcessingState.completed => AudioProcessingState.completed,
          };
          final position = player.position;
          if (shouldHandlePlayerCompletion(
            completed: state == ProcessingState.completed,
            playbackStarted: _currentItemStarted,
            position: position,
            duration: _effectiveDuration,
          )) {
            _handleCompletion(position: position);
          }
          _broadcastState();
        }),
        player.errorStream.listen((_) {
          // Load failures are handled by setUrl/setFilePath's returned future.
          if (_hasCurrentSource && _webVideoIntentRevision == null) {
            _setPlaybackError();
          }
        }),
        (_interruptionEvents ?? session.interruptionEventStream).listen((
          event,
        ) {
          if (event.begin) {
            switch (event.type) {
              case AudioInterruptionType.duck:
                _duckedForInterruption = true;
                _runDetached(_applyPodcastVolume());
              case AudioInterruptionType.pause || AudioInterruptionType.unknown:
                // iOS reports an unknown begin event. The end event tells us
                // whether playback may resume.
                final permanentLoss =
                    defaultTargetPlatform == TargetPlatform.android &&
                    event.type == AudioInterruptionType.unknown;
                final shouldResume =
                    !permanentLoss &&
                    _webVideoIntentRevision == null &&
                    (_pendingInterruptionResumeGeneration != null ||
                        _isPlayRequested(_loadGeneration));
                if (shouldResume) {
                  _pendingInterruptionResumeGeneration =
                      ++_interruptionResumeGeneration;
                  _holdAndroidServiceDuringInterruption();
                } else {
                  _cancelPendingInterruptionResume();
                }
                _interruptionPause = _pauseCurrent().catchError((Object _) {});
            }
          } else {
            if (_duckedForInterruption) {
              _duckedForInterruption = false;
              _runDetached(_applyPodcastVolume());
            }
            final resumeGeneration = event.type == AudioInterruptionType.pause
                ? _pendingInterruptionResumeGeneration
                : null;
            _pendingInterruptionResumeGeneration = null;
            if (resumeGeneration != null) {
              _runDetached(_resumeAfterInterruption(resumeGeneration));
            } else if (event.type != AudioInterruptionType.duck &&
                _androidInterruptionTimer?.isActive == true) {
              _cancelPendingInterruptionResume();
              _broadcastState();
            }
          }
        }),
        session.becomingNoisyEventStream.listen((_) {
          _runDetached(pause());
        }),
      ]);
    } on Object {
      if (identical(_player, player)) _player = null;
      _session = null;
      await player.dispose();
      rethrow;
    }
  }

  void _updateNativeDuration(Duration? duration) {
    if (duration == null || duration <= Duration.zero) return;
    if (_duration != duration) {
      _duration = duration;
      _durationEvents.add(duration);
    }
    final current = mediaItem.value;
    if (current == null || current.duration == duration) return;
    final updated = current.copyWith(duration: duration);
    mediaItem.add(updated);
    final index = _queueIndexes[updated.id];
    if (index != null) {
      final items = [...queue.value];
      items[index] = updated;
      _publishQueue(items);
    }
  }

  int beginWebVideoPlayback() {
    _cancelPendingInterruptionResume();
    _episodeSelectionGeneration++;
    _pendingEpisodeSelectionId = null;
    _clearLoadPlaybackIntent();
    _disarmPlaybackRecovery();
    _invalidateLoad();
    _transportRevision++;
    final intent = ++_mediaIntentRevision;
    _webVideoIntentRevision = intent;
    _broadcastState();
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

  Future<void> endWebVideoPlayback(
    int intent, {
    bool cancelPendingPlayback = false,
  }) async {
    if (!isWebVideoPlaybackCurrent(intent)) return;
    if (cancelPendingPlayback) _playbackResolutionGeneration++;
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

  /// Previews and feed attachments need a library episode ID. Keep the
  /// current source until that succeeds, and discard superseded requests.
  Future<void> playPreviewEpisode(
    Future<String?> Function() cacheEpisode, {
    bool standalone = false,
  }) => _playAfterResolving(
    cacheEpisode,
    (episodeId) =>
        standalone ? _playStandaloneEpisode(episodeId) : playEpisode(episodeId),
  );

  Future<void> playVideoAfterResolving(
    Future<Uri?> Function() resolve,
    bool Function(int intent, Uri uri) open,
  ) => _playAfterResolving(resolve, (uri) async {
    final intent = beginWebVideoPlayback();
    var opened = false;
    try {
      if (await prepareWebVideoPlayback(intent)) {
        opened = open(intent, uri);
      }
    } finally {
      if (!opened) await endWebVideoPlayback(intent).catchError((Object _) {});
    }
  });

  Future<void> _playAfterResolving<T>(
    Future<T?> Function() resolve,
    Future<void> Function(T) play,
  ) async {
    _throwIfDisposed();
    _requireLibraryReady();
    final generation = ++_playbackResolutionGeneration;
    final transport = _transportRevision;
    bool isCurrent() =>
        !_disposed &&
        generation == _playbackResolutionGeneration &&
        transport == _transportRevision;
    final T? source;
    try {
      source = await resolve();
    } on Object {
      if (isCurrent()) rethrow;
      return;
    }
    if (source != null && isCurrent()) await play(source);
  }

  Future<void> playEpisode(String episodeId) async {
    final intent = _beginAudioPlaybackIntent();
    final generation = ++_episodeSelectionGeneration;
    _pendingEpisodeSelectionId = episodeId;
    bool isCurrent() =>
        generation == _episodeSelectionGeneration &&
        _isAudioPlaybackIntentCurrent(intent);
    try {
      final item = await _serializeQueueOperation(() async {
        if (!isCurrent()) return null;
        await _persistProgress();
        final item = await _mediaItemForEpisode(episodeId);
        if (item == null || !isCurrent()) return null;
        final items = [...queue.value]
          ..removeWhere((candidate) => candidate.id == episodeId);
        final currentIndex = _currentQueueIndex(items);
        items.insert(math.max(currentIndex, 0), item);
        await _writeQueue(items);
        return item;
      });
      if (item == null ||
          !isCurrent() ||
          !_queueIndexes.containsKey(episodeId)) {
        return;
      }
      await _load(item, autoPlay: true);
    } finally {
      if (generation == _episodeSelectionGeneration) {
        _pendingEpisodeSelectionId = null;
      }
    }
  }

  Future<void> _playStandaloneEpisode(String episodeId) async {
    final intent = _beginAudioPlaybackIntent();
    final generation = ++_episodeSelectionGeneration;
    _pendingEpisodeSelectionId = episodeId;
    try {
      await _persistProgress();
      final item = await _mediaItemForEpisode(episodeId, standalone: true);
      if (item == null ||
          generation != _episodeSelectionGeneration ||
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

  Future<void> playNextEpisode(String episodeId) async {
    _requireLibraryReady();
    await _serializeQueueOperation(() async {
      final item = await _mediaItemForEpisode(episodeId);
      if (item == null) return;
      final items = [...queue.value]
        ..removeWhere((entry) => entry.id == episodeId);
      items.insert(_currentQueueIndex(items) + 1, item);
      await _writeQueue(items);
    });
  }

  Future<void> addEpisodeToQueue(String episodeId) async {
    _requireLibraryReady();
    await _serializeQueueOperation(() async {
      if (_queueIndexes.containsKey(episodeId)) return;
      final item = await _mediaItemForEpisode(episodeId);
      if (item != null) await _writeQueue([...queue.value, item]);
    });
  }

  @override
  Future<void> play() async {
    if (!_loadingMedia &&
        !_isPlayRequested(_loadGeneration) &&
        _completionsInFlight.contains(mediaItem.value?.id)) {
      final transport = _transportRevision;
      await _completionTail;
      if (_disposed || transport != _transportRevision) return;
    }
    if (_hasCurrentSource &&
        _player?.playing == true &&
        _player?.processingState != ProcessingState.idle &&
        _isPlayRequested(_loadGeneration) &&
        _pendingEpisodeSelectionId == null) {
      _playbackResolutionGeneration++;
      return;
    }
    final intent = _beginAudioPlaybackIntent();
    if (mediaItem.value == null && queue.value.isEmpty) {
      await reloadQueueFromDatabase();
      if (!_isAudioPlaybackIntentCurrent(intent)) return;
    }
    final generation = _loadGeneration;
    _armPlaybackRecovery();
    _setPlayIntent(generation, requested: true);
    if (_loadingMedia) return;
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
    if (!_hasCurrentSource) {
      if (interruptionResumeGeneration == null) {
        await _load(current, autoPlay: true);
      }
      return;
    }
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
    if (!_canActivatePlayback(
      expectedLoadGeneration,
      expectedTransportRevision,
      interruptionResumeGeneration,
    )) {
      return;
    }
    if (!activated || _player?.processingState == ProcessingState.idle) {
      await recoverPlaybackIfNeeded();
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
        _startPlayer(
          _player!,
          expectedLoadGeneration,
          expectedTransportRevision,
        );
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
    if (_loadingMedia) {
      _broadcastState();
      return;
    }
    final player = _player;
    if (player == null) return;
    final transport = _transportRevision;
    final generation = _loadGeneration;
    await _serializePlayerOperation(player.pause);
    if (_disposed ||
        transport != _transportRevision ||
        generation != _loadGeneration) {
      return;
    }
    if (_hasCurrentSource && player.processingState != ProcessingState.idle) {
      _position = player.position;
    }
    _broadcastState();
    await _persistProgress();
  }

  @override
  Future<void> stop() => _stop();

  Future<void> _stop({bool checkpoint = true}) async {
    _cancelPendingInterruptionResume();
    final progress = checkpoint ? _persistProgress() : _progressOperationTail;
    _loadedEpisodeId = null;
    _buffered = Duration.zero;
    _checkpointTimer?.cancel();
    final transport = ++_transportRevision;
    _episodeSelectionGeneration++;
    _pendingEpisodeSelectionId = null;
    _clearLoadPlaybackIntent();
    _disarmPlaybackRecovery();
    _invalidateLoad();
    _currentItemStarted = false;
    await _serializePlayerOperation(() async => _player?.stop());
    try {
      await progress;
    } on Object {
      // Stopping playback must not depend on a successful checkpoint.
    }
    if (transport != _transportRevision) return;
    _runDetached(setSleepTimer(null));
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
    if (_loadingMedia) return;
    final duration = _effectiveDuration;
    final safe = position < Duration.zero
        ? Duration.zero
        : duration > Duration.zero && position > duration
        ? duration
        : position;
    if (!_hasCurrentSource) {
      _position = safe;
      _positionEvents.add(safe);
      _broadcastState();
      await _persistProgress(allowZero: true);
      return;
    }
    await initialize();
    if (generation != _loadGeneration ||
        !_hasCurrentSource ||
        mediaItem.value?.id != episodeId) {
      return;
    }
    await _serializePlayerOperation(() async {
      if (generation != _loadGeneration ||
          !_hasCurrentSource ||
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
    await _persistProgress(allowZero: true);
  }

  @override
  Future<void> rewind() => seek(_position - AppConstants.rewind);

  @override
  Future<void> fastForward() => seek(_position + AppConstants.forward);

  @override
  Future<void> skipToPrevious() async {
    if (_position > AppConstants.playbackPositionThreshold) {
      await seek(Duration.zero);
      return;
    }
    final items = queue.value;
    final index = _currentQueueIndex(items);
    if (index > 0) {
      await playQueuedEpisode(items[index - 1].id, markPlayedIfNearEnd: false);
      return;
    }
    await seek(Duration.zero);
  }

  @override
  Future<void> skipToNext() async {
    final items = queue.value;
    final index = _currentQueueIndex(items);
    if (index < 0 || index + 1 >= items.length) {
      return;
    }
    await playQueuedEpisode(items[index + 1].id);
  }

  @override
  Future<void> skipToQueueItem(int index) {
    final items = queue.value;
    if (index < 0 || index >= items.length) return Future<void>.value();
    return playQueuedEpisode(items[index].id);
  }

  Future<void> playQueuedEpisode(
    String episodeId, {
    bool markPlayedIfNearEnd = true,
  }) async {
    if (!_queueIndexes.containsKey(episodeId) ||
        mediaItem.value?.id == episodeId) {
      return;
    }
    final intent = _beginAudioPlaybackIntent();
    final generation = ++_episodeSelectionGeneration;
    _pendingEpisodeSelectionId = episodeId;
    try {
      await _persistProgress(markPlayedIfNearEnd: markPlayedIfNearEnd);
      if (generation != _episodeSelectionGeneration ||
          !_isAudioPlaybackIntentCurrent(intent)) {
        return;
      }
      final index = _queueIndexes[episodeId];
      if (index != null) await _load(queue.value[index], autoPlay: true);
    } finally {
      if (generation == _episodeSelectionGeneration) {
        _pendingEpisodeSelectionId = null;
      }
    }
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    _requireLibraryReady();
    await _serializeQueueOperation(() async {
      if (_queueIndexes.containsKey(mediaItem.id)) return;
      await _writeQueue([...queue.value, mediaItem]);
    });
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    _requireLibraryReady();
    final intent = (media: _mediaIntentRevision, transport: _transportRevision);
    final oldIndex = await _serializeQueueOperation(() async {
      final index = _queueIndexes[mediaItem.id];
      if (index != null) await _writeQueue([...queue.value]..removeAt(index));
      return index;
    });
    if (oldIndex == null || !_playbackIntentMatchesItem(mediaItem.id, intent)) {
      return;
    }
    await _persistProgress();
    if (!_playbackIntentMatchesItem(mediaItem.id, intent)) return;
    final items = queue.value;
    if (items.isEmpty) {
      await stop();
    } else {
      await _load(
        items[oldIndex.clamp(0, items.length - 1)],
        autoPlay: playbackState.value.playing,
      );
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    _requireLibraryReady();
    final seen = <String>{};
    final items = queue.where((item) => seen.add(item.id)).toList();
    await _serializeQueueOperation(() => _writeQueue(items));
  }

  Future<void> reorderQueue(List<MediaItem> displayed, int from, int to) async {
    _requireLibraryReady();
    await _serializeQueueOperation(() async {
      final current = queue.value;
      if (from == to || !sameQueueOrder(displayed, current)) return;
      final items = [...current];
      items.insert(to, items.removeAt(from));
      await _writeQueue(items);
    });
  }

  static bool sameQueueOrder(List<MediaItem>? first, List<MediaItem>? second) {
    if (identical(first, second)) return true;
    if (first == null || second == null || first.length != second.length) {
      return false;
    }
    for (var i = 0; i < first.length; i++) {
      if (first[i].id != second[i].id) return false;
    }
    return true;
  }

  Future<void> clearQueue() async {
    _requireLibraryReady();
    final transport = _transportRevision;
    await _serializeQueueOperation(() => _writeQueue([], clearPending: true));
    if (transport == _transportRevision) await stop();
  }

  @override
  Future<void> setSpeed(double speed) async {
    final scaled = speed * 100;
    if (!scaled.isFinite) return;
    final percent = scaled.round();
    if (!AppConstants.allowedSpeeds.contains(percent)) return;
    _requireLibraryReady();
    await _serializePlayerOperation(() async {
      _throwIfDisposed();
      final player = _player;
      try {
        await player?.setSpeed(percent / 100);
        await _settings.setSpeed(percent);
      } on Object {
        try {
          // just_audio updates its own speed before the native call returns.
          await player?.setSpeed(_speedPercent / 100);
        } on Object {
          // Keep the original error and the last saved preference.
        }
        rethrow;
      }
      _speedPercent = percent;
      _broadcastState();
    });
  }

  Future<void> setSleepTimer(
    Duration? duration, {
    bool endOfEpisode = false,
  }) async {
    _sleepTimer?.cancel();
    final generation = ++_sleepGeneration;
    _sleepAtEnd = duration == null && endOfEpisode;
    final restoreVolume = _sleepVolume != 1;
    _sleepVolume = 1;
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
    if (restoreVolume) await _applyPodcastVolume();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeatOne = repeatMode == AudioServiceRepeatMode.one;
    _broadcastState();
  }

  Future<void> _markEpisodePlayed(
    String id, {
    required Duration position,
    required Duration duration,
  }) async {
    final completedDuration = completedProgressDuration(
      position: position,
      knownDuration: duration,
    );
    final updated =
        await (_database.update(_database.episodes)
              ..where((row) => row.id.equals(id)))
            .write(const EpisodesCompanion(played: Value(true)));
    if (updated == 0) return;
    final now = DateTime.now().toUtc();
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
  }

  Future<void> setEpisodePlayed(String episodeId, bool played) async {
    _requireLibraryReady();
    final currentDuration = mediaItem.value?.id == episodeId
        ? _effectiveDuration
        : Duration.zero;
    if (mediaItem.value?.id == episodeId) {
      final generation = _episodeSelectionGeneration + 1;
      await stop();
      if (generation == _episodeSelectionGeneration &&
          mediaItem.value?.id == episodeId) {
        mediaItem.add(null);
      }
    }
    _requireLibraryReady();
    final episodeFound = await _serializeProgressOperation(
      () => _database.transaction(() async {
        final episode = await _database.episodeById(episodeId);
        if (episode == null) return false;
        final now = DateTime.now().toUtc();
        final durationMs = currentDuration > Duration.zero
            ? currentDuration.inMilliseconds
            : episode.durationMs;
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
        return true;
      }),
    );
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
    final generation = _invalidateLoad();
    // just_audio retains its old source and may emit updates until the new
    // source finishes loading, even after pause or stop.
    _loadedEpisodeId = null;
    _checkpointTimer?.cancel();
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
      _broadcastState();
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
      final nativeDuration = await _serializePlayerOperation<Duration?>(
        () async {
          if (generation != _loadGeneration || _disposed) return null;
          final player = _player!;
          final cancelled = Completer<void>();
          _cancelNativeLoad = cancelled;

          Future<Duration?> prepare() async {
            final duration = source.isLocal
                ? await player.setFilePath(source.resource)
                : await player.setUrl(
                    source.resource,
                    headers: source.headers.isEmpty ? null : source.headers,
                  );
            if (cancelled.isCompleted) return null;
            await player.setSpeed(_speedPercent / 100);
            if (cancelled.isCompleted) return null;
            final effectiveDuration = effectivePlaybackDuration(
              nativeDuration: duration ?? Duration.zero,
              fallbackDuration: (item.duration ?? Duration.zero) > Duration.zero
                  ? item.duration
                  : Duration(milliseconds: progress?.durationMs ?? 0),
            );
            if (progress != null &&
                progress.positionMs > 0 &&
                !progress.completed &&
                !episode.played &&
                (effectiveDuration <= Duration.zero ||
                    progress.positionMs < effectiveDuration.inMilliseconds)) {
              await player.seek(Duration(milliseconds: progress.positionMs));
            } else {
              final intro = Duration(milliseconds: feed?.introSkipMs ?? 0);
              if (intro > Duration.zero &&
                  (effectiveDuration <= Duration.zero ||
                      intro < effectiveDuration)) {
                await player.seek(intro);
              }
            }
            return duration;
          }

          try {
            return await Future.any<Duration?>([
              prepare(),
              cancelled.future.then((_) => null),
            ]).timeout(AppConstants.audioSourceLoadTimeout);
          } on TimeoutException {
            if (!cancelled.isCompleted) cancelled.complete();
            rethrow;
          } finally {
            _cancelNativeLoad = null;
            if (cancelled.isCompleted) {
              // Reset just_audio's playlist before the next transport command.
              await player.setAudioSources(const [], preload: false);
            }
          }
        },
      );
      if (generation != _loadGeneration) return;
      _pendingLoadEpisodeId = null;
      _loadedEpisodeId = item.id;
      _processingState = AudioProcessingState.ready;
      final player = _player!;
      _position = player.position;
      _buffered = player.playbackEvent.bufferedPosition;
      _positionEvents.add(_position);
      _updateNativeDuration(player.duration ?? nativeDuration);
      if (_isPlayRequested(generation)) {
        await _playCurrent(
          expectedLoadGeneration: generation,
          expectedTransportRevision: _transportRevision,
        );
      }
      _broadcastState();
    } on Object {
      if (_disposed || generation != _loadGeneration) return;
      _pendingLoadEpisodeId = null;
      _setPlaybackError();
      rethrow;
    }
  }

  void _handleCompletion({Duration? position}) {
    final item = mediaItem.value;
    if (item == null || !_completionsInFlight.add(item.id)) return;
    final media = _mediaIntentRevision;
    final finalPosition = position ?? _position;
    final duration = _effectiveDuration;
    final generation = _loadGeneration;
    // Pause changes transport intent without replacing the finished episode.
    bool isCurrent() =>
        _hasCurrentSource &&
        generation == _loadGeneration &&
        _mediaIntentRevision == media &&
        _webVideoIntentRevision == null;
    _completionTail = _completionTail.then((_) async {
      try {
        await _completeEpisode(
          item,
          isCurrent: isCurrent,
          position: finalPosition,
          duration: duration,
        );
      } on Object {
        if (isCurrent()) {
          // Retry from the last saved position, not the failed checkpoint at
          // the end of the episode. Do not interrupt a newer selection.
          _setPlaybackError(checkpoint: false);
        }
      } finally {
        _completionsInFlight.remove(item.id);
      }
    });
  }

  Future<void> _completeEpisode(
    MediaItem completed, {
    required bool Function() isCurrent,
    required Duration position,
    required Duration duration,
  }) async {
    // Keep the end-of-episode decision here so native looping cannot bypass
    // the sleep timer or auto-remove the file while it is being repeated.
    if (_repeatOne &&
        !_sleepAtEnd &&
        isCurrent() &&
        _isPlayRequested(_loadGeneration)) {
      await seekEpisode(completed.id, Duration.zero);
      if (isCurrent() &&
          _isPlayRequested(_loadGeneration) &&
          _player?.playing != true) {
        await _playCurrent(
          expectedLoadGeneration: _loadGeneration,
          expectedTransportRevision: _transportRevision,
        );
      }
      return;
    }
    final standalone = completed.extras?['standalone'] == true;
    final completedIndex = await _serializeQueueOperation(() async {
      final index = _queueIndexes[completed.id];
      final rows = await _serializeProgressOperation(
        () => _database.transaction(() async {
          await _markEpisodePlayed(
            completed.id,
            position: position,
            duration: duration,
          );
          if (standalone) return null;
          await _database.removeFinishedQueueEpisode(completed.id);
          return _database.loadQueue();
        }),
      );
      if (rows != null) {
        _publishStoredQueue(rows);
        _broadcastState();
      }
      return index;
    });
    customEvent.add({'type': 'completed', 'episodeId': completed.id});

    if (!isCurrent()) return;
    final stopAtEnd = _sleepAtEnd;
    if (stopAtEnd) {
      _sleepAtEnd = false;
      _setSleepStatus(const SleepTimerStatus.off());
    }
    final items = queue.value;
    if (standalone ||
        stopAtEnd ||
        items.isEmpty ||
        !_isPlayRequested(_loadGeneration)) {
      await _finishCompletedEpisode(isCurrent);
      return;
    }
    final nextIndex = completedIndex == null || completedIndex >= items.length
        ? 0
        : completedIndex;
    await _load(items[nextIndex], autoPlay: true);
  }

  bool _playbackIntentMatchesItem(
    String episodeId,
    ({int media, int transport}) intent,
  ) =>
      mediaItem.value?.id == episodeId &&
      (_pendingEpisodeSelectionId ?? _pendingLoadEpisodeId ?? episodeId) ==
          episodeId &&
      _isAudioPlaybackIntentCurrent(intent);

  Future<void> _finishCompletedEpisode(bool Function() isCurrent) async {
    final media = _mediaIntentRevision;
    _disarmPlaybackRecovery();
    _setPlayIntent(_loadGeneration, requested: false);
    await _serializePlayerOperation(() async {
      if (isCurrent()) await _player?.pause();
    });
    if (!isCurrent()) return;
    _currentItemStarted = false;
    mediaItem.add(null);
    _processingState = AudioProcessingState.completed;
    _broadcastState(playing: false);
    await _setPodcastSessionActive(false, expectedMediaIntent: media);
  }

  Future<void> _fadeAndPause(int generation) async {
    bool isCurrent() => !_disposed && generation == _sleepGeneration;
    try {
      if (!isCurrent() || _webVideoIntentRevision != null) return;
      if (_player != null) {
        for (var step = AppConstants.sleepFadeSteps - 1; step >= 0; step--) {
          await Future<void>.delayed(AppConstants.sleepFadeStepInterval);
          if (!isCurrent() || _webVideoIntentRevision != null) return;
          _sleepVolume = step / AppConstants.sleepFadeSteps;
          try {
            await _applyPodcastVolume();
          } on Object {
            // A native volume error must not prevent the scheduled pause.
          }
        }
      }
      // The last native volume call may have been in flight when the user
      // canceled or replaced the timer.
      if (isCurrent() && _webVideoIntentRevision == null) {
        await pause();
      }
    } finally {
      if (isCurrent()) await setSleepTimer(null);
    }
  }

  Future<void> _applyPodcastVolume() => _serializePlayerOperation(() async {
    if (!_disposed) {
      await _player?.setVolume(
        _sleepVolume * (_duckedForInterruption ? 0.3 : 1),
      );
    }
  });

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

  Future<void> _persistProgress({
    bool markPlayedIfNearEnd = false,
    bool allowZero = false,
  }) {
    final id = mediaItem.value?.id;
    if (id == null ||
        _loadingMedia ||
        (!allowZero && _completionsInFlight.contains(id)) ||
        _processingState == AudioProcessingState.error) {
      return Future<void>.value();
    }
    final position = _position;
    if (position == Duration.zero && !_currentItemStarted && !allowZero) {
      return Future<void>.value();
    }
    final duration = _effectiveDuration;
    final startedSource = _hasCurrentSource && _currentItemStarted;
    return _serializeProgressOperation(() async {
      final newlyCompleted = await _database.transaction(() async {
        final episode = await _database.episodeById(id);
        if (episode == null) return false;
        final existing = await (_database.select(
          _database.playbackProgresses,
        )..where((row) => row.episodeId.equals(id))).getSingleOrNull();
        final wasCompleted = episode.played || existing?.completed == true;
        final nearEnd = isPlaybackComplete(position, duration);
        // Keep the old completion until a replay has a usable checkpoint.
        if (wasCompleted &&
            (!startedSource ||
                position < AppConstants.playbackPositionThreshold ||
                nearEnd)) {
          return false;
        }
        final completed = markPlayedIfNearEnd && nearEnd;
        final now = DateTime.now().toUtc();
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
                completedAt: Value(completed ? now : null),
                updatedAt: now,
              ),
            );
        if (episode.played != completed) {
          await (_database.update(_database.episodes)
                ..where((row) => row.id.equals(id)))
              .write(EpisodesCompanion(played: Value(completed)));
        }
        return completed;
      });
      if (newlyCompleted) {
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

  Future<MediaItem?> _mediaItemForEpisode(
    String episodeId, {
    bool standalone = false,
  }) async {
    final episodes = _database.episodes;
    final feeds = _database.feeds;
    final row = await (_database.select(episodes).join([
      innerJoin(feeds, feeds.id.equalsExp(episodes.feedId)),
    ])..where(episodes.id.equals(episodeId))).getSingleOrNull();
    if (row == null) return null;
    return _mediaItem(
      row.readTable(episodes),
      row.readTable(feeds),
      standalone: standalone,
    );
  }

  MediaItem _mediaItem(Episode episode, Feed feed, {bool standalone = false}) {
    final artworkUrl = (episode.imageUrl ?? feed.imageUrl)?.trim();
    final artworkUri = artworkUrl == null || artworkUrl.isEmpty
        ? null
        : Uri.tryParse(artworkUrl);
    final articleId = episode.guid?.startsWith('nostr-media:') == true
        ? episode.guid!.substring('nostr-media:'.length)
        : null;
    return MediaItem(
      id: episode.id,
      title: episode.title,
      album: feed.title,
      artist: feed.author,
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
    _publishStoredQueue(await _database.loadQueue());
  }

  void _publishStoredQueue(List<(Episode, Feed)> rows) {
    _publishQueue([
      for (final (episode, feed) in rows) _mediaItem(episode, feed),
    ]);
  }

  Future<void> reloadQueueFromDatabase() {
    return _serializeQueueOperation(() async {
      await _restoreQueue();
      _broadcastState();
    });
  }

  Future<void> restoreLibrary(Future<void> Function() restore) async {
    _requireLibraryReady();
    _restoringLibrary = true;
    try {
      // Paused audio is already saved. Writing it again would give an older
      // position a newer timestamp and prevent the backup from replacing it.
      final playing = _hasCurrentSource && _player?.playing == true;
      if (playing) _position = _player!.position;
      await _stop(checkpoint: playing);
      mediaItem.add(null);
      await _completionTail;
      await _serializeQueueOperation(() async {
        await restore();
        await _restoreQueue();
        _broadcastState();
      });
      // The player is stopped; its next source load applies the restored speed.
      await _serializePlayerOperation(() async {
        final restoredSpeed = await _settings.speed();
        _throwIfDisposed();
        _speedPercent = restoredSpeed;
        _broadcastState();
      });
      await restoreLastPlayback();
    } on Object {
      try {
        await restoreLastPlayback();
      } on Object {
        // Keep the original restore error.
      }
      rethrow;
    } finally {
      _restoringLibrary = false;
    }
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
      _invalidateLoad();
    }
    try {
      if (currentId != null && removed.contains(currentId)) {
        await stop();
      }
    } finally {
      if (removed.contains(mediaItem.value?.id)) mediaItem.add(null);
      // The database already removed these entries. Rewriting Up next here
      // could discard entries the audio handler has not loaded yet.
      await _serializeQueueOperation(() async {
        _publishQueue(
          queue.value.where((item) => !removed.contains(item.id)).toList(),
        );
        _broadcastState();
      });
    }
  }

  Future<void> _writeQueue(
    List<MediaItem> items, {
    bool clearPending = false,
  }) async {
    final ids = items.map((item) => item.id).toList(growable: false);
    final existing = await _database.replaceQueue(
      ids,
      clearPending: clearPending,
    );
    _publishQueue(
      existing.length == ids.length
          ? items
          : items.where((item) => existing.contains(item.id)).toList(),
    );
    _broadcastState();
  }

  void _publishQueue(List<MediaItem> items) {
    final currentId = mediaItem.value?.id;
    if (_hasCurrentSource && _duration > Duration.zero) {
      final index = items.indexWhere((item) => item.id == currentId);
      if (index >= 0 && items[index].duration != _duration) {
        items[index] = items[index].copyWith(duration: _duration);
      }
    }
    _queueIndexes = {
      for (var index = 0; index < items.length; index++) items[index].id: index,
    };
    queue.add(items);
  }

  Future<T> _serializeQueueOperation<T>(Future<T> Function() operation) {
    final next = _queueOperationTail.then((_) => operation());
    _queueOperationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _resumeAfterInterruption(int generation) async {
    await _interruptionPause;
    if (!_resumeIsStillAllowed(generation)) return;
    final loadGeneration = _loadGeneration;
    _armPlaybackRecovery();
    _setPlayIntent(loadGeneration, requested: true);
    if (_loadingMedia) return;
    await _playCurrent(
      interruptionResumeGeneration: generation,
      expectedLoadGeneration: loadGeneration,
      expectedTransportRevision: _transportRevision,
    );
  }

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
        !_loadingMedia &&
        _isPlayRequested(generation) &&
        _resumeIsStillAllowed(interruptionResumeGeneration);
  }

  void _setPlayIntent(int generation, {required bool requested}) {
    if (generation != _loadGeneration) return;
    _playIntentGeneration = generation;
    _playRequested = requested;
  }

  void _clearLoadPlaybackIntent() {
    if (_loadingMedia) _processingState = AudioProcessingState.idle;
    _pendingLoadEpisodeId = null;
    _playIntentGeneration = null;
    _playRequested = false;
  }

  int _invalidateLoad() {
    final cancelled = _cancelNativeLoad;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    return ++_loadGeneration;
  }

  ({int media, int transport}) _beginAudioPlaybackIntent() {
    _requireLibraryReady();
    _cancelPendingInterruptionResume();
    final media = ++_mediaIntentRevision;
    _webVideoIntentRevision = null;
    final transport = ++_transportRevision;
    if (!_disposed && !_mediaPlaybackIntentEvents.isClosed) {
      _mediaPlaybackIntentEvents.add(media);
    }
    return (media: media, transport: transport);
  }

  void _requireLibraryReady() {
    if (_restoringLibrary) {
      throw const BackupException('Wait for the backup to finish restoring.');
    }
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
    final transport = _transportRevision;
    final active = _playbackRecovery;
    if (active != null &&
        active.generation == generation &&
        active.transport == transport) {
      return active.future;
    }
    final episodeId = mediaItem.value?.id;
    if (episodeId == null || !_needsPlaybackRecovery(generation, episodeId)) {
      return Future<void>.value();
    }
    final recovery = _recoverPlayback(generation, episodeId);
    _playbackRecovery = (
      generation: generation,
      transport: transport,
      future: recovery,
    );
    return recovery.whenComplete(() {
      if (identical(_playbackRecovery?.future, recovery)) {
        _playbackRecovery = null;
      }
    });
  }

  bool _needsPlaybackRecovery(int generation, String episodeId) {
    final player = _player;
    if (player == null ||
        !_hasCurrentSource ||
        generation != _loadGeneration ||
        mediaItem.value?.id != episodeId) {
      return false;
    }
    return shouldRecoverUnexpectedPlaybackStop(
      playRequested: _isPlayRequested(generation),
      playerPlaying:
          player.playing && player.processingState != ProcessingState.idle,
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
        try {
          await _persistProgress();
        } on Object {
          // Reload from the previous checkpoint if this write fails.
        }
        if (transport != _transportRevision ||
            !_needsPlaybackRecovery(generation, episodeId)) {
          return;
        }
        await _load(
          mediaItem.value!,
          autoPlay: true,
          allowPlaybackRecovery: false,
        );
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
          _startPlayer(player, generation, transport);
        }
      });
    } on Object {
      if (transport == _transportRevision &&
          !_playbackRecoveryAvailable &&
          _needsPlaybackRecovery(generation, episodeId)) {
        _setPlaybackError();
      }
      rethrow;
    }
  }

  void _startPlayer(AudioPlayer player, int generation, int transport) {
    unawaited(
      player.play().catchError((Object _) {
        // just_audio can leave `playing` true after the platform rejects Play.
        if (_canActivatePlayback(generation, transport, null)) {
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
    _androidInterruptionTimer?.cancel();
  }

  void _setPlaybackError({bool checkpoint = true}) {
    if (_disposed) return;
    if (checkpoint && _currentItemStarted) _runDetached(_persistProgress());
    final player = _player;
    if (player != null && player.playing) {
      _runDetached(_serializePlayerOperation(player.pause));
    }
    _loadedEpisodeId = null;
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

  void _holdAndroidServiceDuringInterruption() {
    if (defaultTargetPlatform != TargetPlatform.android ||
        !playbackState.value.playing ||
        _androidInterruptionTimer?.isActive == true) {
      return;
    }
    // Keep the buffering media session active until Android returns focus.
    // This avoids a foreground restart and leaves Pause available throughout.
    _androidInterruptionTimer = Timer(
      AppConstants.androidInterruptionTimeout,
      () => _runDetached(pause()),
    );
  }

  void _broadcastState({bool? playing}) {
    if (_disposed) return;
    final interrupted = _androidInterruptionTimer?.isActive == true;
    final nativePlaying =
        playing ?? (_hasCurrentSource && _player?.playing == true);
    final requested = _isPlayRequested(_loadGeneration);
    final waitingToPlay =
        requested &&
        !nativePlaying &&
        (_loadingMedia ||
            _processingState == AudioProcessingState.ready ||
            _processingState == AudioProcessingState.buffering);
    // Dropping play intent during an active handoff would demote Android's
    // media service and can prevent the next episode from starting offscreen.
    final isPlaying =
        _processingState != AudioProcessingState.error &&
        (nativePlaying ||
            interrupted ||
            (waitingToPlay && playbackState.value.playing));
    final processingState = _processingState == AudioProcessingState.error
        ? AudioProcessingState.error
        : _loadingMedia
        ? AudioProcessingState.loading
        : interrupted || waitingToPlay
        ? AudioProcessingState.buffering
        : !isPlaying &&
              !requested &&
              _processingState == AudioProcessingState.buffering
        ? AudioProcessingState.ready
        : _processingState;
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
        processingState: processingState,
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
    final progress = _persistProgress();
    _disposed = true;
    _cancelPendingInterruptionResume();
    _episodeSelectionGeneration++;
    _clearLoadPlaybackIntent();
    _invalidateLoad();
    _mediaIntentRevision++;
    _transportRevision++;
    _webVideoIntentRevision = null;
    try {
      await progress;
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
    await _interruptionPause;
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } on Object {
        // Continue releasing the remaining subscriptions and player.
      }
    }
    await _completionTail;
    await _queueOperationTail;
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
