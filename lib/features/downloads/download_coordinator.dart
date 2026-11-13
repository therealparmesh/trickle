import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/audio_file.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/playback_source_resolver.dart';
import '../../data/repositories/settings_repository.dart';

// Match the native downloader's recovery window for undelivered task updates.
const interruptedDownloadRecoveryDelay = Duration(seconds: 5);

DownloadState downloadStateForTaskStatus(TaskStatus status) => switch (status) {
  TaskStatus.enqueued => DownloadState.queued,
  TaskStatus.running || TaskStatus.waitingToRetry => DownloadState.running,
  TaskStatus.paused => DownloadState.paused,
  TaskStatus.complete => DownloadState.complete,
  TaskStatus.canceled => DownloadState.canceled,
  TaskStatus.notFound || TaskStatus.failed => DownloadState.failed,
};

bool shouldClearStoredDownloadPath({
  required String? filePath,
  required DownloadState state,
}) =>
    filePath != null &&
    (state == DownloadState.failed || state == DownloadState.canceled);

final class DownloadCoordinator {
  DownloadCoordinator({
    required AppDatabase database,
    required PlaybackSourceResolver sources,
    required SettingsRepository settings,
    FileDownloader? downloader,
    bool recoverInterruptedDownloads = true,
  }) : _database = database,
       _sources = sources,
       _settings = settings,
       _recoverInterruptedDownloads = recoverInterruptedDownloads,
       _downloader = downloader ?? FileDownloader();

