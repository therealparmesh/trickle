import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:trickle/core/youtube_support.dart';
import 'package:trickle/features/video/video_session.dart';

void main() {
  group('YouTube feed discovery', () {
    test('canonicalizes channel, playlist, and direct feed addresses', () {
      expect(
        directYouTubeFeedUri(
          Uri.parse(
            'https://youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw/videos',
          ),
        ).toString(),
        'https://www.youtube.com/feeds/videos.xml?channel_id=UC_x5XG1OV2P6uZZ5FSM9Ttw',
      );
      expect(
        directYouTubeFeedUri(
          Uri.parse(
            'https://www.youtube.com/playlist?list=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
          ),
        ).toString(),
        'https://www.youtube.com/feeds/videos.xml?playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
      );
      expect(
        directYouTubeFeedUri(
          Uri.parse(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
          ),
        ).toString(),
        'https://www.youtube.com/feeds/videos.xml?playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
      );
      expect(
        directYouTubeFeedUri(
          Uri.parse(
            'https://youtu.be/dQw4w9WgXcQ?list=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
          ),
        ).toString(),
        'https://www.youtube.com/feeds/videos.xml?playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
      );
      expect(
        directYouTubeFeedUri(
          Uri.parse(
            'https://www.youtube.com/feeds/videos.xml?playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs&utm_source=ignored',
          ),
        ).toString(),
        'https://www.youtube.com/feeds/videos.xml?playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
      );
    });

    test('classifies channel and playlist feeds without false positives', () {
      expect(
        youtubeFeedKind(
          Uri.parse(
            'https://www.youtube.com/feeds/videos.xml?channel_id=UC_x5XG1OV2P6uZZ5FSM9Ttw',
          ),
        ),
        YouTubeFeedKind.channel,
      );
      expect(
        youtubeFeedKind(
          Uri.parse(
            'https://www.youtube.com/feeds/videos.xml?playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
          ),
        ),
        YouTubeFeedKind.playlist,
      );
      expect(
        youtubeFeedKind(Uri.parse('https://www.youtube.com/@trickle')),
        YouTubeFeedKind.channel,
      );
      expect(
        youtubeFeedKind(
          Uri.parse(
            'https://youtu.be/dQw4w9WgXcQ?list=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
          ),
        ),
        YouTubeFeedKind.playlist,
      );
      expect(
        youtubeFeedKind(Uri.parse('https://youtu.be/dQw4w9WgXcQ')),
        isNull,
      );
      expect(
        youtubeFeedKind(Uri.parse('https://example.com/@trickle')),
        isNull,
      );
    });

    test('discovers a handle page without relying on one metadata shape', () {
      final feed = discoverYouTubeFeedUri(
        Uri.parse('https://www.youtube.com/@GoogleDevelopers'),
        '''
          <html><head><meta itemprop="channelId"
          content="UC_x5XG1OV2P6uZZ5FSM9Ttw"></head></html>
        ''',
      );

      expect(
        feed.toString(),
        'https://www.youtube.com/feeds/videos.xml?channel_id=UC_x5XG1OV2P6uZZ5FSM9Ttw',
      );
    });

    test('discovers channel IDs from JSON and canonical page metadata', () {
      final page = Uri.parse('https://www.youtube.com/@signal');

      expect(
        discoverYouTubeFeedUri(
          page,
          '<script>{"externalId": "UCabcdefghijklmnopqrstuv"}</script>',
        ),
        Uri.parse(
          'https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv',
        ),
      );
      expect(
        discoverYouTubeFeedUri(
          page,
          '<link rel="canonical" '
          'href="https://www.youtube.com/channel/UCzyxwvutsrqponmlkjihgfe">',
        ),
        Uri.parse(
          'https://www.youtube.com/feeds/videos.xml?channel_id=UCzyxwvutsrqponmlkjihgfe',
        ),
      );
    });

    test('rejects unrelated and incomplete addresses', () {
      expect(
        directYouTubeFeedUri(Uri.parse('https://example.com/playlist?list=x')),
        isNull,
      );
      expect(
        directYouTubeFeedUri(Uri.parse('https://youtube.com/@handle')),
        isNull,
      );
      expect(
        discoverYouTubeFeedUri(
          Uri.parse('https://youtube.com/@handle'),
          '<html>missing channel id</html>',
        ),
        isNull,
      );
    });
  });

  test('maps supported video links to one playback address', () {
    for (final source in [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtu.be/dQw4w9WgXcQ?t=30',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
    ]) {
      expect(
        privacyYouTubePlaybackUri(Uri.parse(source)).toString(),
        'https://www.yout-ube.com/watch?v=dQw4w9WgXcQ',
      );
      expect(
        officialYouTubePlaybackUri(Uri.parse(source)).toString(),
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
    }
    expect(
      privacyYouTubePlaybackUri(Uri.parse('https://example.com/dQw4w9WgXcQ')),
      isNull,
    );
    expect(
      officialYouTubePlaybackUri(Uri.parse('https://example.com/dQw4w9WgXcQ')),
      isNull,
    );
  });

  test('video playback falls back once, to official YouTube', () {
    final source = Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    final session = VideoSession(
      articleId: 'video',
      title: 'Video',
      sourceUri: source,
      playbackUri: privacyYouTubePlaybackUri(source)!,
      presentation: VideoPresentation.expanded,
    );

    expect(
      session.playbackUriFor(VideoPlaybackSource.privacyWrapper),
      Uri.parse('https://www.yout-ube.com/watch?v=dQw4w9WgXcQ'),
    );
    expect(
      VideoPlaybackSource.privacyWrapper.fallbackAfterFailure,
      VideoPlaybackSource.officialYouTube,
    );
    expect(
      session.playbackUriFor(VideoPlaybackSource.officialYouTube),
      Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
    );
    expect(VideoPlaybackSource.officialYouTube.fallbackAfterFailure, isNull);
  });

  test('video presentation has one valid state through minimize and PiP', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(videoSessionProvider.notifier);
    notifier.open(
      articleId: 'video',
      title: 'Video',
      sourceUri: Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
      playbackUri: Uri.parse('https://www.yout-ube.com/watch?v=dQw4w9WgXcQ'),
    );

    expect(
      container.read(videoSessionProvider)?.presentation,
      VideoPresentation.expanded,
    );
    notifier.minimize();
    expect(
      container.read(videoSessionProvider)?.presentation,
      VideoPresentation.minimized,
    );
    notifier.expand();
    expect(
      container.read(videoSessionProvider)?.presentation,
      VideoPresentation.expanded,
    );

    notifier.enterPictureInPicture();
    expect(
      container.read(videoSessionProvider)?.presentation,
      VideoPresentation.pictureInPicture,
    );
    notifier.expand();
    expect(
      container.read(videoSessionProvider)?.presentation,
      VideoPresentation.pictureInPicture,
    );

    notifier.leavePictureInPicture();
    expect(
      container.read(videoSessionProvider)?.presentation,
      VideoPresentation.minimized,
    );
    notifier.close();
    expect(container.read(videoSessionProvider), isNull);
  });

  test('only Picture in Picture can continue while the app is hidden', () {
    for (final lifecycle in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      expect(
        shouldPauseVideoForLifecycle(lifecycle, VideoPresentation.expanded),
        isTrue,
      );
      expect(
        shouldPauseVideoForLifecycle(lifecycle, VideoPresentation.minimized),
        isTrue,
      );
      expect(
        shouldPauseVideoForLifecycle(
          lifecycle,
          VideoPresentation.pictureInPicture,
        ),
        isFalse,
      );
    }
    expect(
      shouldPauseVideoForLifecycle(
        AppLifecycleState.inactive,
        VideoPresentation.minimized,
      ),
      isFalse,
    );
  });

  test('video state ignores stale pages and out-of-order callbacks', () {
    for (final scenario in [
      (observerToken: 7, revision: 100, expected: false),
      (observerToken: 8, revision: 4, expected: false),
      (observerToken: 8, revision: 5, expected: true),
    ]) {
      expect(
        shouldAcceptVideoStateRevision(
          activeObserverToken: 8,
          lastRevision: 4,
          observerToken: scenario.observerToken,
          revision: scenario.revision,
        ),
        scenario.expected,
      );
    }
  });
}
