import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/youtube_support.dart';

enum VideoPlaybackSource { privacyWrapper, officialYouTube }

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
    required this.expanded,
  });

  final String articleId;
  final String title;
  final Uri sourceUri;
  final Uri playbackUri;
  final bool expanded;

  Uri? playbackUriFor(VideoPlaybackSource source) => switch (source) {
    VideoPlaybackSource.privacyWrapper => playbackUri,
    VideoPlaybackSource.officialYouTube => officialYouTubePlaybackUri(
      sourceUri,
    ),
  };

  VideoSession copyWith({bool? expanded}) => VideoSession(
    articleId: articleId,
    title: title,
    sourceUri: sourceUri,
    playbackUri: playbackUri,
    expanded: expanded ?? this.expanded,
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
      expanded: true,
    );
  }

  void expand() {
    final current = state;
    if (current != null && !current.expanded) {
      state = current.copyWith(expanded: true);
    }
  }

  void minimize() {
    final current = state;
    if (current != null && current.expanded) {
      state = current.copyWith(expanded: false);
    }
  }

  void close() => state = null;
}
