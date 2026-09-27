import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../data/database/app_database.dart';
import '../episode_actions.dart';
import '../playback_presentation.dart';
import 'common.dart';

final class EpisodeActionsButton extends ConsumerStatefulWidget {
  const EpisodeActionsButton({required this.episode, super.key});

  final Episode episode;

  @override
  ConsumerState<EpisodeActionsButton> createState() =>
      _EpisodeActionsButtonState();
}

class _EpisodeActionsButtonState extends ConsumerState<EpisodeActionsButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final progress = ref.watch(episodeProgressSnapshotProvider(episode.id));
    final download = episodeDownloadAction(
      ref.watch(downloadForEpisodeProvider(episode.id)),
    );
    final played =
        episodeListeningState(episode, progress) ==
        EpisodeListeningState.played;
    return PopupMenuButton<EpisodeAction>(
      tooltip: 'Episode actions',
      enabled: !_busy,
      icon: _busy
          ? const SizedBox.square(
              dimension: AppSizes.progressIndicator,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.more_horiz_rounded),
      onSelected: _perform,
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: EpisodeAction.playNext,
          child: Text('Play next'),
        ),
        const PopupMenuItem(
          value: EpisodeAction.addToUpNext,
          child: Text('Add to Up next'),
        ),
        PopupMenuItem(value: download.action, child: Text(download.label)),
        PopupMenuItem(
          value: EpisodeAction.toggleSaved,
          child: Text(episode.starred ? 'Remove from Saved' : 'Save'),
        ),
        PopupMenuItem(
          value: EpisodeAction.togglePlayed,
          child: Text(played ? 'Mark unplayed' : 'Mark played'),
        ),
      ],
    );
  }

  Future<void> _perform(EpisodeAction action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await performEpisodeAction(ref, widget.episode, action);
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
