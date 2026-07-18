import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/playback_source_resolver.dart';
import '../../data/repositories/settings_repository.dart';

DownloadState downloadStateForTaskStatus(TaskStatus status) => switch (status) {
  TaskStatus.enqueued => DownloadState.queued,
  TaskStatus.running || TaskStatus.waitingToRetry => DownloadState.running,
  TaskStatus.paused => DownloadState.paused,
  TaskStatus.complete => DownloadState.complete,
  TaskStatus.canceled => DownloadState.canceled,
  TaskStatus.notFound || TaskStatus.failed => DownloadState.failed,
};

bool shouldKeepUsableCompletedDownload({
  required DownloadState localState,
  required TaskStatus incomingStatus,
  required bool fileUsable,
}) =>
    fileUsable &&
    localState == DownloadState.complete &&
    incomingStatus != TaskStatus.complete;

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
  }) : _database = database,
       _sources = sources,
       _settings = settings;

  final AppDatabase _database;
  final PlaybackSourceResolver _sources;
  final SettingsRepository _settings;
  final FileDownloader _downloader = FileDownloader();
  final Uuid _uuid = const Uuid();
  final DiskSpacePlus _diskSpace = DiskSpacePlus();
  StreamSubscription<void>? _updates;
  StreamSubscription<TaskRecord>? _taskRecords;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  StreamSubscription<AutoDeletePolicy>? _autoDeleteSubscription;
  Timer? _cleanupTimer;
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
    await _downloader.start();
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
  }

  Future<void> startDownload(String episodeId, {bool automatic = false}) async {
    await _ensureInitialized();
    if (!_startingDownloads.add(episodeId)) return;
    try {
      await _startDownload(episodeId, automatic: automatic);
    } finally {
      _startingDownloads.remove(episodeId);
    }
  }

  Future<void> _startDownload(
    String episodeId, {
    required bool automatic,
  }) async {
    final episode = await _database.episodeById(episodeId);
    if (episode == null) return;
    final existing = await _download(episodeId);
    if (await _isUsableCompletedDownload(existing)) return;
    if (existing?.status == DownloadState.complete.index &&
        existing?.filePath != null) {
      final staleFile = File(existing!.filePath!);
      if (await staleFile.exists()) await staleFile.delete();
      await _setState(
        episodeId,
        DownloadState.failed,
        clearPath: true,
        clearProgress: true,
      );
    }
    final enclosurePath = Uri.tryParse(
      episode.enclosureUrl,
    )?.path.toLowerCase();
    final mimeType = episode.mimeType?.toLowerCase() ?? '';
    if (enclosurePath?.endsWith('.m3u8') == true ||
        mimeType.contains('mpegurl')) {
      throw const DownloadException(
        'This streaming episode can be played online but can’t be downloaded.',
      );
    }
    await _ensureStorageReserve(episode.fileSize);
    if (existing != null) {
      await _downloader.cancelTaskWithId(existing.taskId);
      await _deleteTaskRecord(existing.taskId);
    }

    final source = await _sources.resolve(episode);
    if (source.isLocal) return;
    if (Uri.tryParse(source.resource)?.path.toLowerCase().endsWith('.m3u8') ==
        true) {
      throw const DownloadException(
        'This streaming episode can be played online but can’t be downloaded.',
      );
    }
    final taskId = _uuid.v4();
    final task = DownloadTask(
      taskId: taskId,
      url: source.resource,
      headers: source.headers,
      filename:
          '$episodeId-$taskId.${_extension(episode.mimeType, source.resource)}',
      directory: 'media',
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
    await _database
        .into(_database.mediaDownloads)
        .insertOnConflictUpdate(
          MediaDownloadsCompanion.insert(
            episodeId: episodeId,
            taskId: taskId,
            status: Value(DownloadState.queued.index),
            filePath: const Value(null),
            bytesDownloaded: const Value(0),
            totalBytes: const Value(null),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    try {
      final queued = await _downloader.enqueue(task);
      if (!queued) throw StateError('The download could not be queued.');
    } on Object catch (error, stackTrace) {
      await _setState(episodeId, DownloadState.failed);
      await _deleteTaskRecord(taskId);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> pause(String episodeId) async {
    await _ensureInitialized();
    final row = await _download(episodeId);
    if (row == null) return;
    final task = await _downloader.taskForId(row.taskId);
    if (task is DownloadTask && await _downloader.pause(task)) {
      await _setState(episodeId, DownloadState.paused);
    }
  }

  Future<void> resume(String episodeId) async {
    await _ensureInitialized();
    final row = await _download(episodeId);
    if (row == null) return;
    final task = await _downloader.taskForId(row.taskId);
    if (task is DownloadTask && await _downloader.resume(task)) {
      await _setState(episodeId, DownloadState.queued);
      return;
    }
    await startDownload(episodeId);
  }

  Future<void> delete(String episodeId) async {
    await _ensureInitialized();
    final row = await _download(episodeId);
    if (row == null) return;
    await _downloader.cancelTaskWithId(row.taskId);
    await _deleteTaskRecord(row.taskId);
    final path = row.filePath;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    await (_database.delete(
      _database.mediaDownloads,
    )..where((candidate) => candidate.episodeId.equals(episodeId))).go();
    _lastProgressWrite.remove(episodeId);
  }

  /// Cancels native tasks whose database rows were removed by a committed
  /// subscription deletion.
  Future<void> discardTasksForDeletedEpisodes(
    Iterable<MediaDownload> downloads,
  ) async {
    await _ensureInitialized();
    for (final download in downloads) {
      try {
        await _downloader.cancelTaskWithId(download.taskId);
      } on Object {
        // A terminal or already-removed task needs no further cancellation.
      }
      await _deleteTaskRecord(download.taskId);
      if (download.filePath case final path?) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on Object {
          // Feed deletion is already committed; inaccessible app data is safe
          // to leave for the operating system to reclaim.
        }
      }
      _lastProgressWrite.remove(download.episodeId);
    }
  }

  Future<void> setKeep(String episodeId, bool keep) {
    return (_database.update(_database.mediaDownloads)
          ..where((row) => row.episodeId.equals(episodeId)))
        .write(MediaDownloadsCompanion(keep: Value(keep)));
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
          if (row.filePath case final path?) {
            final staleFile = File(path);
            if (await staleFile.exists()) await staleFile.delete();
          }
          await _setState(
            row.episodeId,
            DownloadState.failed,
            clearPath: true,
            clearProgress: true,
          );
        }
        continue;
      }
      if (recordsById.containsKey(row.taskId)) continue;
      final task = await _downloader.taskForId(row.taskId);
      if (task == null &&
          row.status != DownloadState.failed.index &&
          row.status != DownloadState.canceled.index) {
        await _setState(row.episodeId, DownloadState.failed);
      }
    }
  }

  Future<void> cleanupPlayed() async {
    await _ensureInitialized();
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    final policy = await _settings.watchAutoDelete().first;
    if (policy == AutoDeletePolicy.never) return;
    final now = DateTime.now().toUtc();
    final completed =
        await (_database.select(_database.mediaDownloads)..where(
              (row) =>
                  row.status.equals(DownloadState.complete.index) &
                  row.keep.equals(false),
            ))
            .get();
    final progressRows = await (_database.select(
      _database.playbackProgresses,
    )..where((row) => row.completed.equals(true))).get();
    final progressByEpisode = {
      for (final progress in progressRows) progress.episodeId: progress,
    };
    DateTime? nextDue;
    for (final download in completed) {
      final progress = progressByEpisode[download.episodeId];
      if (progress == null) continue;
      final completedAt = progress.completedAt ?? progress.updatedAt;
      final due = switch (policy) {
        AutoDeletePolicy.immediately => completedAt,
        AutoDeletePolicy.after24Hours => completedAt.add(
          const Duration(hours: 24),
        ),
        AutoDeletePolicy.after7Days => completedAt.add(const Duration(days: 7)),
        AutoDeletePolicy.never => DateTime.utc(9999),
      };
      if (!due.isAfter(now)) {
        await delete(download.episodeId);
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
    if (episodeId.isEmpty) {
      if (update is TaskStatusUpdate && _isTerminal(update.status)) {
        if (update.status == TaskStatus.complete) {
          final staleFile = File(await update.task.filePath());
          if (await staleFile.exists()) await staleFile.delete();
        }
        await _markTerminalStateCommitted(update.task.taskId);
      }
      return;
    }
    final current = await _download(episodeId);
    if (current == null || current.taskId != update.task.taskId) {
      if (update is TaskStatusUpdate && _isTerminal(update.status)) {
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
        shouldKeepUsableCompletedDownload(
          localState: DownloadState.complete,
          incomingStatus: update.status,
          fileUsable: await _isUsableCompletedDownload(current),
        )) {
      if (_isTerminal(update.status)) {
        await _markTerminalStateCommitted(update.task.taskId);
      }
      return;
    }
    switch (update) {
      case TaskProgressUpdate():
        final now = DateTime.now().toUtc();
        final last = _lastProgressWrite[episodeId];
        if (last != null && now.difference(last) < const Duration(seconds: 2)) {
          return;
        }
        _lastProgressWrite[episodeId] = now;
        final total = update.hasExpectedFileSize
            ? update.expectedFileSize
            : null;
        if (total != null && total > 0 && current.totalBytes == null) {
          try {
            await _ensureStorageReserve(
              total,
              alreadyDownloaded: current.bytesDownloaded,
            );
          } on Object {
            await _downloader.cancelTaskWithId(current.taskId);
            await _setState(episodeId, DownloadState.failed);
            _lastProgressWrite.remove(episodeId);
            return;
          }
        }
        final downloaded = total == null || update.progress < 0
            ? null
            : (total * update.progress).round();
        await (_database.update(
          _database.mediaDownloads,
        )..where((row) => row.episodeId.equals(episodeId))).write(
          MediaDownloadsCompanion(
            bytesDownloaded: Value.absentIfNull(downloaded),
            totalBytes: Value.absentIfNull(total),
            updatedAt: Value(now),
          ),
        );
      case TaskStatusUpdate():
        final state = downloadStateForTaskStatus(update.status);
        String? path;
        if (state == DownloadState.complete) {
          path = await update.task.filePath();
          final file = File(path);
          if (!await file.exists() ||
              await file.length() == 0 ||
              _isClearlyNotAudio(update.responseHeaders) ||
              await _looksLikeWebDocument(file)) {
            if (await file.exists()) await file.delete();
            await _setState(
              episodeId,
              DownloadState.failed,
              clearPath: true,
              clearProgress: true,
            );
            await _markTerminalStateCommitted(update.task.taskId);
            return;
          }
          final length = await file.length();
          await _setState(
            episodeId,
            state,
            path: path,
            downloadedBytes: length,
            totalBytes: length,
          );
          _lastProgressWrite.remove(episodeId);
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
            final staleFile = File(current.filePath!);
            if (await staleFile.exists()) await staleFile.delete();
          } on Object {
            // The database path must not keep advertising an unusable file.
          }
        }
        await _setState(
          episodeId,
          state,
          path: path,
          clearPath: clearStoredPath,
        );
        if (state == DownloadState.failed || state == DownloadState.canceled) {
          _lastProgressWrite.remove(episodeId);
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

  Future<bool> _isUsableCompletedDownload(MediaDownload? download) async {
    if (download?.status != DownloadState.complete.index ||
        download?.filePath == null) {
      return false;
    }
    try {
      final file = File(download!.filePath!);
      return await file.exists() &&
          await file.length() > 0 &&
          !await _looksLikeWebDocument(file);
    } on Object {
      return false;
    }
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

  Future<void> _setState(
    String episodeId,
    DownloadState state, {
    String? path,
    bool clearPath = false,
    bool clearProgress = false,
    int? downloadedBytes,
    int? totalBytes,
  }) async {
    final now = DateTime.now().toUtc();
    await (_database.update(
      _database.mediaDownloads,
    )..where((row) => row.episodeId.equals(episodeId))).write(
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
      throw StateError(
        'There isn’t enough free storage to download this episode.',
      );
    }
  }

  String _extension(String? mimeType, String url) {
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
    final segment = Uri.tryParse(url)?.pathSegments.lastOrNull;
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

  Future<bool> _looksLikeWebDocument(File file) async {
    final bytes = await file
        .openRead(0, math.min(await file.length(), 512))
        .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk));
    final prefix = utf8
        .decode(bytes, allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return prefix.startsWith('<!doctype html') ||
        prefix.startsWith('<html') ||
        prefix.startsWith('<?xml');
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
    await _updates?.cancel();
    await _taskRecords?.cancel();
    await _connectivity?.cancel();
    await _autoDeleteSubscription?.cancel();
    _cleanupTimer?.cancel();
    _terminalStateCommitted.clear();
    _terminalRecordPersisted.clear();
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
