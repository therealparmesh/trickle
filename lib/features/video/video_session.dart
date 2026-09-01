import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/youtube_support.dart';

enum VideoPlaybackSource { privacyWrapper, officialYouTube, directMedia }

enum VideoPresentation { expanded, minimized, pictureInPicture }

enum VideoPictureInPictureExit { restored, dismissed }

enum VideoPictureInPictureExitAction { minimize, resumeInMiniPlayer, close }

VideoPictureInPictureExitAction videoPictureInPictureExitAction({
  required AppLifecycleState lifecycle,
  required VideoPictureInPictureExit exit,
  bool? backgroundedAtExit,
}) {
  if (exit == VideoPictureInPictureExit.restored) {
    return VideoPictureInPictureExitAction.minimize;
  }
  final backgrounded =
      backgroundedAtExit ??
      switch (lifecycle) {
        AppLifecycleState.resumed || AppLifecycleState.inactive => false,
        AppLifecycleState.hidden ||
        AppLifecycleState.paused ||
        AppLifecycleState.detached => true,
      };
  return backgrounded
      ? VideoPictureInPictureExitAction.close
      : VideoPictureInPictureExitAction.resumeInMiniPlayer;
}

bool shouldPauseVideoForLifecycle(
  AppLifecycleState lifecycle,
  VideoPresentation presentation,
) =>
    (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) &&
    presentation != VideoPresentation.pictureInPicture;

bool shouldAcceptVideoStateRevision({
  required int activeObserverToken,
  required int lastRevision,
  required int observerToken,
  required int revision,
}) => observerToken == activeObserverToken && revision > lastRevision;

bool shouldApplyVideoPlaybackState({
  required bool awaitingPictureInPictureResume,
  required bool isPictureInPictureResumeResult,
}) => !awaitingPictureInPictureResume || isPictureInPictureResumeResult;

extension VideoPlaybackSourceFallback on VideoPlaybackSource {
  VideoPlaybackSource? get fallbackAfterFailure => switch (this) {
    VideoPlaybackSource.privacyWrapper => VideoPlaybackSource.officialYouTube,
    VideoPlaybackSource.officialYouTube ||
    VideoPlaybackSource.directMedia => null,
  };
}

final class VideoSession {
  const VideoSession({
    required this.intentRevision,
    required this.articleId,
    required this.title,
    required this.sourceUri,
    required this.playbackUri,
    required this.presentation,
  });

  final int intentRevision;
  final String articleId;
  final String title;
  final Uri sourceUri;
  final Uri playbackUri;
  final VideoPresentation presentation;

  VideoPlaybackSource get initialPlaybackSource =>
      youtubeVideoId(sourceUri) == null
      ? VideoPlaybackSource.directMedia
      : VideoPlaybackSource.privacyWrapper;

  Uri? playbackUriFor(VideoPlaybackSource source) => switch (source) {
    VideoPlaybackSource.privacyWrapper =>
      privacyYouTubePlaybackUri(sourceUri) ?? playbackUri,
    VideoPlaybackSource.officialYouTube => officialYouTubePlaybackUri(
      sourceUri,
    ),
    VideoPlaybackSource.directMedia => playbackUri,
  };

  VideoSession copyWith({VideoPresentation? presentation}) => VideoSession(
    intentRevision: intentRevision,
    articleId: articleId,
    title: title,
    sourceUri: sourceUri,
    playbackUri: playbackUri,
    presentation: presentation ?? this.presentation,
  );
}

final videoSessionProvider =
    NotifierProvider<VideoSessionNotifier, VideoSession?>(
      VideoSessionNotifier.new,
    );

final class VideoSessionNotifier extends Notifier<VideoSession?> {
  @override
  VideoSession? build() => null;

  void open({
    required int intentRevision,
    required String articleId,
    required String title,
    required Uri sourceUri,
    required Uri playbackUri,
  }) {
    state = VideoSession(
      intentRevision: intentRevision,
      articleId: articleId,
      title: title,
      sourceUri: sourceUri,
      playbackUri: playbackUri,
      presentation: VideoPresentation.expanded,
    );
  }

  void expand() {
    final current = state;
    if (current != null &&
        current.presentation == VideoPresentation.minimized) {
      state = current.copyWith(presentation: VideoPresentation.expanded);
    }
  }

  void minimize() {
    final current = state;
    if (current != null && current.presentation == VideoPresentation.expanded) {
      state = current.copyWith(presentation: VideoPresentation.minimized);
    }
  }

  void enterPictureInPicture() {
    final current = state;
    if (current == null ||
        current.presentation == VideoPresentation.pictureInPicture) {
      return;
    }
    state = current.copyWith(presentation: VideoPresentation.pictureInPicture);
  }

  void leavePictureInPicture() {
    final current = state;
    if (current?.presentation == VideoPresentation.pictureInPicture) {
      state = current!.copyWith(presentation: VideoPresentation.minimized);
    }
  }

  void close() => state = null;
}
