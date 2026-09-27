import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import 'add_feed_dialog.dart';

enum _AddFeedChoice { podcastSearch, podcastUrl, feed, youtube }

Future<void> showAddFeedSheet(
  BuildContext context, {
  bool includePodcasts = false,
}) async {
  final choice = await showModalBottomSheet<_AddFeedChoice>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (includePodcasts) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.podcasts_rounded,
                  color: AppConstants.cyan,
                ),
                title: const Text('Add podcast'),
                subtitle: const Text('Search Apple Podcasts'),
                onTap: () =>
                    Navigator.pop(context, _AddFeedChoice.podcastSearch),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.add_link_rounded,
                  color: AppConstants.cyan,
                ),
                title: const Text('Add podcast URL'),
                subtitle: const Text('Paste a podcast feed URL'),
                onTap: () => Navigator.pop(context, _AddFeedChoice.podcastUrl),
              ),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.add_link_rounded,
                color: AppConstants.magenta,
              ),
              title: const Text('Add feed'),
              subtitle: const Text(
                'RSS, Atom, JSON Feed, website, or Nostr profile',
              ),
              onTap: () => Navigator.pop(context, _AddFeedChoice.feed),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.video_call_outlined,
                color: AppConstants.magenta,
              ),
              title: const Text('Add YouTube feed'),
              subtitle: const Text('Public channel or playlist'),
              onTap: () => Navigator.pop(context, _AddFeedChoice.youtube),
            ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice == _AddFeedChoice.podcastSearch) {
    await context.push<void>('/podcast-search');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => switch (choice) {
      _AddFeedChoice.podcastUrl => const AddFeedDialog.podcast(),
      _AddFeedChoice.youtube => const AddFeedDialog.youtube(),
      _ => const AddFeedDialog(),
    },
  );
}
