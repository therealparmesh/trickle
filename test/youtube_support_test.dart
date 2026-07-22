import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
      expanded: true,
      externalPresentation: false,
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

  test('video stays in one session across mini-player and system PiP', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(videoSessionProvider.notifier);
    notifier.open(
      articleId: 'video',
      title: 'Video',
      sourceUri: Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
      playbackUri: Uri.parse('https://www.yout-ube.com/watch?v=dQw4w9WgXcQ'),
    );

    expect(container.read(videoSessionProvider)?.expanded, isTrue);
    notifier.minimize();
    expect(container.read(videoSessionProvider)?.expanded, isFalse);
    notifier.expand();
    expect(container.read(videoSessionProvider)?.expanded, isTrue);

    notifier.setExternalPresentation(true);
    expect(container.read(videoSessionProvider)?.externalPresentation, isTrue);
    expect(container.read(videoSessionProvider)?.expanded, isFalse);

    notifier.setExternalPresentation(false);
    expect(container.read(videoSessionProvider)?.externalPresentation, isFalse);
    expect(container.read(videoSessionProvider)?.expanded, isFalse);
  });
}
