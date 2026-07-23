import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../data/database/app_database.dart';
import '../playback_presentation.dart';
import 'common.dart';
import 'design_system.dart';

final class EpisodePlaybackButton extends ConsumerStatefulWidget {
  const EpisodePlaybackButton({
    required this.episode,
    this.expanded = false,
    super.key,
  });

  final Episode episode;
  final bool expanded;

  @override
  ConsumerState<EpisodePlaybackButton> createState() =>
      _EpisodePlaybackButtonState();
}

class _EpisodePlaybackButtonState extends ConsumerState<EpisodePlaybackButton> {
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(currentMediaProvider).value;
    final isCurrent = current?.id == widget.episode.id;
    final state = ref.watch(playbackStateProvider).value;
    final progress = widget.expanded
        ? ref.watch(episodeProgressProvider(widget.episode.id)).value
        : null;
    final playing = isCurrent && state?.playing == true;
    final phase = isCurrent
        ? playbackUiPhaseFor(state)
        : PlaybackUiPhase.paused;
    final engineBusy = isCurrent && phase.isBusy;
    final failed = isCurrent && phase.isError;
    final busy = _running || (engineBusy && !playing);
    final label = failed
        ? 'Retry'
        : playing
        ? 'Pause'
        : engineBusy
        ? phase.actionLabel(playing: false)
        : isCurrent
        ? 'Resume'
        : widget.episode.played || progress?.completed == true
        ? 'Play again'
        : (progress?.positionMs ?? 0) > 0
        ? 'Resume'
        : 'Play';
    final icon = failed
        ? Icons.refresh_rounded
        : playing
        ? Icons.pause_rounded
        : Icons.play_arrow_rounded;
    final onPressed = busy ? null : () => _toggle(isCurrent, playing);

    if (widget.expanded) {
      return Semantics(
        button: true,
        enabled: !busy,
        label: '$label ${widget.episode.title}',
        excludeSemantics: true,
        onTap: onPressed,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(54),
            backgroundColor: failed ? AppConstants.danger : null,
          ),
          onPressed: onPressed,
          icon: busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.3,
                    color: AppConstants.background,
                  ),
                )
              : Icon(icon),
          label: Text(label),
        ),
      );
    }

    final tooltip = '$label ${widget.episode.title}';
    return Semantics(
      button: true,
      enabled: !busy,
      label: tooltip,
      excludeSemantics: true,
      onTap: onPressed,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Material(
          color: failed
              ? AppConstants.danger.withValues(alpha: 0.16)
              : AppConstants.cyan.withValues(alpha: 0.14),
          shape: CutCornerBorder(
            cut: 10,
            side: BorderSide(
              color: failed
                  ? AppConstants.danger.withValues(alpha: 0.6)
                  : AppConstants.cyan.withValues(alpha: 0.45),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 48,
              child: Center(
                child: busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : Icon(
                        icon,
                        color: failed ? AppConstants.danger : AppConstants.cyan,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(bool isCurrent, bool playing) async {
    setState(() => _running = true);
    try {
      if (!isCurrent) {
        await ref.read(audioHandlerProvider).playEpisode(widget.episode.id);
      } else if (playing) {
        await ref.read(audioHandlerProvider).pause();
      } else {
        await ref.read(audioHandlerProvider).play();
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}
