import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_providers.dart';
import '../core/constants.dart';
import '../core/youtube_support.dart';
import '../data/database/app_database.dart';

Future<void> deleteSubscriptionThenCleanup({
  required Future<void> Function() deleteSubscription,
  required Iterable<Future<void> Function()> cleanupOperations,
}) async {
  await deleteSubscription();
  for (final cleanup in cleanupOperations) {
    try {
      await cleanup();
    } on Object {
      // The database commit is authoritative. Continue best-effort cleanup
      // without presenting a failed deletion for a subscription that is gone.
    }
  }
}

Future<bool> confirmUnsubscribe(BuildContext context, Feed feed) async {
  final kind = FeedKind.values[feed.kind.clamp(0, FeedKind.values.length - 1)];
  final youtubeKind = youtubeFeedKind(Uri.tryParse(feed.feedUrl));
  final noun = switch ((kind, youtubeKind)) {
    (FeedKind.podcast, _) => 'podcast',
    (FeedKind.reader, YouTubeFeedKind.channel) => 'YouTube channel',
    (FeedKind.reader, YouTubeFeedKind.playlist) => 'YouTube playlist',
    (FeedKind.reader, null) => 'feed',
  };
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Unsubscribe from this $noun?'),
          content: const Text(
            'This removes its episodes, articles, playback and reading progress, Up Next items, downloads, and private credentials from this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppConstants.danger,
                foregroundColor: AppConstants.background,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Unsubscribe'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> removeSubscription(WidgetRef ref, Feed feed) async {
  final database = ref.read(databaseProvider);
  final episodeIds =
      await (database.selectOnly(database.episodes)
            ..addColumns([database.episodes.id])
            ..where(database.episodes.feedId.equals(feed.id)))
          .map((row) => row.read(database.episodes.id)!)
          .get();
  final downloadRows =
      await (database.select(database.mediaDownloads).join([
            innerJoin(
              database.episodes,
              database.episodes.id.equalsExp(database.mediaDownloads.episodeId),
            ),
          ])..where(database.episodes.feedId.equals(feed.id)))
          .map((row) => row.readTable(database.mediaDownloads))
          .get();
  await deleteSubscriptionThenCleanup(
    deleteSubscription: () =>
        ref.read(feedRepositoryProvider).deleteFeed(feed.id),
    cleanupOperations: [
      if (episodeIds.isNotEmpty)
        () => ref
            .read(audioHandlerProvider)
            .removeEpisodesFromLibrary(episodeIds),
      if (downloadRows.isNotEmpty)
        () => ref
            .read(downloadCoordinatorProvider)
            .discardTasksForDeletedEpisodes(downloadRows),
    ],
  );
}
