import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/app_providers.dart';
import '../core/constants.dart';
import '../features/video/video_session.dart';
import 'playback_presentation.dart';
import 'widgets/common.dart';
import 'widgets/design_system.dart';
import 'widgets/video_player_host.dart';

final class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final video = ref.watch(videoSessionProvider);
    final hasAudioPlayer =
        video == null && ref.watch(currentMediaProvider).value != null;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final playerInset = keyboardOpen
        ? 0.0
        : video != null && video.presentation != VideoPresentation.expanded
        ? videoMiniPlayerHeight(context) +
              16 +
              MediaQuery.viewPaddingOf(context).bottom
        : hasAudioPlayer
        ? _miniPlayerHeight(context) +
              8 +
              MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    return VideoPlayerHost(
      child: BackButtonListener(
        onBackButtonPressed: () async {
          if (ref.read(videoSessionProvider)?.presentation !=
              VideoPresentation.expanded) {
            return false;
          }
          ref.read(videoSessionProvider.notifier).minimize();
          return true;
        },
        child: ColoredBox(
          color: AppConstants.background,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(bottom: playerInset, child: child),
              if (video == null)
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: MiniPlayer(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final item = ref.watch(currentMediaProvider).value;
    if (item == null) return const SizedBox.shrink();
    final explicit = item.extras?['explicit'] == true;
    final state = ref.watch(playbackStateProvider).value;
    final phase = playbackUiPhaseFor(state);
    final playing = state?.playing == true;
    final canToggle = phase.canToggle(playing: playing);
    final actionLabel = phase.actionLabel(playing: playing);
    final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final duration =
        ref.watch(playbackDurationProvider).value ??
        item.duration ??
        Duration.zero;
    final ratio = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final height = _miniPlayerHeight(context);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: Material(
              color: AppConstants.elevated.withValues(alpha: 0.98),
              shape: const CutCornerBorder(
                cut: 14,
                side: BorderSide(color: AppConstants.hairline),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                height: height,
                child: Stack(
                  children: [
                    Row(
                      children: [
                        Container(width: 3, color: phase.color),
                        Expanded(
                          child: Semantics(
                            button: true,
                            label:
                                'Open Now Playing. ${item.title}${explicit ? ', explicit' : ''}. ${phase.semanticStatus}',
                            excludeSemantics: true,
                            onTap: () => context.push('/player'),
                            child: InkWell(
                              onTap: () => context.push('/player'),
                              child: Row(
                                children: [
                                  const SizedBox(width: 6),
                                  EpisodeArtworkById(
                                    episodeId: item.id,
                                    fallbackUrl: item.artUri?.toString(),
                                    size: 54,
                                    radius: 4,
                                  ),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        EpisodeTitle(
                                          title: item.title,
                                          explicit: explicit,
                                          maxLines: 1,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          phase.isError
                                              ? 'Couldn’t play'
                                              : item.album ?? phase.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: phase.isError
                                                    ? AppConstants.danger
                                                    : AppConstants
                                                          .secondaryText,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Tooltip(
                          message: actionLabel,
                          excludeFromSemantics: true,
                          child: Semantics(
                            button: true,
                            enabled: canToggle,
                            label: actionLabel,
                            excludeSemantics: true,
                            onTap: canToggle
                                ? () => _togglePlayback(context, ref, playing)
                                : null,
                            child: Material(
                              color: phase.isError
                                  ? AppConstants.danger
                                  : AppConstants.cyan,
                              shape: const CutCornerBorder(cut: 9),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: canToggle
                                    ? () =>
                                          _togglePlayback(context, ref, playing)
                                    : null,
                                child: SizedBox.square(
                                  dimension: 52,
                                  child: phase.isBusy
                                      ? Center(
                                          child: SizedBox.square(
                                            dimension: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.5,
                                              color: playing
                                                  ? AppConstants.background
                                                  : AppConstants.secondaryText,
                                            ),
                                          ),
                                        )
                                      : Icon(
                                          phase.isError
                                              ? Icons.refresh_rounded
                                              : playing
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          color: AppConstants.background,
                                          size: 30,
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                      ],
                    ),
                    Positioned(
                      left: 3,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: phase.isBusy ? null : ratio,
                        minHeight: 2,
                        backgroundColor: Colors.transparent,
                        color: phase.color,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _togglePlayback(
    BuildContext context,
    WidgetRef ref,
    bool playing,
  ) async {
    try {
      if (playing) {
        await ref.read(audioHandlerProvider).pause();
      } else {
        await ref.read(audioHandlerProvider).play();
      }
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }
}

double _miniPlayerHeight(BuildContext context) {
  final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.2);
  return 66 + (textScale - 1) * 28;
}
