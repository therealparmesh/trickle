import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/database/app_database.dart';
import '../../features/player/trickle_audio_handler.dart';
import '../playback_presentation.dart';
import '../widgets/common.dart';
import '../widgets/design_system.dart';

final class QueuePage extends ConsumerStatefulWidget {
  const QueuePage({super.key});

  @override
  ConsumerState<QueuePage> createState() => _QueuePageState();
}

final class _QueuePageState extends ConsumerState<QueuePage> {
  final _listKey = GlobalKey<ReorderableListState>();

  @override
  Widget build(BuildContext context) {
    ref.listen(queueProvider, (previous, next) {
      if (TrickleAudioHandler.sameQueueOrder(previous?.value, next.value)) {
        return;
      }
      // A drop also publishes a new queue, while Flutter is still finishing
      // that gesture. Cancel before the next build, after the callback returns.
      scheduleMicrotask(() {
        if (mounted) _listKey.currentState?.cancelReorder();
      });
    });
    final queueState = ref.watch(queueProvider);
    final queue = queueState.value ?? const <MediaItem>[];
    final queuedEpisodes =
        ref.watch(queuedEpisodesProvider).value ?? const <String, Episode>{};
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    return Scaffold(
      appBar: AppBar(
        title: const PageTitle('Up next'),
        actions: [
          if (largeText)
            IconButton(
              tooltip: 'Clear Up next',
              color: AppConstants.danger,
              onPressed: queue.isEmpty
                  ? null
                  : () => _confirmClear(context, ref),
              icon: const Icon(Icons.clear_all_rounded),
            )
          else
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppConstants.danger),
              onPressed: queue.isEmpty
                  ? null
                  : () => _confirmClear(context, ref),
              child: const Text('Clear all'),
            ),
        ],
      ),
      body: AppBackdrop(
        child: queueState.when(
          loading: () => const LoadingView(label: 'Loading Up next'),
          error: (error, _) => ErrorView(
            friendlyError(error),
            title: 'Couldn’t load Up next',
            onRetry: () => ref.invalidate(queueProvider),
          ),
          data: (queue) => queue.isEmpty
              ? const EmptyState(
                  icon: Icons.queue_music_rounded,
                  title: 'Nothing is Up next',
                  message:
                      'Choose Play next or Add to Up next from an episode menu.',
                )
              : ReorderableList(
                  key: _listKey,
                  padding: const EdgeInsets.only(
                    top: AppSpacing.sm,
                    bottom: AppSpacing.xl,
                  ),
                  itemCount: queue.length,
                  onReorderItem: (oldIndex, newIndex) {
                    unawaited(
                      _run(
                        context,
                        () => ref
                            .read(audioHandlerProvider)
                            .reorderQueue(queue, oldIndex, newIndex),
                      ),
                    );
                  },
                  itemBuilder: (context, index) {
                    final item = queue[index];
                    final episode = queuedEpisodes[item.id];
                    return Dismissible(
                      key: ValueKey(item.id),
                      direction: DismissDirection.endToStart,
                      background: const ColoredBox(
                        color: AppConstants.danger,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: EdgeInsets.only(right: AppSpacing.xl),
                            child: Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                      ),
                      confirmDismiss: (_) async {
                        final audio = ref.read(audioHandlerProvider);
                        if (await _confirmRemove(context, item.title) &&
                            context.mounted) {
                          await _run(
                            context,
                            () => audio.removeQueueItem(item),
                          );
                        }
                        // The queue stream removes the row on success. If the
                        // action was rejected, leave it available to retry.
                        return false;
                      },
                      child: Consumer(
                        builder: (context, ref, _) {
                          final playback = ref.watch(
                            playbackItemUiSnapshotProvider(item.id),
                          );
                          final phase = playbackUiPhaseFor(
                            processingState: playback.processingState,
                            playing: playback.playing,
                          );
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                              vertical: AppSpacing.xs,
                            ),
                            child: SignalPanel(
                              accent: playback.isCurrent
                                  ? AppConstants.acid
                                  : null,
                              color: Colors.transparent,
                              padding: EdgeInsets.zero,
                              child: ListTile(
                                key: ValueKey('tile-${item.id}'),
                                selected: playback.isCurrent,
                                selectedTileColor: AppConstants.acid.withValues(
                                  alpha: 0.04,
                                ),
                                onTap: playback.isCurrent
                                    ? () => context.push('/player')
                                    : () => _run(
                                        context,
                                        () => ref
                                            .read(audioHandlerProvider)
                                            .playQueuedEpisode(item.id),
                                      ),
                                leading: episode == null
                                    ? Artwork(
                                        url: item.artUri?.toString(),
                                        size: AppSizes.artwork,
                                        radius: 4,
                                      )
                                    : EpisodeArtwork(
                                        episode: episode,
                                        size: AppSizes.artwork,
                                        radius: 4,
                                      ),
                                title: EpisodeTitle(
                                  title: item.title,
                                  explicit: item.extras?['explicit'] == true,
                                  maxLines: 2,
                                ),
                                subtitle: Text(
                                  [
                                    if (item.album?.isNotEmpty == true)
                                      item.album!,
                                    if (playback.isCurrent) phase.label,
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: ReorderableDragStartListener(
                                  index: index,
                                  child: const SizedBox.square(
                                    dimension: 48,
                                    child: Tooltip(
                                      message: 'Reorder episode',
                                      child: Icon(Icons.drag_indicator_rounded),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Up next?'),
        content: const Text(
          'Playback will stop and every episode will be removed from Up next.',
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
            child: const Text('Clear Up next'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _run(context, ref.read(audioHandlerProvider).clearQueue);
    }
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }

  Future<bool> _confirmRemove(BuildContext context, String title) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remove from Up next?'),
            content: Text(title),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppConstants.danger,
                  foregroundColor: AppConstants.background,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
  }
}
