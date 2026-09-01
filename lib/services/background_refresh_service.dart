import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../core/constants.dart';
import '../data/database/app_database.dart';
import '../data/network/safe_network_client.dart';
import '../data/repositories/feed_repository.dart';
import '../data/repositories/playback_source_resolver.dart';
import '../data/repositories/settings_repository.dart';
import '../data/security/private_feed_store.dart';
import '../features/downloads/download_coordinator.dart';
import 'notification_service.dart';
import 'sync_coordinator.dart';

const backgroundRefreshTask = 'com.parmscript.trickle.feed-refresh';
const _backgroundRefreshCadence = Duration(hours: 1);

@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    final database = AppDatabase();
    SafeNetworkClient? network;
    DownloadCoordinator? downloads;
    try {
      network = await SafeNetworkClient.create();
      final privateFeeds = PrivateFeedStore();
      final repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final settings = SettingsRepository(database);
      final now = DateTime.now().toUtc();
      final startedAt = now;
      final interval = await settings.refreshInterval();
      // Feed revisions make a foreground refresh that overlaps this task a
      // safe no-op instead of making either isolate wait on a process lock.
      await repository.refreshAll(
        budget: AppConstants.backgroundRefreshBudget,
        dueAt: now,
        minimumAge: interval.duration,
        maxConcurrent: 2,
      );
      final sources = PlaybackSourceResolver(database, privateFeeds, network);
      downloads = DownloadCoordinator(
        database: database,
        sources: sources,
        settings: settings,
      );
      await downloads.initialize();
      await applyPodcastAutomation(
        database: database,
        queueEpisodes: database.stageQueueAdditions,
        downloadEpisode: (episodeId) =>
            downloads!.startDownload(episodeId, automatic: true),
      );
      await downloads.cleanupPlayed();
      final notifiedFeedIds =
          (await (database.select(
                database.feeds,
              )..where((row) => row.notifications.equals(true))).get())
              .map((feed) => feed.id)
              .toSet();
      if (notifiedFeedIds.isNotEmpty) {
        final episodes =
            await (database.select(database.episodes)..where(
                  (row) => row.discoveredAt.isBiggerOrEqualValue(startedAt),
                ))
                .get();
        final articles =
            await (database.select(database.articles)..where(
                  (row) => row.discoveredAt.isBiggerOrEqualValue(startedAt),
                ))
                .get();
        try {
          await NotificationService()
              .showNewItems(
                episodes: episodes
                    .where(
                      (episode) => notifiedFeedIds.contains(episode.feedId),
                    )
                    .length,
                articles: articles
                    .where(
                      (article) => notifiedFeedIds.contains(article.feedId),
                    )
                    .length,
              )
              .timeout(AppConstants.shortOperationTimeout);
        } on Object {
          // A denied notification permission must not fail feed refresh.
        }
      }
      return true;
    } on Object {
      return false;
    } finally {
      await downloads?.dispose();
      network?.close();
      await database.close();
    }
  });
}

final class BackgroundRefreshService {
  Future<void> initialize() async {
    await Workmanager().initialize(backgroundCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      backgroundRefreshTask,
      backgroundRefreshTask,
      frequency: _backgroundRefreshCadence,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
      tag: 'feed-refresh',
    );
  }
}
