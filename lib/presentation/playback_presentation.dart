import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../data/database/app_database.dart';

enum EpisodeListeningState { newEpisode, inProgress, played }

EpisodeListeningState episodeListeningState(
  Episode episode,
  PlaybackProgressesData? progress,
) {
  if (episode.played || progress?.completed == true) {
    return EpisodeListeningState.played;
  }
  if ((progress?.positionMs ?? 0) > 0) {
    return EpisodeListeningState.inProgress;
  }
  return EpisodeListeningState.newEpisode;
}

double? episodeProgressFraction(
  Episode episode,
  PlaybackProgressesData? progress,
) {
  final position = progress?.positionMs ?? 0;
  final duration = progress?.durationMs ?? episode.durationMs ?? 0;
  if (position <= 0 || duration <= 0 || progress?.completed == true) {
    return null;
  }
  return (position / duration).clamp(0, 1);
}

extension EpisodeListeningStatePresentation on EpisodeListeningState {
  String get label => switch (this) {
    EpisodeListeningState.newEpisode => 'New',
    EpisodeListeningState.inProgress => 'In Progress',
    EpisodeListeningState.played => 'Played',
  };

  Color get color => switch (this) {
    EpisodeListeningState.newEpisode => AppConstants.magenta,
    EpisodeListeningState.inProgress => AppConstants.cyan,
    EpisodeListeningState.played => AppConstants.secondaryText,
  };
}

enum PlaybackUiPhase { loading, buffering, error, playing, paused }

PlaybackUiPhase playbackUiPhaseFor({
  required AudioProcessingState? processingState,
  required bool playing,
}) {
  if (processingState == null ||
      processingState == AudioProcessingState.loading) {
    return PlaybackUiPhase.loading;
  }
  if (processingState == AudioProcessingState.buffering) {
    return PlaybackUiPhase.buffering;
  }
  if (processingState == AudioProcessingState.error) {
    return PlaybackUiPhase.error;
  }
  return playing ? PlaybackUiPhase.playing : PlaybackUiPhase.paused;
}

extension PlaybackUiPhasePresentation on PlaybackUiPhase {
  String get label => switch (this) {
    PlaybackUiPhase.loading => 'Loading',
    PlaybackUiPhase.buffering => 'Buffering',
    PlaybackUiPhase.error => 'Playback error',
    PlaybackUiPhase.playing => 'Playing',
    PlaybackUiPhase.paused => 'Paused',
  };

  String get semanticStatus => switch (this) {
    PlaybackUiPhase.loading => 'Audio is loading.',
    PlaybackUiPhase.buffering => 'Playback is buffering.',
    PlaybackUiPhase.error => 'Playback error. Retry playback.',
    PlaybackUiPhase.playing => 'Playback is playing.',
    PlaybackUiPhase.paused => 'Playback is paused.',
  };

  Color get color => switch (this) {
    PlaybackUiPhase.loading => AppConstants.acid,
    PlaybackUiPhase.buffering || PlaybackUiPhase.playing => AppConstants.cyan,
    PlaybackUiPhase.error => AppConstants.danger,
    PlaybackUiPhase.paused => AppConstants.magenta,
  };

  bool get isBusy =>
      this == PlaybackUiPhase.loading || this == PlaybackUiPhase.buffering;

  bool get isError => this == PlaybackUiPhase.error;

  bool canToggle({required bool playing}) => !isBusy || playing;

  String actionLabel({required bool playing}) {
    if (isError) return 'Retry playback';
    if (playing) return 'Pause';
    return switch (this) {
      PlaybackUiPhase.loading => 'Loading audio',
      PlaybackUiPhase.buffering => 'Buffering audio',
      _ => 'Play',
    };
  }
}
