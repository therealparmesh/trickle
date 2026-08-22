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

enum _DownloadsAction { removePlayed, removeAll }

final class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

final class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(downloadsProvider);
    final episodes = ref.watch(downloadedEpisodesProvider);
    final items = downloads.value ?? const <MediaDownload>[];
    return Scaffold(
      appBar: AppBar(
        title: const PageTitle('Downloads'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (items.isNotEmpty)
            PopupMenuButton<_DownloadsAction>(
              tooltip: 'Download storage actions',
              onSelected: _runBulkAction,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _DownloadsAction.removePlayed,
                  child: Text('Remove played downloads'),
                ),
                PopupMenuItem(
                  value: _DownloadsAction.removeAll,
                  child: Text('Remove all downloads'),
                ),
              ],
            ),
        ],
      ),
      body: AppBackdrop(
        child: downloads.when(
          data: (items) => items.isEmpty
              ? const EmptyState(
                  icon: Icons.download_done_rounded,
                  title: 'No downloads',
                  message:
                      'Download episodes for playback without a connection.',
                )
              : episodes.when(
                  data: (episodes) => IgnorePointer(
                    ignoring: _busy,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                      itemCount: items.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) return _StorageSummary(items);
                        final download = items[index - 1];
                        return _DownloadRow(
                          download,
                          episode: episodes[download.episodeId],
                        );
                      },
                    ),
                  ),
                  loading: () => const LoadingView(label: 'Loading downloads'),
                  error: (error, _) => ErrorView(
                    friendlyError(error),
                    onRetry: () => ref.invalidate(downloadedEpisodesProvider),
                  ),
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

  Future<void> _runBulkAction(_DownloadsAction action) async {
    if (_busy) return;
    final removeAll = action == _DownloadsAction.removeAll;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          removeAll ? 'Remove all downloads?' : 'Remove played downloads?',
        ),
        content: Text(
          removeAll
              ? 'Current downloads will be canceled. Episodes remain in your library.'
              : 'Played downloads marked Keep will remain on this device.',
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final coordinator = ref.read(downloadCoordinatorProvider);
      final removed = removeAll
          ? await coordinator.removeAllDownloads()
          : await coordinator.removePlayedDownloads();
      if (mounted) {
        showMessageSnackBar(
          context,
          removed == 0
              ? removeAll
                    ? 'No downloads to remove'
                    : 'No played downloads to remove'
              : '$removed ${removed == 1 ? 'download' : 'downloads'} removed',
        );
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

final class _StorageSummary extends StatelessWidget {
  const _StorageSummary(this.downloads);

  final List<MediaDownload> downloads;

  @override
  Widget build(BuildContext context) {
    final bytes = downloads.fold<int>(
      0,
      (total, download) =>
          total +
          (download.status == DownloadState.complete.index
              ? download.totalBytes ?? download.bytesDownloaded
              : download.bytesDownloaded),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        accent: AppConstants.cyan,
        child: Row(
          children: [
            const Icon(Icons.storage_rounded, color: AppConstants.cyan),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${downloads.length} ${downloads.length == 1 ? 'download' : 'downloads'} · ${formatBytes(bytes)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _DownloadRow extends ConsumerStatefulWidget {
  _DownloadRow(this.download, {required this.episode})
    : super(key: ValueKey(download.episodeId));

  final MediaDownload download;
  final Episode? episode;

  @override
  ConsumerState<_DownloadRow> createState() => _DownloadRowState();
}

final class _DownloadRowState extends ConsumerState<_DownloadRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final download = widget.download;
    final episode = widget.episode;
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
            enabled: !_busy,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.more_vert_rounded),
            onSelected: (action) => _runAction(action, download),
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
    return row(episode, fallbackTitle: 'Unavailable episode');
  }

  Future<void> _runAction(String action, MediaDownload download) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final coordinator = ref.read(downloadCoordinatorProvider);
      switch (action) {
        case 'pause':
          await coordinator.pause(download.episodeId);
        case 'resume':
          await coordinator.resume(download.episodeId);
        case 'keep':
          await coordinator.setKeep(download.episodeId, !download.keep);
        case 'delete':
          await coordinator.delete(download.episodeId);
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
