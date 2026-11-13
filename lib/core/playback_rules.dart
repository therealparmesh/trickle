import 'dart:math' as math;

import 'constants.dart';

/// An episode is complete inside the smaller of its final 60 seconds or 5%.
bool isPlaybackComplete(Duration position, Duration duration) {
  if (duration <= Duration.zero) return false;
  final fivePercent = (duration.inMilliseconds * 0.05).round();
  final remainingWindow = math.min(
    AppConstants.playbackCompletionWindow.inMilliseconds,
    fivePercent,
  );
  return position.inMilliseconds >= duration.inMilliseconds - remainingWindow;
}

/// Prefers the native player's duration but preserves a feed-provided fallback
/// while the backend is opening or cannot discover a duration of its own.
Duration effectivePlaybackDuration({
  required Duration nativeDuration,
  Duration? fallbackDuration,
}) => nativeDuration > Duration.zero
    ? nativeDuration
    : fallbackDuration ?? Duration.zero;

/// Produces a non-zero completed duration for streams whose length was never
/// known by using the final playback position as the best available value.
Duration completedProgressDuration({
  required Duration position,
  required Duration knownDuration,
}) => knownDuration > Duration.zero
    ? knownDuration
    : position > Duration.zero
    ? position
    : Duration.zero;

/// Allows one recovery attempt only when requested playback stopped before the
/// episode finished. Explicit pauses, source changes, and completion handling
/// must never restart audio.
bool shouldRecoverUnexpectedPlaybackStop({
  required bool playRequested,
  required bool playerPlaying,
  required bool loadingMedia,
  required bool handlingCompletion,
  required bool terminalState,
  required Duration position,
  required Duration duration,
}) =>
    playRequested &&
    !playerPlaying &&
    !loadingMedia &&
    !handlingCompletion &&
    !terminalState &&
    (duration <= Duration.zero || position < duration);

/// A native completion must belong to started audio that reached the end.
bool shouldHandlePlayerCompletion({
  required bool completed,
  required bool playbackStarted,
  required Duration position,
  required Duration duration,
}) =>
    completed &&
    playbackStarted &&
    (duration > Duration.zero
        ? isPlaybackComplete(position, duration)
        : position > Duration.zero);

/// Whether the current position has entered this episode's configured outro.
bool shouldHandleOutroSkip({
  required bool playbackStarted,
  required Duration position,
  required Duration duration,
  required Duration outro,
}) =>
    playbackStarted &&
    outro > Duration.zero &&
    duration > outro &&
    position >= duration - outro;

/// Whether removing library episodes invalidates the active or pending
/// playback selection.
bool removedEpisodesAffectPlayback({
  required Set<String> removedEpisodeIds,
  required String? currentEpisodeId,
  required String? pendingSelectionEpisodeId,
  required String? pendingLoadEpisodeId,
}) =>
    (currentEpisodeId != null &&
        removedEpisodeIds.contains(currentEpisodeId)) ||
    (pendingSelectionEpisodeId != null &&
        removedEpisodeIds.contains(pendingSelectionEpisodeId)) ||
    (pendingLoadEpisodeId != null &&
        removedEpisodeIds.contains(pendingLoadEpisodeId));
