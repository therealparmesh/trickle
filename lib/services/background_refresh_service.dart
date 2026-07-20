import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart';

import '../data/database/app_database.dart';
import '../data/network/safe_network_client.dart';
import '../data/repositories/feed_repository.dart';
import '../data/repositories/playback_source_resolver.dart';
import '../data/repositories/settings_repository.dart';
import '../data/security/private_feed_store.dart';
import '../features/downloads/download_coordinator.dart';
import 'notification_service.dart';
import 'refresh_lock.dart';
import 'sync_coordinator.dart';

const backgroundRefreshTask = 'com.parmscript.trickle.feed-refresh';
const _backgroundRefreshBudget = Duration(seconds: 15);
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
      // Keep all network work inside the OS task lifetime so the database is
      // never closed under an in-flight refresh.
      await RefreshLock.run(
        () => repository.refreshAll(
          budget: _backgroundRefreshBudget,
          dueAt: now,
          minimumAge: interval.duration,
          maxConcurrent: 2,
        ),
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
        queueEpisode: (episodeId) => _addEpisodeToQueue(database, episodeId),
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
              .timeout(const Duration(seconds: 3));
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

Future<void> _addEpisodeToQueue(AppDatabase database, String episodeId) async {
  await database.transaction(() async {
    final existing = await (database.select(
      database.queueEntries,
    )..where((row) => row.episodeId.equals(episodeId))).getSingleOrNull();
    if (existing != null) return;
    final last =
        await (database.select(database.queueEntries)
              ..orderBy([(row) => OrderingTerm.desc(row.sortKey)])
              ..limit(1))
            .getSingleOrNull();
    await database
        .into(database.queueEntries)
        .insert(
          QueueEntriesCompanion.insert(
            id: const Uuid().v4(),
            episodeId: episodeId,
            sortKey: (last?.sortKey ?? -1024) + 1024,
            addedAt: DateTime.now().toUtc(),
          ),
          mode: InsertMode.insertOrIgnore,
        );
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
