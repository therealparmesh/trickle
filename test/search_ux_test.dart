import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/app/theme.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/repositories/podcast_search_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/presentation/pages/podcasts_page.dart';
import 'package:trickle/presentation/pages/feed_detail_page.dart';
import 'package:trickle/presentation/pages/search_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'catalog subscription affects only its row and keeps search usable',
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
      final now = DateTime.utc(2026, 7, 18);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'existing',
              title: 'Existing Signal',
              feedUrl: 'http://existing.test/feed.xml#catalog',
              kind: Value(FeedKind.podcast.index),
              createdAt: now,
              updatedAt: now,
            ),
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
          GoRoute(
            path: '/podcast-preview',
            builder: (_, _) => const Scaffold(body: Text('Podcast preview')),
          ),
        ],
      );
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
      expect(find.text('Second Signal'), findsOneWidget);
      expect(find.text('Existing Signal'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);
      final firstRow = find.ancestor(
        of: find.text('Explicit Signal'),
        matching: find.byType(ListTile),
      );
      final secondRow = find.ancestor(
        of: find.text('Second Signal'),
        matching: find.byType(ListTile),
      );
      final existingRow = find.ancestor(
        of: find.text('Existing Signal'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: existingRow, matching: find.text('Unsubscribe')),
        findsOneWidget,
      );
      await tester.tap(find.text('Second Signal'));
      await tester.pumpAndSettle();
      expect(find.text('Podcast preview'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(of: firstRow, matching: find.text('Subscribe')),
      );
      for (
        var attempt = 0;
        attempt < 10 && !feedAdapter.started.isCompleted;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(feedAdapter.started.isCompleted, isTrue);
      expect(
        find.descendant(
          of: firstRow,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      final firstButton = tester.widget<TextButton>(
        find.descendant(of: firstRow, matching: find.byType(TextButton)),
      );
      expect(firstButton.onPressed, isNull);
      expect(
        find.descendant(of: firstRow, matching: find.text('Subscribe')),
        findsOneWidget,
      );
      final secondButton = tester.widget<TextButton>(
        find.descendant(of: secondRow, matching: find.byType(TextButton)),
      );
      expect(secondButton.onPressed, isNotNull);
      expect(
        find.descendant(of: secondRow, matching: find.text('Subscribe')),
        findsOneWidget,
      );

      feedAdapter.release.complete();
      for (
        var attempt = 0;
        attempt < 30 &&
            find
                .descendant(of: firstRow, matching: find.text('Unsubscribe'))
                .evaluate()
                .isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }

      expect(
        find.descendant(of: firstRow, matching: find.text('Unsubscribe')),
        findsOneWidget,
      );
      expect(find.text('Search'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      router.dispose();
      searchNetwork.close();
      feedNetwork.close();
      await database.close();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('catalog rows preserve titles and actions at large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _CatalogAdapter(),
      addressValidator: (_) async {},
    );
    final router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(
          path: '/search',
          builder: (_, _) => const SearchPage(initialCatalog: true),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          podcastSearchProvider.overrideWithValue(
            PodcastSearchRepository(database, network),
          ),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
        ],
        child: MaterialApp.router(
          theme: TrickleTheme.dark,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(3.2)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(EditableText), 'signal');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text('Explicit Signal'));
    expect(title.maxLines, 4);
    expect(find.text('Subscribe'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    router.dispose();
    network.close();
    await database.close();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('podcast detail can unsubscribe and resubscribe in place', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _ImmediateFeedAdapter(),
      addressValidator: (_) async {},
    );
    final repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: PrivateFeedStore(storage: const FlutterSecureStorage()),
    );
    final now = DateTime.utc(2026, 7, 22);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'podcast',
            title: 'Signal Podcast',
            feedUrl: 'https://resubscribe.test/feed.xml',
            kind: Value(FeedKind.podcast.index),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          feedRepositoryProvider.overrideWithValue(repository),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: const FeedDetailPage(feedId: 'podcast'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Subscribed'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Unsubscribe'));
    await tester.pumpAndSettle();

    expect(find.text('Subscribe'), findsOneWidget);
    expect(find.text('Subscribe to load episodes'), findsOneWidget);

    await tester.tap(find.text('Subscribe'));
    for (
      var attempt = 0;
      attempt < 30 && find.text('Subscribed').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('Subscribed'), findsOneWidget);
    for (
      var attempt = 0;
      attempt < 10 && find.text('First episode').evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('First episode'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    network.close();
    await database.close();
  });

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

  testWidgets('add YouTube feed uses focused copy and rejects other hosts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: const Scaffold(body: AddFeedDialog.youtube()),
      ),
    );

    expect(find.text('Add YouTube feed'), findsOneWidget);
    expect(
      find.text(
        'Paste a public YouTube channel or playlist. trickle finds its feed automatically.',
      ),
      findsOneWidget,
    );
    expect(find.text('Private feed'), findsNothing);

    await tester.enterText(
      find.byType(EditableText),
      'https://example.com/channel',
    );
    await tester.tap(find.text('Subscribe'));
    await tester.pump();
    expect(
      find.text('Enter a YouTube channel, playlist, or YouTube Atom feed URL.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a feed subscription does not trap the add dialog', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final adapter = _BlockingFeedAdapter();
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    final repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: PrivateFeedStore(storage: const FlutterSecureStorage()),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [feedRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AddFeedDialog(),
                ),
                child: const Text('Open add feed'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open add feed'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(EditableText),
      'https://example.test/feed.xml',
    );
    await tester.tap(find.text('Subscribe'));
    for (
      var attempt = 0;
      attempt < 10 && !adapter.started.isCompleted;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(find.text('Subscribing…'), findsOneWidget);
    final cancel = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Cancel'),
    );
    expect(cancel.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AddFeedDialog), findsNothing);

    adapter.release.complete();
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      final subscribed = await tester.runAsync(
        () => database.select(database.feeds).get(),
      );
      if (subscribed?.isNotEmpty == true) break;
    }
    expect(await database.select(database.feeds).get(), isNotEmpty);
    expect(tester.takeException(), isNull);
    network.close();
    await database.close();
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
          },
          {
            "collectionName": "Second Signal",
            "artistName": "trickle tests",
            "feedUrl": "https://second.test/feed.xml",
            "trackCount": 4,
            "collectionExplicitness": "cleaned"
          },
          {
            "collectionName": "Existing Signal",
            "artistName": "trickle tests",
            "feedUrl": "https://existing.test/feed.xml",
            "trackCount": 8,
            "collectionExplicitness": "cleaned"
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

final class _ImmediateFeedAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '''
      <rss version="2.0">
        <channel>
          <title>Signal Podcast</title>
          <item>
            <guid>episode-1</guid>
            <title>First episode</title>
            <enclosure
              url="https://resubscribe.test/audio.mp3"
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
