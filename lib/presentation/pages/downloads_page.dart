import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../data/database/app_database.dart';
import '../widgets/common.dart';
import '../widgets/episode_playback_button.dart';

final class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: AppBackdrop(
        child: downloads.when(
          data: (items) => items.isEmpty
              ? const EmptyState(
                  icon: Icons.download_done_rounded,
                  title: 'No downloads',
                  message:
                      'Download episodes for playback without a connection.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (context, index) => _DownloadRow(items[index]),
                ),
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(
            friendlyError(error),
            onRetry: () => ref.invalidate(downloadsProvider),
          ),
        ),
      ),
    );
  }
}

final class _DownloadRow extends ConsumerWidget {
  const _DownloadRow(this.download);

  final MediaDownload download;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episode = ref.watch(episodeProvider(download.episodeId));
    final state = DownloadState
        .values[download.status.clamp(0, DownloadState.values.length - 1)];
    final total = download.totalBytes ?? 0;
    final progress = total <= 0
        ? null
        : (download.bytesDownloaded / total).clamp(0.0, 1.0);
    Widget row(Episode? value, {String? fallbackTitle}) => ListTile(
      onTap: value == null ? null : () => context.push('/episode/${value.id}'),
      leading: value == null
          ? const Artwork(size: 52)
          : EpisodeArtwork(episode: value, size: 52),
      title: EpisodeTitle(
        title: value?.title ?? fallbackTitle ?? 'Unavailable episode',
        explicit: value?.explicit ?? false,
        maxLines: 2,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_stateLabel(state, download)),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress, minHeight: 3),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null) EpisodePlaybackButton(episode: value),
          PopupMenuButton<String>(
            tooltip: 'Download actions',
            onSelected: (action) async {
              try {
                final coordinator = ref.read(downloadCoordinatorProvider);
                switch (action) {
                  case 'pause':
                    await coordinator.pause(download.episodeId);
                  case 'resume':
                    await coordinator.resume(download.episodeId);
                  case 'keep':
                    await coordinator.setKeep(
                      download.episodeId,
                      !download.keep,
                    );
                  case 'delete':
                    await coordinator.delete(download.episodeId);
                }
              } on Object catch (error) {
                if (context.mounted) showErrorSnackBar(context, error);
              }
            },
            itemBuilder: (_) => [
              if (state == DownloadState.running ||
                  state == DownloadState.queued)
                const PopupMenuItem(value: 'pause', child: Text('Pause')),
              if (state == DownloadState.paused ||
                  state == DownloadState.failed)
                PopupMenuItem(
                  value: 'resume',
                  child: Text(
                    state == DownloadState.paused
                        ? 'Resume download'
                        : 'Retry download',
                  ),
                ),
              if (state == DownloadState.canceled)
                const PopupMenuItem(
                  value: 'resume',
                  child: Text('Retry download'),
                ),
              if (state == DownloadState.complete)
                PopupMenuItem(
                  value: 'keep',
                  child: Text(
                    download.keep ? 'Allow automatic removal' : 'Keep download',
                  ),
                ),
              PopupMenuItem(
                value: 'delete',
                child: Text(
                  state == DownloadState.running ||
                          state == DownloadState.queued
                      ? 'Cancel download'
                      : 'Remove download',
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return episode.when(
      data: row,
      loading: () => Semantics(
        label: 'Loading download',
        child: ExcludeSemantics(
          child: ListTile(
            leading: Artwork(size: 52),
            title: LinearProgressIndicator(),
          ),
        ),
      ),
      error: (_, _) => row(null, fallbackTitle: 'Couldn’t load episode'),
    );
  }

  String _stateLabel(DownloadState state, MediaDownload download) {
    if (state == DownloadState.complete && download.totalBytes != null) {
      return '${formatBytes(download.totalBytes!)} · Downloaded${download.keep ? ' · Kept' : ''}';
    }
    return switch (state) {
      DownloadState.queued => 'Queued',
      DownloadState.running =>
        'Downloading · ${formatBytes(download.bytesDownloaded)}',
      DownloadState.paused => 'Paused',
      DownloadState.complete => 'Downloaded${download.keep ? ' · Kept' : ''}',
      DownloadState.failed => 'Failed · Choose Retry download',
      DownloadState.canceled => 'Canceled · Choose Retry download',
    };
  }
}
