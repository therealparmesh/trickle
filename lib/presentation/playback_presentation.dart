import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';

enum PlaybackUiPhase { loading, buffering, error, playing, paused }

PlaybackUiPhase playbackUiPhaseFor(PlaybackState? state) {
  final processingState = state?.processingState;
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
  return state?.playing == true
      ? PlaybackUiPhase.playing
      : PlaybackUiPhase.paused;
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
