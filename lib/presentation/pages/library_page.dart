import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../widgets/common.dart';

final class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueState = ref.watch(queueProvider);
    final queue = queueState.value ?? const [];
    final podcastCount = ref.watch(podcastFeedsProvider).value?.length;
    final feedCount = ref.watch(readerFeedsProvider).value?.length;
    final downloadCount = ref.watch(downloadsProvider).value?.length;
    final savedEpisodeCount = ref.watch(starredEpisodeCountProvider).value;
    final savedArticleCount = ref.watch(starredArticleCountProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const PageTitle('Library'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: AppBackdrop(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: HorizontalShortcutStrip(
                children: [
                  LibraryShortcut(
                    icon: Icons.podcasts_rounded,
                    label: 'Podcasts',
                    badge: visibleBadgeCount(podcastCount),
                    onTap: () => context.push('/podcasts'),
                  ),
                  LibraryShortcut(
                    icon: Icons.dynamic_feed_outlined,
                    label: 'Feeds',
                    badge: visibleBadgeCount(feedCount),
                    color: AppConstants.magenta,
                    onTap: () => context.push('/reader?tab=feeds'),
                  ),
                  LibraryShortcut(
                    icon: Icons.queue_music_rounded,
                    label: 'Up Next',
                    badge: visibleBadgeCount(queueState.value?.length),
                    onTap: () => context.push('/queue'),
                  ),
                  LibraryShortcut(
                    icon: Icons.arrow_downward_rounded,
                    label: 'Downloads',
                    badge: visibleBadgeCount(downloadCount),
                    onTap: () => context.push('/downloads'),
                  ),
                  LibraryShortcut(
                    icon: Icons.bookmark_outline_rounded,
                    label: 'Saved episodes',
                    badge: visibleBadgeCount(savedEpisodeCount),
                    onTap: () => context.push('/saved'),
                  ),
                  LibraryShortcut(
                    icon: Icons.bookmark_outline_rounded,
                    label: 'Saved articles',
                    badge: visibleBadgeCount(savedArticleCount),
                    color: AppConstants.magenta,
                    onTap: () => context.push('/saved?tab=articles'),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: SectionHeader(
                'Up Next',
                action: queue.isEmpty ? null : 'See all',
                onAction: queue.isEmpty ? null : () => context.push('/queue'),
              ),
            ),
            if (queueState.isLoading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 18),
                  child: InlineLoadingView(label: 'Loading Up Next'),
                ),
              )
            else if (queueState.hasError)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: InlineErrorView(
                    friendlyError(queueState.error!),
                    title: 'Couldn’t load Up Next',
                    onRetry: () => ref.invalidate(queueProvider),
                  ),
                ),
              )
            else if (queue.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(18, 4, 18, 12),
                  child: Text(
                    'Nothing is Up Next.',
                    style: TextStyle(color: AppConstants.secondaryText),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: queue.take(5).length,
                itemBuilder: (context, index) {
                  final item = queue[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    onTap: () => _openQueueItem(context, ref, index),
                    leading: EpisodeArtworkById(
                      episodeId: item.id,
                      fallbackUrl: item.artUri?.toString(),
                      size: 52,
                    ),
                    title: EpisodeTitle(
                      title: item.title,
                      explicit: item.extras?['explicit'] == true,
                      maxLines: 1,
                    ),
                    subtitle: Text(item.album ?? '', maxLines: 1),
                    trailing: Text(
                      item.duration == null
                          ? ''
                          : formatDuration(item.duration!),
                      style: const TextStyle(
                        color: AppConstants.secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  );
                },
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
          ],
        ),
      ),
    );
  }

  Future<void> _openQueueItem(
    BuildContext context,
    WidgetRef ref,
    int index,
  ) async {
    try {
      await ref.read(audioHandlerProvider).skipToQueueItem(index);
      if (context.mounted) unawaited(context.push('/player'));
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }
}