  final AppDatabase _database;
  final PlaybackSourceResolver _sources;
  final SettingsRepository _settings;
  final bool _recoverInterruptedDownloads;
  final FileDownloader _downloader;
  final Uuid _uuid = const Uuid();
  final DiskSpacePlus _diskSpace = DiskSpacePlus();
  StreamSubscription<void>? _updates;
  StreamSubscription<TaskRecord>? _taskRecords;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  StreamSubscription<AutoDeletePolicy>? _autoDeleteSubscription;
  Timer? _cleanupTimer;
  Timer? _recoveryTimer;
  Future<void>? _activeRecovery;
  Future<void>? _activeCleanup;
  bool _cleanupRequested = false;
  final Map<String, DateTime> _lastProgressWrite = {};
  final Set<String> _startingDownloads = {};
  final Set<String> _terminalStateCommitted = {};
  final Set<String> _terminalRecordPersisted = {};
  Future<void>? _initialization;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final active = _initialization;
    if (active != null) return active;
    final future = _initialize();
    _initialization = future;
    try {
      await future;
    } on Object catch (error, stackTrace) {
      await _resetPartialInitialization();
      _initialization = null;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _resetPartialInitialization() async {
    await _updates?.cancel();
    await _taskRecords?.cancel();
    await _connectivity?.cancel();
    await _autoDeleteSubscription?.cancel();
    _updates = null;
    _taskRecords = null;
    _connectivity = null;
    _autoDeleteSubscription = null;
    _terminalStateCommitted.clear();
    _terminalRecordPersisted.clear();
    _initialized = false;
  }

  bool _isTerminal(TaskStatus status) {
    return status == TaskStatus.complete ||
        status == TaskStatus.notFound ||
        status == TaskStatus.failed ||
        status == TaskStatus.canceled;
  }

  Future<void> _deleteTaskRecord(String taskId) async {
    try {
      await _downloader.database.deleteRecordWithId(taskId);
      _terminalStateCommitted.remove(taskId);
      _terminalRecordPersisted.remove(taskId);
    } on Object {
      // A later startup cleanup is the fallback for transient storage errors.
    }
  }

  Future<void> _initialize() async {
    _taskRecords = _downloader.database.updates.listen((record) {
      if (record.group == 'media' && _isTerminal(record.status)) {
        _terminalRecordPersisted.add(record.taskId);
        _runDetached(_deleteCommittedTaskRecord(record.taskId));
      }
    });
    _updates = _downloader.updates
        .asyncMap((update) async {
          try {
            await _handleUpdate(update);
          } on Object {
            // Keep processing later downloader events after a transient I/O error.
          }
        })
        .listen((_) {});
    await _applyConnectivity(await Connectivity().checkConnectivity());
    // Persist terminal task state in the app database before removing the
    // downloader's durable completion record.
    await _downloader.start(doRescheduleKilledTasks: false);
    _downloader.configureNotificationForGroup(
      'media',
      running: const TaskNotification(
        'Downloading',
        '{displayName} · {progress}',
      ),
      complete: const TaskNotification('Downloaded', '{displayName}'),
      error: const TaskNotification('Download failed', '{displayName}'),
      paused: const TaskNotification('Download paused', '{displayName}'),
      progressBar: true,
      groupNotificationId: 'trickle-downloads',
    );
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      _runDetached(_applyConnectivity(results));
    });
    var reconciled = false;
    try {
      await _reconcile();
      reconciled = true;
    } on Object {
      // Records remain available for the next startup after a transient error.
    }
    _initialized = true;
    _autoDeleteSubscription = _settings.watchAutoDelete().skip(1).listen((_) {
      _runDetached(cleanupPlayed());
    });
    if (reconciled) {
      try {
        await cleanupPlayed();
      } on Object {
        // Core downloading is initialized even if optional maintenance fails.
      }
    }
    if (_recoverInterruptedDownloads) {
      // Match the downloader's startup delay so delivered native updates
      // have time to reach its tracking database before recovery.
      _recoveryTimer = Timer(interruptedDownloadRecoveryDelay, () {
        final recovery = _recoverInterruptedTasks();
        _activeRecovery = recovery;
        _runDetached(recovery);
      });
    }
  }

  Future<void> _recoverInterruptedTasks() async {
    final (restarted, failed) = await _downloader.rescheduleKilledTasks();
    for (final task in restarted) {
      if (task.group != 'media') continue;
      // A removal can finish before the downloader re-enqueues its snapshot.
      if ((await _download(task.metaData))?.taskId != task.taskId) {
        await _downloader.cancelTaskWithId(task.taskId);
        await _deleteTaskRecord(task.taskId);
      }
    }
    for (final task in failed) {
      if (task.group != 'media') continue;
      await _setState(
        task.taskId,
        DownloadState.failed,
        whileTransferring: true,
        clearProgress: true,
      );
    }
  }

  Future<void> startDownload(
    String episodeId, {
    bool automatic = false,
    Duration Function()? remainingNetworkTime,
  }) => _requestDownload(
    episodeId,
    automatic: automatic,
    remainingNetworkTime: remainingNetworkTime,
  );

  Future<void> _requestDownload(
    String episodeId, {
    bool automatic = false,
    Duration Function()? remainingNetworkTime,
    String? replacingTaskId,
  }) async {
    await _ensureInitialized();
    if (!_startingDownloads.add(episodeId)) return;
    try {
      await _startDownload(
        episodeId,
        automatic: automatic,
        remainingNetworkTime: remainingNetworkTime,
        replacingTaskId: replacingTaskId,
      );
    } finally {
      _startingDownloads.remove(episodeId);
    }
  }

  Future<void> _startDownload(
    String episodeId, {
    required bool automatic,
    required Duration Function()? remainingNetworkTime,
    required String? replacingTaskId,
  }) async {
    final episode = await _database.episodeById(episodeId);
    if (episode == null) return;
    final existing = await _download(episodeId);
    if (replacingTaskId != null && existing?.taskId != replacingTaskId) {
      return;
    }
    if (existing != null && _isActiveDownload(existing)) return;
    if (await _isUsableCompletedDownload(existing)) return;
    final enclosurePath = Uri.tryParse(
      episode.enclosureUrl,
    )?.path.toLowerCase();
    final mimeType = episode.mimeType?.toLowerCase() ?? '';
    if (enclosurePath?.endsWith('.m3u8') == true ||
        mimeType.contains('mpegurl')) {
      throw const UnsupportedDownloadException(
        'This streaming episode can be played online but can’t be downloaded.',
      );
    }
    await _ensureStorageReserve(episode.fileSize);
    final remaining =
        remainingNetworkTime?.call() ?? AppConstants.interactiveRequestTimeout;
    if (remaining <= Duration.zero) {
      throw const NetworkException('The request timed out.');
    }
    final source = await _sources.resolveRemote(
      episode,
      totalTimeout: remaining,
    );
    if (source.url.path.toLowerCase().endsWith('.m3u8')) {
      throw const UnsupportedDownloadException(
        'This streaming episode can be played online but can’t be downloaded.',
      );
    }
    final taskId = _uuid.v4();
    final task = DownloadTask(
      taskId: taskId,
      url: source.url.toString(),
      headers: source.headers,
      filename:
          '$episodeId-$taskId.${_extension(episode.mimeType, source.url)}',
      directory: downloadMediaDirectory,
      baseDirectory: BaseDirectory.applicationSupport,
      group: 'media',
      updates: Updates.statusAndProgress,
      requiresWiFi: automatic,
      retries: 3,
      allowPause: true,
      priority: automatic ? 5 : 0,
      metaData: episodeId,
      displayName: episode.title,
    );
    // Foreground and background workers can resolve the same URL at once.
    // Only the worker that claims the unchanged row may enqueue a native task.
    // Keep explicit downloads of finished episodes so their old playback
    // history cannot cause cleanup as soon as the new file finishes.
    final claimed = await _database.customUpdate(
      'INSERT INTO media_downloads (episode_id, task_id, status, updated_at, keep) '
      'SELECT episodes.id, ?, ?, ?, (? = 0 AND (episodes.played = 1 OR EXISTS '
      '(SELECT 1 FROM playback_progresses WHERE episode_id = episodes.id AND completed = 1))) '
      'FROM episodes JOIN feeds ON feeds.id = episodes.feed_id '
      'WHERE episodes.id = ? AND (? = 0 OR (feeds.subscribed = 1 AND feeds.auto_download = 1)) '
      'AND (SELECT task_id FROM media_downloads WHERE episode_id = episodes.id) IS ? '
      'ON CONFLICT(episode_id) DO UPDATE SET task_id = excluded.task_id, '
      'status = excluded.status, file_path = NULL, bytes_downloaded = 0, '
      'total_bytes = NULL, updated_at = excluded.updated_at, '
      'keep = media_downloads.keep OR excluded.keep WHERE media_downloads.status = ?',
      variables: [
        Variable(taskId),
        Variable(DownloadState.queued.index),
        Variable(DateTime.now().toUtc()),
        Variable(automatic ? 1 : 0),
        Variable(episodeId),
        Variable(automatic ? 1 : 0),
        Variable(existing?.taskId),
        Variable(existing?.status),
      ],
      updates: {_database.mediaDownloads},
    );
    if (claimed == 0) return;
    try {
      if (existing != null) {
        _lastProgressWrite.remove(existing.taskId);
        await _downloader.cancelTaskWithId(existing.taskId);
        await _deleteTaskRecord(existing.taskId);
        await _deleteStoredFile(existing.filePath);
      }
      final queued = await _downloader.enqueue(task);
      if (!queued) throw StateError('The download could not be queued.');
      // A removal during enqueue may have canceled before the task existed.
      if ((await _download(episodeId))?.taskId != taskId) {
        await _downloader.cancelTaskWithId(taskId);
        await _deleteTaskRecord(taskId);
      }
    } on Object catch (error, stackTrace) {
      await _setState(taskId, DownloadState.failed);
      await _deleteTaskRecord(taskId);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  bool _isActiveDownload(MediaDownload download) =>
      _reportsProgress(download) ||
      download.status == DownloadState.paused.index;

  Future<void> pause(String episodeId) async {
    await _ensureInitialized();
    final row = await _download(episodeId);
    if (row == null || !_reportsProgress(row)) return;
    final task = await _downloader.taskForId(row.taskId);
    // A successful request does not mean the downloader has saved resume data.
    if (task is DownloadTask && !await _downloader.pause(task)) {
      throw const DownloadException('Couldn’t pause this download.');
    }
  }

  Future<void> resume(String episodeId) async {
    await _ensureInitialized();
    final row = await _download(episodeId);
    if (row == null) return;
    if (row.status == DownloadState.paused.index) {
      final task = await _downloader.taskForId(row.taskId);
      if (task is DownloadTask && await _downloader.resume(task)) {
        if ((await _download(episodeId))?.taskId != row.taskId) {
          await _downloader.cancelTaskWithId(row.taskId);
          await _deleteTaskRecord(row.taskId);
        }
        return;
      }
      // If the platform lost its paused task, a retry needs a fresh task.
      final changed =
          await (_database.update(_database.mediaDownloads)..where(
                (candidate) =>
                    candidate.taskId.equals(row.taskId) &
                    candidate.status.equals(DownloadState.paused.index),
              ))
              .write(
                MediaDownloadsCompanion(
                  status: Value(DownloadState.failed.index),
                ),
              );
      if (changed == 0) return;
    } else if (row.status != DownloadState.failed.index &&
        row.status != DownloadState.canceled.index) {
      return;
    }
    await _requestDownload(episodeId, replacingTaskId: row.taskId);
  }

  Future<void> delete(String episodeId) async {
    await _ensureInitialized();
    final row = await _download(episodeId);
    if (row == null) return;
    await _cancelDownload(row);
  }

  Future<bool> _cancelDownload(MediaDownload row) async {
    await _downloader.cancelTaskWithId(row.taskId);
    final removed = await (_database.delete(
      _database.mediaDownloads,
    )..where((candidate) => candidate.taskId.equals(row.taskId))).goAndReturn();
    await _deleteTaskRecord(row.taskId);
    await _deleteStoredFile(removed.singleOrNull?.filePath ?? row.filePath);
    _lastProgressWrite.remove(row.taskId);
    return removed.isNotEmpty;
  }

  Future<bool> _removePlayedDownload(
    MediaDownload download, {
    ({AutoDeletePolicy policy, DateTime completedBy})? automatic,
  }) async {
    final progress = _database.playbackProgresses;
    final completedAt = coalesce([progress.completedAt, progress.updatedAt]);
    final eligibleProgress =
        progress.completed.equals(true) &
        (automatic == null
            ? const Constant(true)
            : completedAt.isSmallerOrEqualValue(automatic.completedBy));
    final delete = _database.delete(_database.mediaDownloads)
      ..where(
        (row) =>
            row.taskId.equals(download.taskId) &
            row.status.equals(DownloadState.complete.index) &
            row.keep.equals(false) &
            existsQuery(
              _database.selectOnly(progress)
                ..addColumns([progress.episodeId])
                ..where(
                  progress.episodeId.equalsExp(row.episodeId) &
                      eligibleProgress,
                ),
            ),
      );
    final removed = automatic == null
        ? await delete.goAndReturn()
        : await _database.transaction(() async {
            // Recheck before deleting: a user can extend retention while a
            // previous file is being removed, including from another isolate.
            if (await _settings.autoDelete() != automatic.policy) {
              return const <MediaDownload>[];
            }
            return delete.goAndReturn();
          });
    final row = removed.singleOrNull;
    if (row == null) return false;
    _lastProgressWrite.remove(row.taskId);
    await _deleteTaskRecord(row.taskId);
    await _deleteStoredFile(row.filePath);
    return true;
  }

  Future<int> removePlayedDownloads() async {
    await _ensureInitialized();
    final rows =
        await (_database.select(_database.mediaDownloads).join([
              innerJoin(
                _database.playbackProgresses,
                _database.playbackProgresses.episodeId.equalsExp(
                  _database.mediaDownloads.episodeId,
                ),
              ),
            ])..where(
              _database.mediaDownloads.status.equals(
                    DownloadState.complete.index,
                  ) &
                  _database.mediaDownloads.keep.equals(false) &
                  _database.playbackProgresses.completed.equals(true),
            ))
            .get();
    var removed = 0;
    for (final row in rows) {
      final download = row.readTable(_database.mediaDownloads);
      if (await _removePlayedDownload(download)) removed++;
    }
    return removed;
  }

  Future<int> removeAllDownloads() async {
    await _ensureInitialized();
    final downloads = await _database.select(_database.mediaDownloads).get();
    var removed = 0;
    for (final download in downloads) {
      if (await _cancelDownload(download)) removed++;
    }
    return removed;
  }

  Future<void> setKeep(String episodeId, bool keep) async {
    final changed =
        await (_database.update(_database.mediaDownloads)
              ..where((row) => row.episodeId.equals(episodeId)))
            .write(MediaDownloadsCompanion(keep: Value(keep)));
    if (!keep && changed != 0) await cleanupPlayed();
  }

  Future<void> _reconcile() async {
    final records = await _downloader.database.allRecords(group: 'media');
    for (final record in records) {
      if (_isTerminal(record.status)) {
        _terminalRecordPersisted.add(record.taskId);
      }
      await _handleUpdate(
        TaskStatusUpdate(record.task, record.status, record.exception),
      );
    }
    final recordsById = {for (final record in records) record.taskId: record};
    final rows = await _database.select(_database.mediaDownloads).get();
    for (final row in rows) {
      if (row.status == DownloadState.complete.index) {
        if (!await _isUsableCompletedDownload(row)) {
          await _database.markDownloadFileUnavailable(row);
        }
        continue;
      }
      if (recordsById.containsKey(row.taskId)) continue;
      final task = await _downloader.taskForId(row.taskId);
      if (task == null &&
          row.status != DownloadState.failed.index &&
          row.status != DownloadState.canceled.index) {
        await _setState(row.taskId, DownloadState.failed);
      }
    }
  }

  Future<void> cleanupPlayed() async {
    await _ensureInitialized();
    _cleanupRequested = true;
    return _activeCleanup ??= _drainCleanup();
  }

  Future<void> _drainCleanup() async {
    try {
      while (_cleanupRequested) {
        _cleanupRequested = false;
        await _cleanupPlayed();
      }
    } finally {
      _activeCleanup = null;
    }
  }

  Future<void> _cleanupPlayed() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    final policy = await _settings.autoDelete();
    final now = DateTime.now().toUtc();
    final completed =
        await (_database.select(_database.mediaDownloads).join([
              innerJoin(
                _database.playbackProgresses,
                _database.playbackProgresses.episodeId.equalsExp(
                  _database.mediaDownloads.episodeId,
                ),
              ),
            ])..where(
              _database.mediaDownloads.status.equals(
                    DownloadState.complete.index,
                  ) &
                  _database.mediaDownloads.keep.equals(false) &
                  _database.playbackProgresses.completed.equals(true),
            ))
            .get();
    DateTime? nextDue;
    for (final row in completed) {
      final download = row.readTable(_database.mediaDownloads);
      final progress = row.readTable(_database.playbackProgresses);
      final completedAt = progress.completedAt ?? progress.updatedAt;
      final due = switch (policy) {
        AutoDeletePolicy.immediately => completedAt,
        AutoDeletePolicy.after1Day => completedAt.add(
          const Duration(hours: 24),
        ),
        AutoDeletePolicy.after1Week => completedAt.add(const Duration(days: 7)),
      };
      if (!due.isAfter(now)) {
        await _removePlayedDownload(
          download,
          automatic: (policy: policy, completedBy: completedAt),
        );
      } else if (nextDue == null || due.isBefore(nextDue)) {
        nextDue = due;
      }
    }
    if (nextDue != null) {
      final remaining = nextDue.difference(DateTime.now().toUtc());
      _cleanupTimer = Timer(
        remaining.isNegative ? Duration.zero : remaining,
        () {
          _runDetached(cleanupPlayed());
        },
      );
    }
  }

  Future<void> _handleUpdate(TaskUpdate update) async {
    final episodeId = update.task.metaData;
    final current = episodeId.isEmpty ? null : await _download(episodeId);
    if (current == null || current.taskId != update.task.taskId) {
      if (update is TaskStatusUpdate && _isTerminal(update.status)) {
        _lastProgressWrite.remove(update.task.taskId);
        if (update.status == TaskStatus.complete) {
          final staleFile = File(await update.task.filePath());
          if (await staleFile.exists()) await staleFile.delete();
        }
        await _markTerminalStateCommitted(update.task.taskId);
      }
      return;
    }
    if (update is TaskStatusUpdate &&
        current.status == DownloadState.complete.index &&
        update.status != TaskStatus.complete &&
        await _isUsableCompletedDownload(current)) {
      if (_isTerminal(update.status)) {
        await _markTerminalStateCommitted(update.task.taskId);
      }
      return;
    }
    switch (update) {
      case TaskProgressUpdate():
        // Task progress is advisory. A late event must not change paused or
        // terminal rows, even when another isolate wrote the new state.
        if (!_reportsProgress(current) || update.progress < 0) return;
        final now = DateTime.now().toUtc();
        final last = _lastProgressWrite[current.taskId];
        if (last != null &&
            now.difference(last) < AppConstants.downloadProgressWriteInterval) {
          return;
        }
        _lastProgressWrite[current.taskId] = now;
        final total = update.hasExpectedFileSize
            ? update.expectedFileSize
            : null;
        if (total != null && total > 0 && current.totalBytes == null) {
          try {
            await _ensureStorageReserve(
              total,
              alreadyDownloaded: current.bytesDownloaded,
            );
          } on DownloadException {
            final changed = await _setState(
              current.taskId,
              DownloadState.failed,
              whileTransferring: true,
            );
            if (changed != 0) {
              await _downloader.cancelTaskWithId(current.taskId);
            }
            _lastProgressWrite.remove(current.taskId);
            return;
          }
        }
        final downloaded = total == null
            ? null
            : (total * update.progress).round();
        await (_database.update(_database.mediaDownloads)..where(
              (row) => row.taskId.equals(current.taskId) & _transferring(row),
            ))
            .write(
              MediaDownloadsCompanion(
                bytesDownloaded: Value.absentIfNull(downloaded),
                totalBytes: Value.absentIfNull(total),
                updatedAt: Value(now),
              ),
            );
      case TaskStatusUpdate():
        final state = downloadStateForTaskStatus(update.status);
        if (state == DownloadState.complete) {
          final file = File(await update.task.filePath());
          if (_isClearlyNotAudio(update.responseHeaders) ||
              !await isUsableAudioFile(file)) {
            if (await file.exists()) await file.delete();
            await _setState(
              current.taskId,
              DownloadState.failed,
              clearPath: true,
              clearProgress: true,
            );
            await _markTerminalStateCommitted(update.task.taskId);
            return;
          }
          final length = await file.length();
          final updated = await _setState(
            current.taskId,
            state,
            path: p.join(downloadMediaDirectory, update.task.filename),
            downloadedBytes: length,
            totalBytes: length,
          );
          if (updated == 0 && await file.exists()) await file.delete();
          _lastProgressWrite.remove(current.taskId);
          await _markTerminalStateCommitted(update.task.taskId);
          if (_initialized) await cleanupPlayed();
          return;
        }
        final clearStoredPath = shouldClearStoredDownloadPath(
          filePath: current.filePath,
          state: state,
        );
        if (clearStoredPath) {
          try {
            await _deleteStoredFile(current.filePath);
          } on Object {
            // The database path must not keep advertising an unusable file.
          }
        }
        await _setState(current.taskId, state, clearPath: clearStoredPath);
        if (state == DownloadState.failed || state == DownloadState.canceled) {
          _lastProgressWrite.remove(current.taskId);
        }
        if (_isTerminal(update.status)) {
          await _markTerminalStateCommitted(update.task.taskId);
        }
    }
  }

  Future<MediaDownload?> _download(String episodeId) {
    return (_database.select(
      _database.mediaDownloads,
    )..where((row) => row.episodeId.equals(episodeId))).getSingleOrNull();
  }

  bool _reportsProgress(MediaDownload row) =>
      row.status == DownloadState.queued.index ||
      row.status == DownloadState.running.index;

  Expression<bool> _transferring(MediaDownloads row) => row.status.isIn([
    DownloadState.queued.index,
    DownloadState.running.index,
  ]);

  Future<bool> _isUsableCompletedDownload(MediaDownload? download) async {
    if (download?.status != DownloadState.complete.index) return false;
    final file = await storedAudioFile(download?.filePath);
    return file != null && await isUsableAudioFile(file);
  }

  Future<void> _deleteStoredFile(String? path) async {
    final file = await storedAudioFile(path);
    if (file != null && await file.exists()) await file.delete();
  }

  Future<void> _markTerminalStateCommitted(String taskId) async {
    _terminalStateCommitted.add(taskId);
    await _deleteCommittedTaskRecord(taskId);
  }

  Future<void> _deleteCommittedTaskRecord(String taskId) async {
    if (!_terminalStateCommitted.contains(taskId) ||
        !_terminalRecordPersisted.contains(taskId)) {
      return;
    }
    try {
      await _downloader.database.deleteRecordWithId(taskId);
      _terminalStateCommitted.remove(taskId);
      _terminalRecordPersisted.remove(taskId);
    } on Object {
      // The record stays durable and will be retried on the next update/start.
    }
  }

  Future<int> _setState(
    String taskId,
    DownloadState state, {
    String? path,
    bool clearPath = false,
    bool clearProgress = false,
    bool whileTransferring = false,
    int? downloadedBytes,
    int? totalBytes,
  }) async {
    final now = DateTime.now().toUtc();
    return (_database.update(_database.mediaDownloads)..where(
          (row) =>
              row.taskId.equals(taskId) &
              (whileTransferring ? _transferring(row) : const Constant(true)),
        ))
        .write(
          MediaDownloadsCompanion(
            status: Value(state.index),
            filePath: clearPath ? const Value(null) : Value.absentIfNull(path),
            bytesDownloaded: clearProgress
                ? const Value(0)
                : Value.absentIfNull(downloadedBytes),
            totalBytes: clearProgress
                ? const Value(null)
                : Value.absentIfNull(totalBytes),
            updatedAt: Value(now),
          ),
        );
  }

  Future<void> _ensureStorageReserve(
    int? declaredSize, {
    int alreadyDownloaded = 0,
  }) async {
    final freeMiB = await _diskSpace.getFreeDiskSpace ?? double.infinity;
    final totalMiB = await _diskSpace.getTotalDiskSpace ?? double.infinity;
    final reserveMiB = math.max(1024.0, totalMiB * 0.05);
    final remainingBytes = math.max(0, (declaredSize ?? 0) - alreadyDownloaded);
    final remainingMiB = remainingBytes / (1024 * 1024);
    if (freeMiB - remainingMiB < reserveMiB) {
      throw const DownloadException(
        'There isn’t enough free storage to download this episode.',
      );
    }
  }

  String _extension(String? mimeType, Uri url) {
    final byMime = switch (mimeType?.toLowerCase()) {
      'audio/mpeg' => 'mp3',
      'audio/mp4' || 'audio/x-m4a' => 'm4a',
      'audio/aac' => 'aac',
      'audio/ogg' => 'ogg',
      'audio/opus' => 'opus',
      'audio/flac' => 'flac',
      _ => null,
    };
    if (byMime != null) return byMime;
    final segment = url.pathSegments.lastOrNull;
    final raw = segment?.contains('.') == true
        ? segment!.split('.').last.toLowerCase()
        : null;
    if (const {
      'mp3',
      'm4a',
      'aac',
      'ogg',
      'opus',
      'flac',
      'wav',
    }.contains(raw)) {
      return raw!;
    }
    return 'audio';
  }

  Future<void> _applyConnectivity(List<ConnectivityResult> results) async {
    final hasUnmeteredLink =
        results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    final limit =
        !hasUnmeteredLink && results.contains(ConnectivityResult.mobile)
        ? 1
        : 2;
    await _downloader.configure(
      globalConfig: (Config.holdingQueue, (limit, limit, limit)),
    );
  }

  bool _isClearlyNotAudio(Map<String, String>? headers) {
    final type = headers?['content-type']?.toLowerCase() ?? '';
    return type.contains('text/html') ||
        type.contains('application/json') ||
        type.contains('application/xml');
  }

  Future<void> dispose() async {
    final initialization = _initialization;
    if (initialization != null) {
      try {
        await initialization;
      } on Object {
        // Continue releasing resources after a partial initialization.
      }
    }
    _recoveryTimer?.cancel();
    try {
      await _activeRecovery;
    } on Object {
      // Recovery is optional maintenance; disposal must still finish.
    }
    _recoveryTimer = null;
    _activeRecovery = null;
    await _updates?.cancel();
    await _taskRecords?.cancel();
    await _connectivity?.cancel();
    await _autoDeleteSubscription?.cancel();
    final cleanup = _activeCleanup;
    if (cleanup != null) {
      try {
        await cleanup;
      } on Object {
        // Cleanup failure does not prevent native resources being released.
      }
    }
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _terminalStateCommitted.clear();
    _terminalRecordPersisted.clear();
    _lastProgressWrite.clear();
    _activeCleanup = null;
    _initialized = false;
    _initialization = null;
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) await initialize();
  }

  void _runDetached(Future<void> operation) {
    unawaited(operation.catchError((Object _) {}));
  }
}
