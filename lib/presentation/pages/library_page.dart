import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../widgets/common.dart';

final class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider).value ?? const [];
    final completeDownloads =
        ref.watch(completedDownloadCountProvider).value ?? 0;
    final starredEpisodes = ref.watch(starredEpisodeCountProvider).value ?? 0;
    final starredArticles = ref.watch(starredArticleCountProvider).value ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
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
                    icon: Icons.queue_music_rounded,
                    label: 'Up Next',
                    badge: queue.length,
                    onTap: () => context.push('/queue'),
                  ),
                  LibraryShortcut(
                    icon: Icons.arrow_downward_rounded,
                    label: 'Downloads',
                    badge: completeDownloads,
                    onTap: () => context.push('/downloads'),
                  ),
                  LibraryShortcut(
                    icon: Icons.bookmark_outline_rounded,
                    label: 'Episodes',
                    badge: starredEpisodes,
                    color: AppConstants.magenta,
                    onTap: () => context.push('/saved'),
                  ),
                  LibraryShortcut(
                    icon: Icons.bookmark_outline_rounded,
                    label: 'Articles',
                    badge: starredArticles,
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
            if (queue.isEmpty)
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
            const SliverToBoxAdapter(child: SectionHeader('Storage')),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: AppCard(
                  onTap: () => context.push('/downloads'),
                  child: Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppConstants.acid.withValues(alpha: 0.16),
                        ),
                        child: const Icon(
                          Icons.offline_bolt_rounded,
                          color: AppConstants.acid,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$completeDownloads download${completeDownloads == 1 ? '' : 's'} on this device',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            const Text(
                              'Pause, resume, and listen offline.',
                              style: TextStyle(
                                color: AppConstants.secondaryText,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
              ),
            ),
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
      if (context.mounted) context.push('/player');
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }
}
