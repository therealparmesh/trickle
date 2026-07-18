import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/core/formatters.dart';
import 'package:trickle/core/playback_rules.dart';
import 'package:trickle/core/url_identity.dart';

void main() {
  group('played threshold', () {
    test('handles short, long, and unknown-duration episodes', () {
      const duration = Duration(minutes: 20);
      expect(
        isPlaybackComplete(const Duration(minutes: 18, seconds: 59), duration),
        isFalse,
      );
      expect(isPlaybackComplete(const Duration(minutes: 19), duration), isTrue);
      const longDuration = Duration(hours: 2);
      expect(
        isPlaybackComplete(
          const Duration(hours: 1, minutes: 58, seconds: 59),
          longDuration,
        ),
        isFalse,
      );
      expect(
        isPlaybackComplete(const Duration(hours: 1, minutes: 59), longDuration),
        isTrue,
      );
      expect(
        isPlaybackComplete(const Duration(hours: 4), Duration.zero),
        isFalse,
      );
    });
  });

  group('interruption resume intent', () {
    test('explicit intent wins and otherwise falls back to player state', () {
      for (final scenario in const [
        (playing: false, requested: true, expected: true),
        (playing: false, requested: false, expected: false),
        (playing: true, requested: false, expected: false),
        (playing: true, requested: null, expected: true),
      ]) {
        expect(
          shouldResumeAfterInterruption(
            playing: scenario.playing,
            playRequested: scenario.requested,
          ),
          scenario.expected,
        );
      }
    });

    test('only removed current or pending episodes invalidate playback', () {
      expect(
        removedEpisodesAffectPlayback(
          removedEpisodeIds: {'other'},
          currentEpisodeId: 'current',
          pendingSelectionEpisodeId: 'pending-selection',
          pendingLoadEpisodeId: 'pending-load',
        ),
        isFalse,
      );
      expect(
        removedEpisodesAffectPlayback(
          removedEpisodeIds: {'current'},
          currentEpisodeId: 'current',
          pendingSelectionEpisodeId: null,
          pendingLoadEpisodeId: null,
        ),
        isTrue,
      );
      expect(
        removedEpisodesAffectPlayback(
          removedEpisodeIds: {'pending-selection'},
          currentEpisodeId: 'current',
          pendingSelectionEpisodeId: 'pending-selection',
          pendingLoadEpisodeId: null,
        ),
        isTrue,
      );
      expect(
        removedEpisodesAffectPlayback(
          removedEpisodeIds: {'pending-load'},
          currentEpisodeId: 'current',
          pendingSelectionEpisodeId: null,
          pendingLoadEpisodeId: 'pending-load',
        ),
        isTrue,
      );
    });
  });

  group('native completion events', () {
    test('accepts completion only for a loaded media item', () {
      expect(
        shouldHandlePlayerCompletion(
          completed: true,
          loadingMedia: false,
          hasMedia: true,
          playbackStarted: true,
          position: const Duration(minutes: 19),
          duration: const Duration(minutes: 20),
        ),
        isTrue,
      );
    });

    test('ignores initial and in-flight completion events', () {
      expect(
        shouldHandlePlayerCompletion(
          completed: true,
          loadingMedia: true,
          hasMedia: true,
          playbackStarted: true,
          position: const Duration(minutes: 19),
          duration: const Duration(minutes: 20),
        ),
        isFalse,
      );
      expect(
        shouldHandlePlayerCompletion(
          completed: true,
          loadingMedia: false,
          hasMedia: false,
          playbackStarted: true,
          position: const Duration(minutes: 19),
          duration: const Duration(minutes: 20),
        ),
        isFalse,
      );
      expect(
        shouldHandlePlayerCompletion(
          completed: false,
          loadingMedia: false,
          hasMedia: true,
          playbackStarted: true,
          position: const Duration(minutes: 19),
          duration: const Duration(minutes: 20),
        ),
        isFalse,
      );
      expect(
        shouldHandlePlayerCompletion(
          completed: true,
          loadingMedia: false,
          hasMedia: true,
          playbackStarted: false,
          position: const Duration(minutes: 19),
          duration: const Duration(minutes: 20),
        ),
        isFalse,
      );
      expect(
        shouldHandlePlayerCompletion(
          completed: true,
          loadingMedia: false,
          hasMedia: true,
          playbackStarted: true,
          position: Duration.zero,
          duration: const Duration(minutes: 20),
        ),
        isFalse,
      );
      expect(
        shouldHandlePlayerCompletion(
          completed: true,
          loadingMedia: false,
          hasMedia: true,
          playbackStarted: true,
          position: const Duration(minutes: 3),
          duration: Duration.zero,
        ),
        isTrue,
      );
    });

    test('uses feed duration when the native duration resets to zero', () {
      final duration = effectivePlaybackDuration(
        nativeDuration: Duration.zero,
        fallbackDuration: const Duration(minutes: 20),
      );

      expect(duration, const Duration(minutes: 20));
      expect(
        shouldHandlePlayerCompletion(
          completed: true,
          loadingMedia: false,
          hasMedia: true,
          playbackStarted: true,
          position: const Duration(minutes: 3),
          duration: duration,
        ),
        isFalse,
      );
      expect(
        shouldHandlePlayerCompletion(
          completed: true,
          loadingMedia: false,
          hasMedia: true,
          playbackStarted: true,
          position: const Duration(minutes: 19),
          duration: duration,
        ),
        isTrue,
      );
    });

    test('preserves final progress when a completed duration is unknown', () {
      expect(
        completedProgressDuration(
          position: const Duration(minutes: 37, seconds: 12),
          knownDuration: Duration.zero,
        ),
        const Duration(minutes: 37, seconds: 12),
      );
      expect(
        completedProgressDuration(
          position: const Duration(minutes: 37, seconds: 12),
          knownDuration: const Duration(minutes: 40),
        ),
        const Duration(minutes: 40),
      );
    });
  });

  group('outro skip', () {
    test('runs only for started current media inside the outro', () {
      expect(
        shouldHandleOutroSkip(
          loadingMedia: false,
          playbackStarted: true,
          position: const Duration(minutes: 19, seconds: 30),
          duration: const Duration(minutes: 20),
          outro: const Duration(seconds: 45),
        ),
        isTrue,
      );
      for (final state in const [
        (loading: true, started: true, position: Duration(minutes: 20)),
        (loading: false, started: false, position: Duration(minutes: 20)),
        (loading: false, started: true, position: Duration(minutes: 19)),
      ]) {
        expect(
          shouldHandleOutroSkip(
            loadingMedia: state.loading,
            playbackStarted: state.started,
            position: state.position,
            duration: const Duration(minutes: 20),
            outro: const Duration(seconds: 45),
          ),
          isFalse,
        );
      }
    });

    test('uses feed duration when the native duration resets to zero', () {
      final duration = effectivePlaybackDuration(
        nativeDuration: Duration.zero,
        fallbackDuration: const Duration(minutes: 20),
      );

      expect(
        shouldHandleOutroSkip(
          loadingMedia: false,
          playbackStarted: true,
          position: const Duration(minutes: 19, seconds: 20),
          duration: duration,
          outro: const Duration(seconds: 45),
        ),
        isTrue,
      );
    });
  });

  test('skip and checkpoint timings are exact', () {
    expect(AppConstants.rewind, const Duration(seconds: 15));
    expect(AppConstants.forward, const Duration(seconds: 30));
    expect(AppConstants.progressCheckpoint, const Duration(seconds: 15));
    expect(AppConstants.sleepFade, const Duration(seconds: 4));
  });

  test('compact durations never describe positive audio as zero minutes', () {
    expect(compactDuration(1), '<1m');
    expect(compactDuration(const Duration(seconds: 59).inMilliseconds), '<1m');
    expect(compactDuration(const Duration(minutes: 1).inMilliseconds), '1m');
  });

  test('refresh intervals use the declared hours', () {
    expect(RefreshInterval.hourly.duration, const Duration(hours: 1));
    expect(RefreshInterval.every3Hours.duration, const Duration(hours: 3));
    expect(RefreshInterval.every6Hours.duration, const Duration(hours: 6));
    expect(RefreshInterval.every12Hours.duration, const Duration(hours: 12));
    expect(RefreshInterval.daily.duration, const Duration(hours: 24));
  });

  group('public URL identity', () {
    test('preserves legitimate author and similarly named query fields', () {
      final identity = credentialAgnosticUrl(
        Uri.parse(
          'https://example.com/item?author=alice&authorship=staff&monkey=capuchin',
        ),
      );

      expect(
        identity,
        'https://example.com/item?author=alice&authorship=staff&monkey=capuchin',
      );
    });

    test('removes actual credential fields while retaining public fields', () {
      final identity = credentialAgnosticUrl(
        Uri.parse(
          'https://example.com/item?author=alice&auth_token=SECRET&basic_auth=SECRET&sig=SECRET',
        ),
      );

      expect(identity, 'https://example.com/item?author=alice');
      expect(
        credentialAgnosticUrl(
          Uri.parse('https://example.com/item?token=SECRET#player'),
        ),
        'https://example.com/item',
      );
    });
  });
}
