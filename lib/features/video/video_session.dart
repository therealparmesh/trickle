import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/youtube_support.dart';

enum VideoPlaybackSource { privacyWrapper, officialYouTube }

enum VideoPresentation { expanded, minimized, pictureInPicture }

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

extension VideoPlaybackSourceFallback on VideoPlaybackSource {
  VideoPlaybackSource? get fallbackAfterFailure => switch (this) {
    VideoPlaybackSource.privacyWrapper => VideoPlaybackSource.officialYouTube,
    VideoPlaybackSource.officialYouTube => null,
  };
}

final class VideoSession {
  const VideoSession({
    required this.articleId,
    required this.title,
    required this.sourceUri,
    required this.playbackUri,
    required this.presentation,
  });

  final String articleId;
  final String title;
  final Uri sourceUri;
  final Uri playbackUri;
  final VideoPresentation presentation;

  Uri? playbackUriFor(VideoPlaybackSource source) => switch (source) {
    VideoPlaybackSource.privacyWrapper => playbackUri,
    VideoPlaybackSource.officialYouTube => officialYouTubePlaybackUri(
      sourceUri,
    ),
  };

  VideoSession copyWith({VideoPresentation? presentation}) => VideoSession(
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
    required String articleId,
    required String title,
    required Uri sourceUri,
    required Uri playbackUri,
  }) {
    state = VideoSession(
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
