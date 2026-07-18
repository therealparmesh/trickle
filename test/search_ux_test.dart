import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/app/theme.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/repositories/podcast_search_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/presentation/pages/podcasts_page.dart';
import 'package:trickle/presentation/pages/search_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'catalog subscription survives a new search and keeps its row identified',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final searchNetwork = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _CatalogAdapter(),
        addressValidator: (_) async {},
      );
      final feedAdapter = _BlockingFeedAdapter();
      final feedNetwork = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = feedAdapter,
        addressValidator: (_) async {},
      );
      final repository = FeedRepository(
        database: database,
        network: feedNetwork,
        privateFeeds: PrivateFeedStore(storage: const FlutterSecureStorage()),
      );
      final router = GoRouter(
        initialLocation: '/search',
        routes: [
          GoRoute(
            path: '/search',
            builder: (_, _) => const SearchPage(initialCatalog: true),
          ),
          GoRoute(
            path: '/podcast/:id',
            builder: (_, _) => const Scaffold(body: Text('Podcast detail')),
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        searchNetwork.close();
        feedNetwork.close();
        await database.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            podcastSearchProvider.overrideWithValue(
              PodcastSearchRepository(database, searchNetwork),
            ),
            feedRepositoryProvider.overrideWithValue(repository),
            remoteImagesProvider.overrideWith((_) => Stream.value(false)),
          ],
          child: MaterialApp.router(
            theme: TrickleTheme.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText), 'signal');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.text('Explicit Signal'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);
      await tester.tap(find.text('Subscribe'));
      for (
        var attempt = 0;
        attempt < 10 && !feedAdapter.started.isCompleted;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(feedAdapter.started.isCompleted, isTrue);
      expect(find.text('Subscribing…'), findsOneWidget);

      await tester.enterText(find.byType(EditableText), 'another search');
      await tester.pump();
      expect(
        find.text('Explicit Signal'),
        findsNothing,
        reason: 'results from the previous query must not remain actionable',
      );
      feedAdapter.release.complete();
      for (
        var attempt = 0;
        attempt < 30 && find.text('Podcast detail').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }

      expect(find.text('Podcast detail'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('add feed rejects malformed addresses before subscribing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: const Scaffold(body: AddFeedDialog()),
      ),
    );

    await tester.enterText(find.byType(EditableText), 'ftp://example.com/feed');
    await tester.tap(find.text('Subscribe'));
    await tester.pump();
    expect(find.text('Use an HTTP or HTTPS address.'), findsOneWidget);

    await tester.enterText(
      find.byType(EditableText),
      'https://user:password@example.com/feed',
    );
    await tester.tap(find.text('Subscribe'));
    await tester.pump();
    expect(
      find.text(
        'Remove the username and password from the URL. Use the Private feed fields instead.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

final class _CatalogAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '''
      {
        "results": [
          {
            "collectionName": "Explicit Signal",
            "artistName": "trickle tests",
            "feedUrl": "https://example.test/feed.xml",
            "trackCount": 12,
            "collectionExplicitness": "explicit"
          }
        ]
      }
      ''',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _BlockingFeedAdapter implements HttpClientAdapter {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return ResponseBody.fromString(
      '''
      <rss version="2.0">
        <channel>
          <title>Explicit Signal</title>
          <item>
            <guid>episode-1</guid>
            <title>First episode</title>
            <enclosure
              url="https://example.test/audio.mp3"
              type="audio/mpeg"
            />
          </item>
        </channel>
      </rss>
      ''',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/rss+xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
