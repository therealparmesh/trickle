import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/app/trickle_app.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/repositories/playback_source_resolver.dart';
import 'package:trickle/data/repositories/settings_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/features/downloads/download_coordinator.dart';
import 'package:trickle/presentation/widgets/add_feed_dialog.dart';
import 'package:trickle/services/incoming_share_service.dart';
import 'package:trickle/services/notification_service.dart';
import 'package:trickle/services/sync_coordinator.dart';

import 'support/playback_harness.dart';
import 'support/unused_downloader.dart';

void main() {
  testWidgets(
    'a warm share opens without another resume or a duplicate dialog',
    (tester) async {
      const channel = MethodChannel('com.parmscript.trickle/incoming-share');
      const codec = StandardMethodCodec();
      final messenger = tester.binding.defaultBinaryMessenger;
      String? pending;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'takePendingText') throw MissingPluginException();
        final text = pending;
        pending = null;
        return text;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final harness = (await tester.runAsync(
        () async => createPlaybackHarness(),
      ))!;
      final secrets = PrivateFeedStore();
      final settings = SettingsRepository(harness.database);
      final downloads = DownloadCoordinator(
        database: harness.database,
        sources: PlaybackSourceResolver(
          harness.database,
          secrets,
          harness.network,
        ),
        settings: settings,
        downloader: UnusedDownloader(),
      );
      final sync = SyncCoordinator(
        database: harness.database,
        feeds: FeedRepository(
          database: harness.database,
          network: harness.network,
          privateFeeds: secrets,
        ),
        downloads: downloads,
        audio: harness.handler,
        notifications: NotificationService(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(harness.database),
            audioHandlerProvider.overrideWithValue(harness.handler),
            recentEpisodesProvider.overrideWith((_) => Stream.value(const [])),
            recentArticlesProvider.overrideWith((_) => Stream.value(const [])),
            feedsProvider.overrideWith((_) => Stream.value(const [])),
            newEpisodeCountProvider.overrideWith((_) => Stream.value(0)),
            unreadArticleCountProvider.overrideWith((_) => Stream.value(0)),
          ],
          child: TrickleApp(sync: sync, onDispose: () async {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsOneWidget);

      Future<void> share(String url) async {
        pending = url;
        await messenger.handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(const MethodCall('shareAvailable')),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      const first = 'https://example.test/first.xml';
      const second = 'https://example.test/second.xml';
      try {
        await share(first);
        expect(find.text(first), findsOneWidget);
        await share(second);
        expect(find.text(first), findsOneWidget);
        expect(find.text(second), findsNothing);
        Navigator.of(tester.element(find.byType(AddFeedDialog))).pop();
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text(second), findsOneWidget);
        Navigator.of(tester.element(find.byType(AddFeedDialog))).pop();
        await tester.pumpAndSettle();
        expect(find.byType(AddFeedDialog), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
        await tester.runAsync(() async {
          await downloads.dispose();
          await disposePlaybackHarness(harness);
        });
      }
    },
  );

  test('shared text preserves URLs and extracts addresses from prose', () {
    for (final url in [
      'https://example.test/feed?token=abc!',
      'https://example.test/feed_(private)',
      'https://example.test/feed?token=abc;',
    ]) {
      expect(feedInputFromSharedText('  $url  '), url);
    }
    expect(
      feedInputFromSharedText(
        'Worth following: (https://example.test/feed.xml). Sent from Safari',
      ),
      'https://example.test/feed.xml',
    );
    expect(
      feedInputFromSharedText(
        'Profile nprofile1qqsp9z7s4s2z7s4s2z7s4s2z7s4s2z7s4s2z7s4s2z7s4s2z7s4s2z7',
      ),
      startsWith('nprofile1'),
    );
    expect(
      feedInputFromSharedText('“https://example.test/feed.xml”'),
      'https://example.test/feed.xml',
    );
    expect(
      feedInputFromSharedText(
        'Profile npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq https://example.test/profile.xml',
      ),
      'https://example.test/profile.xml',
    );
    expect(feedInputFromSharedText('   '), isNull);
  });
}
