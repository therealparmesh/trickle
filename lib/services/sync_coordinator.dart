import 'dart:async';

import 'package:drift/drift.dart';

import '../core/constants.dart';
import '../core/errors.dart';
import '../data/database/app_database.dart';
import '../data/repositories/feed_repository.dart';
import '../features/downloads/download_coordinator.dart';
import '../features/player/trickle_audio_handler.dart';
import 'notification_service.dart';
import 'refresh_lock.dart';

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
    future.then<void>(
      (_) => _clearActiveRefresh(run),
      onError: (Object _, StackTrace _) => _clearActiveRefresh(run),
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
    final refreshed = await RefreshLock.run(() => _feeds.refreshFeed(feed));
    if (!refreshed) {
      return const SyncResult(failedFeeds: 1);
    }
    await applyPodcastAutomation(
      database: _database,
      feedIds: {feed.id},
      queueEpisode: _audio.addEpisodeToQueue,
      downloadEpisode: (id) => _downloads.startDownload(id, automatic: true),
    );
    await _downloads.cleanupPlayed();
    return const SyncResult();
  }

  Future<SyncResult> _runRefresh(_FullRefreshRun run) async {
    final refreshResult = await RefreshLock.run(
      () => _feeds.refreshAll(onProgress: run.reportProgress),
    );
    await applyPodcastAutomation(
      database: _database,
      queueEpisode: _audio.addEpisodeToQueue,
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
          (await (_database.select(
                _database.feeds,
              )..where((row) => row.notifications.equals(true))).get())
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
  required Future<void> Function(String episodeId) queueEpisode,
  required Future<void> Function(String episodeId) downloadEpisode,
  Set<String>? feedIds,
}) async {
  final query = database.select(database.feeds);
  if (feedIds != null) query.where((row) => row.id.isIn(feedIds));
  final feeds = await query.get();
  for (final feed in feeds) {
    final pending =
        await (database.select(database.episodes)
              ..where(
                (row) =>
                    row.feedId.equals(feed.id) &
                    row.automationApplied.equals(false),
              )
              ..orderBy([
                (row) => OrderingTerm.desc(row.publishedAt),
                (row) => OrderingTerm.desc(row.discoveredAt),
              ]))
            .get();
    if (pending.isEmpty) continue;
    final limit = feed.autoDownloadLimit.clamp(1, 10);
    final downloadIds = <String>{};
    if (feed.autoDownload) {
      downloadIds.addAll(pending.take(limit).map((episode) => episode.id));
      final retryQuery =
          database.select(database.mediaDownloads).join([
            innerJoin(
              database.episodes,
              database.episodes.id.equalsExp(database.mediaDownloads.episodeId),
            ),
          ])..where(
            database.episodes.feedId.equals(feed.id) &
                database.episodes.automationApplied.equals(false) &
                database.mediaDownloads.status.isIn([
                  DownloadState.failed.index,
                  DownloadState.canceled.index,
                ]),
          );
      downloadIds.addAll(
        (await retryQuery.get()).map(
          (row) => row.readTable(database.mediaDownloads).episodeId,
        ),
      );
    }
    final appliedIds = <String>[];
    for (final episode in pending) {
      try {
        if (feed.autoQueue) await queueEpisode(episode.id);
        if (downloadIds.contains(episode.id)) {
          final existing =
              await (database.select(database.mediaDownloads)
                    ..where((row) => row.episodeId.equals(episode.id)))
                  .getSingleOrNull();
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
    if (appliedIds.isNotEmpty) {
      await (database.update(database.episodes)
            ..where((row) => row.id.isIn(appliedIds)))
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
