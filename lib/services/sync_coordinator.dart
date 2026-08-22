import 'dart:async';

import 'package:drift/drift.dart';

import '../core/constants.dart';
import '../core/errors.dart';
import '../data/database/app_database.dart';
import '../data/repositories/feed_repository.dart';
import '../features/downloads/download_coordinator.dart';
import '../features/player/trickle_audio_handler.dart';
import 'notification_service.dart';

final class SyncResult {
  const SyncResult({this.failedFeeds = 0});

  final int failedFeeds;
}

/// Runs foreground refresh work without requiring an account or server.
final class SyncCoordinator {
  SyncCoordinator({
    required AppDatabase database,
    required FeedRepository feeds,
    required DownloadCoordinator downloads,
    required TrickleAudioHandler audio,
    required NotificationService notifications,
  }) : _database = database,
       _feeds = feeds,
       _downloads = downloads,
       _audio = audio,
       _notifications = notifications;

  final AppDatabase _database;
  final FeedRepository _feeds;
  final DownloadCoordinator _downloads;
  final TrickleAudioHandler _audio;
  final NotificationService _notifications;

  Future<void> _refreshTail = Future<void>.value();
  _FullRefreshRun? _activeFullRefresh;

  Future<SyncResult> refresh({
    bool notify = false,
    void Function(int completed, int total)? onProgress,
  }) {
    final active = _activeFullRefresh;
    if (active != null) {
      if (notify) active.notifyRequested = true;
      active.addProgressListener(onProgress);
      return active.future;
    }
    final run = _FullRefreshRun(
      startedAt: DateTime.now().toUtc(),
      notifyRequested: notify,
    );
    run.addProgressListener(onProgress);
    final future = _serialize(() => _runRefresh(run));
    run.future = future;
    _activeFullRefresh = run;
    unawaited(
      future.then<void>(
        (_) => _clearActiveRefresh(run),
        onError: (Object _, StackTrace _) => _clearActiveRefresh(run),
      ),
    );
    return future;
  }

  void _clearActiveRefresh(_FullRefreshRun run) {
    if (identical(_activeFullRefresh, run)) _activeFullRefresh = null;
  }

  Future<SyncResult> refreshFeed(Feed feed) =>
      _serialize(() => _runFeedRefresh(feed));

