import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_providers.dart';
import '../core/constants.dart';
import '../core/youtube_support.dart';
import '../data/database/app_database.dart';

Future<bool> confirmUnsubscribe(BuildContext context, Feed feed) async {
  final kind = FeedKind.values[feed.kind.clamp(0, FeedKind.values.length - 1)];
  final youtubeKind = youtubeFeedKind(Uri.tryParse(feed.feedUrl));
  final noun = feed.protocol == FeedProtocol.nostr.index
      ? 'Nostr profile'
      : switch ((kind, youtubeKind)) {
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
            'Saved articles and saved, downloaded, queued, bookmarked, or in-progress episodes stay in your library. Other items are removed.',
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
  final repository = ref.read(feedRepositoryProvider);
  final audioHandler = ref.read(audioHandlerProvider);
  final removedEpisodes = await repository.deleteFeed(feed.id);
  try {
    await audioHandler.removeEpisodesFromLibrary(removedEpisodes);
  } on Object {
    // Unsubscribe already committed; do not report it as failed.
  }
}
