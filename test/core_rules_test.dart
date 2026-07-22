import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/core/formatters.dart';
import 'package:trickle/core/playback_rules.dart';
import 'package:trickle/core/url_identity.dart';

void main() {
  test('metadata lines omit blank and repeated values', () {
    expect(metadataLine(['Signal', ' signal ', '', null, '2h']), 'Signal · 2h');
  });

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

    test('completion uses feed duration after native duration resets', () {
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

    test('outro skip uses feed duration after native duration resets', () {
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

  test('network and refresh deadlines use the standard timing tiers', () {
    expect(AppConstants.shortOperationTimeout, const Duration(seconds: 3));
    expect(AppConstants.networkConnectionTimeout, const Duration(seconds: 10));
    expect(AppConstants.interactiveRequestTimeout, const Duration(seconds: 15));
    expect(AppConstants.contentRequestTimeout, const Duration(seconds: 30));
    expect(
      AppConstants.videoSourceLoadTimeout,
      AppConstants.networkConnectionTimeout,
    );
    expect(
      AppConstants.backgroundRefreshBudget,
      AppConstants.interactiveRequestTimeout,
    );
    expect(AppConstants.feedRefreshTimeout, AppConstants.contentRequestTimeout);
    expect(
      AppConstants.opmlImportFeedTimeout,
      AppConstants.contentRequestTimeout,
    );
  });

  test('playback and persistence timings are exact product rules', () {
    expect(AppConstants.rewind, const Duration(seconds: 15));
    expect(AppConstants.forward, const Duration(seconds: 30));
    expect(AppConstants.progressCheckpoint, const Duration(seconds: 15));
    expect(AppConstants.playbackPositionThreshold, const Duration(seconds: 10));
    expect(AppConstants.playbackCompletionWindow, const Duration(minutes: 1));
    expect(AppConstants.sleepFade, const Duration(seconds: 4));
    expect(AppConstants.sleepStatusUpdate, const Duration(seconds: 30));
    expect(
      AppConstants.downloadProgressWriteInterval,
      const Duration(seconds: 2),
    );
    expect(AppConstants.databaseLockTimeout, const Duration(seconds: 5));
  });

  test('compact durations never describe positive audio as zero minutes', () {
    expect(compactDuration(1), '<1m');
    expect(compactDuration(const Duration(seconds: 59).inMilliseconds), '<1m');
    expect(compactDuration(const Duration(minutes: 1).inMilliseconds), '1m');
  });

  test('settings expose the exact cleanup and refresh choices', () {
    expect(AutoDeletePolicy.values, const [
      AutoDeletePolicy.immediately,
      AutoDeletePolicy.after1Day,
      AutoDeletePolicy.after1Week,
    ]);
    expect(
      RefreshInterval.values
          .map((interval) => (interval.duration, interval.label))
          .toList(),
      const [
        (Duration(hours: 1), '1 hour'),
        (Duration(hours: 2), '2 hours'),
        (Duration(hours: 4), '4 hours'),
        (Duration(hours: 8), '8 hours'),
        (Duration(hours: 12), '12 hours'),
        (Duration(days: 1), '1 day'),
        (Duration(days: 7), '1 week'),
      ],
    );
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