  Future<SyncResult> _serialize(Future<SyncResult> Function() operation) {
    final result = _refreshTail.then((_) => operation());
    _refreshTail = result.then<void>(
      (_) {},
      // Callers still receive the error through [result], while the internal
      // tail recovers so the next requested refresh can run.
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<SyncResult> _runFeedRefresh(Feed feed) async {
    final refreshed = await _feeds.refreshFeed(feed);
    if (!refreshed) {
      return const SyncResult(failedFeeds: 1);
    }
    await applyPodcastAutomation(
      database: _database,
      feedIds: {feed.id},
      queueEpisodes: _audio.addEpisodesToQueue,
      downloadEpisode: (id) => _downloads.startDownload(id, automatic: true),
    );
    await _downloads.cleanupPlayed();
    return const SyncResult();
  }

  Future<SyncResult> _runRefresh(_FullRefreshRun run) async {
    final refreshResult = await _feeds.refreshAll(
      onProgress: run.reportProgress,
    );
    await applyPodcastAutomation(
      database: _database,
      queueEpisodes: _audio.addEpisodesToQueue,
      downloadEpisode: (id) => _downloads.startDownload(id, automatic: true),
    );
    await _downloads.cleanupPlayed();
    if (run.notifyRequested) {
      final newEpisodes =
          await (_database.select(_database.episodes)..where(
                (row) => row.discoveredAt.isBiggerOrEqualValue(run.startedAt),
              ))
              .get();
      final newArticles =
          await (_database.select(_database.articles)..where(
                (row) => row.discoveredAt.isBiggerOrEqualValue(run.startedAt),
              ))
              .get();
      final notifiedFeedIds =
          (await (_database.select(_database.feeds)..where(
                    (row) =>
                        row.subscribed.equals(true) &
                        row.notifications.equals(true),
                  ))
                  .get())
              .map((feed) => feed.id)
              .toSet();
      try {
        await _notifications.showNewItems(
          episodes: newEpisodes
              .where((episode) => notifiedFeedIds.contains(episode.feedId))
              .length,
          articles: newArticles
              .where((article) => notifiedFeedIds.contains(article.feedId))
              .length,
        );
      } on Object {
        // Notification permission or OS delivery must not fail synchronization.
      }
    }
    return SyncResult(failedFeeds: refreshResult.failedFeeds);
  }

  Future<void> resumeMaintenance() async {
    await _serialize(() async {
      await _audio.reloadQueueFromDatabase();
      await _downloads.cleanupPlayed();
      return const SyncResult();
    });
  }
}

Future<void> applyPodcastAutomation({
  required AppDatabase database,
  required Future<void> Function(Iterable<String> episodeIds) queueEpisodes,
  required Future<void> Function(String episodeId) downloadEpisode,
  Set<String>? feedIds,
}) async {
  final query = database.select(database.feeds);
  query.where(
    (row) =>
        row.subscribed.equals(true) &
        (feedIds == null ? const Constant(true) : row.id.isIn(feedIds)),
  );
  final feeds = await query.get();
  if (feeds.isEmpty) return;
  final feedsById = {for (final feed in feeds) feed.id: feed};
  final pendingQuery = database.select(database.episodes)
    ..where(
      (row) =>
          row.automationApplied.equals(false) &
          (feedIds == null
              ? const Constant(true)
              : row.feedId.isIn(feedsById.keys)),
    )
    ..orderBy([
      (row) => OrderingTerm.asc(row.feedId),
      (row) => OrderingTerm.desc(row.publishedAt),
      (row) => OrderingTerm.desc(row.discoveredAt),
    ]);
  final pendingByFeed = <String, List<Episode>>{};
  for (final episode in await pendingQuery.get()) {
    pendingByFeed.putIfAbsent(episode.feedId, () => []).add(episode);
  }
  if (pendingByFeed.isEmpty) return;
  final downloadCandidateIds = <String>{
    for (final feed in feeds)
      if (feed.autoDownload)
        for (final episode in pendingByFeed[feed.id] ?? const <Episode>[])
          episode.id,
  };
  final downloadsByEpisode = <String, MediaDownload>{};
  final candidateIds = downloadCandidateIds.toList(growable: false);
  for (
    var start = 0;
    start < candidateIds.length;
    start += AppDatabase.safeVariableBatchSize
  ) {
    final end = (start + AppDatabase.safeVariableBatchSize).clamp(
      0,
      candidateIds.length,
    );
    final downloads =
        await (database.select(database.mediaDownloads)..where(
              (row) => row.episodeId.isIn(candidateIds.sublist(start, end)),
            ))
            .get();
    for (final download in downloads) {
      downloadsByEpisode[download.episodeId] = download;
    }
  }
  final queueIds = [
    for (final feed in feeds)
      if (feed.autoQueue)
        for (final episode in pendingByFeed[feed.id] ?? const <Episode>[])
          episode.id,
  ];
  var queueSucceeded = true;
  if (queueIds.isNotEmpty) {
    try {
      await queueEpisodes(queueIds);
    } on Object {
      queueSucceeded = false;
    }
  }
  final appliedIds = <String>[];
  for (final feed in feeds) {
    final pending = pendingByFeed[feed.id] ?? const <Episode>[];
    if (pending.isEmpty) continue;
    final limit = feed.autoDownloadLimit.clamp(1, 10);
    final downloadIds = <String>{};
    if (feed.autoDownload) {
      downloadIds.addAll(pending.take(limit).map((episode) => episode.id));
      for (final episode in pending) {
        final existing = downloadsByEpisode[episode.id];
        if (existing?.status == DownloadState.failed.index ||
            existing?.status == DownloadState.canceled.index) {
          downloadIds.add(episode.id);
        }
      }
    }
    for (final episode in pending) {
      if (feed.autoQueue && !queueSucceeded) continue;
      try {
        if (downloadIds.contains(episode.id)) {
          final existing = downloadsByEpisode[episode.id];
          if (existing == null ||
              existing.status == DownloadState.failed.index ||
              existing.status == DownloadState.canceled.index) {
            await downloadEpisode(episode.id);
          }
        }
        appliedIds.add(episode.id);
      } on DownloadException {
        // Permanently unsupported media should not retry every refresh.
        appliedIds.add(episode.id);
      } on Object {
        // A failed action stays pending for the next refresh.
      }
    }
  }
  if (appliedIds.isNotEmpty) {
    for (
      var start = 0;
      start < appliedIds.length;
      start += AppDatabase.safeVariableBatchSize
    ) {
      final end = (start + AppDatabase.safeVariableBatchSize).clamp(
        0,
        appliedIds.length,
      );
      await (database.update(database.episodes)
            ..where((row) => row.id.isIn(appliedIds.sublist(start, end))))
          .write(const EpisodesCompanion(automationApplied: Value(true)));
    }
  }
}

final class _FullRefreshRun {
  _FullRefreshRun({required this.startedAt, required this.notifyRequested});

  final DateTime startedAt;
  bool notifyRequested;
  late final Future<SyncResult> future;
  final List<void Function(int completed, int total)> _progressListeners = [];
  int _completed = 0;
  int _total = 0;

  void addProgressListener(void Function(int completed, int total)? listener) {
    if (listener == null) return;
    _progressListeners.add(listener);
    if (_total > 0) listener(_completed, _total);
  }

  void reportProgress(int completed, int total) {
    _completed = completed;
    _total = total;
    for (final listener in _progressListeners) {
      listener(completed, total);
    }
  }
}
