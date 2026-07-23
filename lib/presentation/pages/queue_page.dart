import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../playback_presentation.dart';
import '../widgets/common.dart';

final class QueuePage extends ConsumerWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueState = ref.watch(queueProvider);
    final queue = queueState.value ?? const <MediaItem>[];
    final current = ref.watch(currentMediaProvider).value;
    final playback = ref.watch(playbackStateProvider).value;
    final phase = playbackUiPhaseFor(playback);
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Up Next'),
        actions: [
          if (largeText)
            IconButton(
              tooltip: 'Clear Up Next',
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
              child: const Text('Clear'),
            ),
        ],
      ),
      body: AppBackdrop(
        child: queueState.when(
          loading: () => const LoadingView(label: 'Loading Up Next'),
          error: (error, _) => ErrorView(
            friendlyError(error),
            title: 'Couldn’t load Up Next',
            onRetry: () => ref.invalidate(queueProvider),
          ),
          data: (queue) => queue.isEmpty
              ? const EmptyState(
                  icon: Icons.queue_music_rounded,
                  title: 'Nothing is Up Next',
                  message:
                      'Choose Play next or Add to Up Next from an episode menu.',
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(top: 8, bottom: 24),
                  itemCount: queue.length,
                  onReorderItem: (oldIndex, newIndex) {
                    final items = [...queue];
                    final item = items.removeAt(oldIndex);
                    items.insert(newIndex, item);
                    unawaited(
                      _run(
                        context,
                        () => ref.read(audioHandlerProvider).updateQueue(items),
                      ),
                    );
                  },
                  itemBuilder: (context, index) {
                    final item = queue[index];
                    final active = current?.id == item.id;
                    return Dismissible(
                      key: ValueKey(item.id),
                      direction: DismissDirection.endToStart,
                      background: const ColoredBox(
                        color: AppConstants.danger,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: EdgeInsets.only(right: 22),
                            child: Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                      ),
                      confirmDismiss: (_) =>
                          _confirmRemove(context, item.title),
                      onDismissed: (_) => _run(
                        context,
                        () => ref
                            .read(audioHandlerProvider)
                            .removeQueueItem(item),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            key: ValueKey('tile-${item.id}'),
                            selected: active,
                            selectedTileColor: AppConstants.cyan.withValues(
                              alpha: 0.05,
                            ),
                            onTap: active
                                ? () => context.push('/player')
                                : () => _run(
                                    context,
                                    () => ref
                                        .read(audioHandlerProvider)
                                        .skipToQueueItem(index),
                                  ),
                            leading: EpisodeArtworkById(
                              episodeId: item.id,
                              fallbackUrl: item.artUri?.toString(),
                              size: 50,
                            ),
                            title: EpisodeTitle(
                              title: item.title,
                              explicit: item.extras?['explicit'] == true,
                              maxLines: 2,
                            ),
                            subtitle: Text(
                              [
                                if (item.album?.isNotEmpty == true) item.album!,
                                if (active) phase.label,
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
                          if (index < queue.length - 1)
                            const Divider(height: 1, indent: 82, endIndent: 16),
                        ],
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
        title: const Text('Clear Up Next?'),
        content: const Text(
          'Playback will stop and every episode will be removed from Up Next.',
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
            child: const Text('Clear Up Next'),
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
            title: const Text('Remove from Up Next?'),
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
