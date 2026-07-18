import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_providers.dart';
import '../core/constants.dart';
import '../data/database/app_database.dart';

enum EpisodeAction {
  playNow,
  playNext,
  addToUpNext,
  download,
  resumeDownload,
  deleteDownload,
  toggleSaved,
  togglePlayed,
}

typedef EpisodeDownloadAction = ({
  EpisodeAction action,
  String label,
  IconData icon,
});

EpisodeDownloadAction episodeDownloadAction(MediaDownload? download) {
  final state = download == null
      ? null
      : DownloadState.values[download.status.clamp(
          0,
          DownloadState.values.length - 1,
        )];
  return switch (state) {
    null => (
      action: EpisodeAction.download,
      label: 'Download',
      icon: Icons.download_rounded,
    ),
    DownloadState.complete => (
      action: EpisodeAction.deleteDownload,
      label: 'Remove download',
      icon: Icons.download_done_rounded,
    ),
    DownloadState.running || DownloadState.queued => (
      action: EpisodeAction.deleteDownload,
      label: 'Cancel download',
      icon: Icons.close_rounded,
    ),
    DownloadState.paused => (
      action: EpisodeAction.resumeDownload,
      label: 'Resume download',
      icon: Icons.download_rounded,
    ),
    DownloadState.failed || DownloadState.canceled => (
      action: EpisodeAction.resumeDownload,
      label: 'Retry download',
      icon: Icons.refresh_rounded,
    ),
  };
}

Future<void> performEpisodeAction(
  WidgetRef ref,
  Episode episode,
  EpisodeAction action,
) async {
  switch (action) {
    case EpisodeAction.playNow:
      await ref.read(audioHandlerProvider).playEpisode(episode.id);
    case EpisodeAction.playNext:
      await ref.read(audioHandlerProvider).playNextEpisode(episode.id);
    case EpisodeAction.addToUpNext:
      await ref.read(audioHandlerProvider).addEpisodeToQueue(episode.id);
    case EpisodeAction.download:
      await ref.read(downloadCoordinatorProvider).startDownload(episode.id);
    case EpisodeAction.resumeDownload:
      await ref.read(downloadCoordinatorProvider).resume(episode.id);
    case EpisodeAction.deleteDownload:
      await ref.read(downloadCoordinatorProvider).delete(episode.id);
    case EpisodeAction.toggleSaved:
      await ref
          .read(feedRepositoryProvider)
          .starEpisode(episode.id, starred: !episode.starred);
    case EpisodeAction.togglePlayed:
      await ref
          .read(audioHandlerProvider)
          .setEpisodePlayed(episode.id, !episode.played);
  }
}

Future<void> shareEpisode(
  BuildContext context,
  Episode episode,
  Feed? feed,
) async {
  final siteUrl = feed?.isPrivate == true ? null : feed?.siteUrl;
  final lines = <String>[
    episode.title,
    if (feed?.title.isNotEmpty == true) feed!.title,
    if (siteUrl?.isNotEmpty == true) siteUrl!,
  ];
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      text: lines.join('\n'),
      subject: episode.title,
      sharePositionOrigin: box == null || !box.hasSize || box.size.isEmpty
          ? const Rect.fromLTWH(0, 0, 1, 1)
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}
