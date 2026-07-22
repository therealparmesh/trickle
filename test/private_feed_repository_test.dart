import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';

void main() {
  late AppDatabase database;
  late SafeNetworkClient network;
  late PrivateFeedStore privateFeeds;
  late FeedRepository repository;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final dio = Dio()..httpClientAdapter = _FeedAdapter();
    network = SafeNetworkClient.forTesting(dio, addressValidator: (_) async {});
    privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
  });

  tearDown(() async {
    network.close();
    await database.close();
  });

  test(
    'explicit private mode protects credentials embedded in a URL path',
    () async {
      const secretUrl = 'https://example.test/private/PATH_SECRET/feed.xml';

      final feed = await repository.subscribe(secretUrl, forcePrivate: true);
      final episode = (await database.select(database.episodes).get()).single;
      final secret = await privateFeeds.read(feed.credentialRef!);
      final mediaUrl = await privateFeeds.readMediaUrl(episode.id);
      final persistedRecords = jsonEncode({
        'feeds': [
          for (final row in await database.select(database.feeds).get())
            row.toJson(),
        ],
        'episodes': [
          for (final row in await database.select(database.episodes).get())
            row.toJson(),
        ],
        'articles': [
          for (final row in await database.select(database.articles).get())
            row.toJson(),
        ],
      });

      expect(feed.isPrivate, isTrue);
      expect(feed.feedUrl, startsWith('private://'));
      expect(feed.feedUrl, isNot(contains('PATH_SECRET')));
      expect(secret?.url.toString(), secretUrl);
      expect(episode.enclosureUrl, startsWith('private-media://'));
      expect(episode.enclosureUrl, isNot(contains('MEDIA_SECRET')));
      expect(mediaUrl?.queryParameters['token'], 'MEDIA_SECRET');
      expect(persistedRecords, isNot(contains('PATH_SECRET')));
      expect(persistedRecords, isNot(contains('MEDIA_SECRET')));
    },
  );

  test('a query-bearing feed URL is protected automatically', () async {
    const secretUrl = 'https://example.test/feed.xml?access_token=QUERY_SECRET';

    final feed = await repository.subscribe(secretUrl);
    final secret = await privateFeeds.read(feed.credentialRef!);

    expect(feed.isPrivate, isTrue);
    expect(feed.feedUrl, startsWith('private://'));
    expect(feed.feedUrl, isNot(contains('QUERY_SECRET')));
    expect(secret?.url.toString(), secretUrl);

    final rotated = await repository.subscribe(
      'https://example.test/feed.xml?access_token=REPLACEMENT_SECRET',
    );
    final updatedSecret = await privateFeeds.read(rotated.credentialRef!);
    expect(rotated.id, feed.id);
    expect(await database.select(database.feeds).get(), hasLength(1));
    expect(
      updatedSecret?.url.queryParameters['access_token'],
      'REPLACEMENT_SECRET',
    );
  });

  test('bounded refresh selects only feeds due before the cutoff', () async {
    final cutoff = DateTime.utc(2026, 7, 19, 12);
    Future<void> insertFeed(String id, DateTime? lastRefresh) {
      return database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: id,
              title: id,
              feedUrl: 'https://$id.example.test/feed.xml',
              lastRefresh: Value(lastRefresh),
              createdAt: cutoff,
              updatedAt: cutoff,
            ),
          );
    }

    await insertFeed('never-refreshed', null);
    await insertFeed('due', cutoff);
    await insertFeed('not-due', cutoff.add(const Duration(seconds: 1)));
    await insertFeed('future-clock', cutoff.add(const Duration(days: 1)));
    final progress = <(int, int)>[];

    await repository.refreshAll(
      budget: Duration.zero,
      dueAt: cutoff.add(const Duration(hours: 1)),
      minimumAge: const Duration(hours: 1),
      onProgress: (completed, total) => progress.add((completed, total)),
    );

    expect(progress, [(0, 3)]);
  });

  test('a signed redirect is not persisted as the refresh address', () async {
    network.close();
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _SignedRedirectAdapter(),
      addressValidator: (_) async {},
    );
    privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );

    final feed = await repository.subscribe(
      'https://example.test/discover.xml',
    );
    expect(feed.isPrivate, isFalse);
    expect(feed.credentialRef, isNull);
    expect(feed.feedUrl, 'https://example.test/discover.xml');
    expect(feed.feedUrl, isNot(contains('REDIRECT_SECRET')));
    expect(
      jsonEncode((await database.select(database.feeds).get()).single.toJson()),
      isNot(contains('REDIRECT_SECRET')),
    );
  });

  test('an imported podcast is stored only in the podcast library', () async {
    network.close();
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _PodcastWithTextItemAdapter(),
      addressValidator: (_) async {},
    );
    privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );

    final feed = await repository.subscribe('https://example.test/show.xml');

    expect(feed.kind, FeedKind.podcast.index);
    expect(await database.select(database.episodes).get(), hasLength(1));
    expect(await database.select(database.articles).get(), isEmpty);
    expect(await database.watchPodcastFeeds().first, hasLength(1));
    expect(await database.watchReaderFeeds().first, isEmpty);
  });

  test('a malformed refresh cannot erase or reclassify a podcast', () async {
    network.close();
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _PodcastThenArticleAdapter(),
      addressValidator: (_) async {},
    );
    privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
    final subscribed = await repository.subscribe(
      'https://example.test/show.xml',
    );

    expect(await repository.refreshFeed(subscribed), isTrue);

    final refreshed = await database.feedById(subscribed.id);
    expect(refreshed?.kind, FeedKind.podcast.index);
    expect(await database.select(database.episodes).get(), hasLength(1));
    expect(await database.select(database.articles).get(), isEmpty);
  });

  test(
    'not-modified refresh preserves content and coalesces duplicate requests',
    () async {
      network.close();
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase.memory());
      final adapter = _NotModifiedFeedAdapter();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = adapter,
        addressValidator: (_) async {},
      );
      privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );

      final subscribed = await repository.subscribe(
        'https://example.test/mixed.xml',
      );
      final articles = await database.select(database.articles).get();
      final article = articles.singleWhere((item) => item.guid == 'article-1');
      final readAt = DateTime.utc(2024, 1, 2, 3, 4, 5);
      await (database.update(
        database.articles,
      )..where((row) => row.id.equals(article.id))).write(
        ArticlesCompanion(readAt: Value(readAt), starred: const Value(true)),
      );
      final oldRefresh = DateTime.utc(2000, 1, 1);
      await (database.update(
        database.feeds,
      )..where((row) => row.id.equals(subscribed.id))).write(
        FeedsCompanion(
          lastRefresh: Value(oldRefresh),
          refreshError: const Value('Previous refresh failed.'),
        ),
      );
      final staleFeed = await database.feedById(subscribed.id);

      expect(await repository.refreshFeed(staleFeed!), isTrue);

      final refreshedFeed = await database.feedById(subscribed.id);
      final preservedArticle = await database.articleById(article.id);
      expect(refreshedFeed?.lastRefresh?.isAfter(oldRefresh), isTrue);
      expect(refreshedFeed?.refreshError, isNull);
      expect(refreshedFeed?.etag, '"mixed-v1"');
      expect(refreshedFeed?.lastModified, 'Wed, 01 Jan 2025 00:00:00 GMT');
      expect(await database.select(database.episodes).get(), isEmpty);
      expect(await database.select(database.articles).get(), hasLength(2));
      expect(preservedArticle?.readAt?.isAtSameMomentAs(readAt), isTrue);
      expect(preservedArticle?.starred, isTrue);
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.headers['If-None-Match'], '"mixed-v1"');
      expect(
        adapter.requests.last.headers['If-Modified-Since'],
        'Wed, 01 Jan 2025 00:00:00 GMT',
      );

      final requestsBeforeConcurrentRefresh = adapter.requests.length;
      expect(
        await Future.wait([
          repository.refreshFeed(refreshedFeed!),
          repository.refreshFeed(refreshedFeed),
        ]),
        everyElement(isTrue),
      );
      expect(adapter.requests, hasLength(requestsBeforeConcurrentRefresh + 1));
    },
  );

  test('an older failed refresh cannot overwrite a newer success', () async {
    final subscribed = await repository.subscribe(
      'https://example.test/feed.xml',
    );
    final failureAdapter = _BlockingFailureFeedAdapter();
    final failureNetwork = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = failureAdapter,
      addressValidator: (_) async {},
    );
    final successNetwork = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _AlwaysNotModifiedFeedAdapter(),
      addressValidator: (_) async {},
    );
    addTearDown(failureNetwork.close);
    addTearDown(successNetwork.close);
    final failureRepository = FeedRepository(
      database: database,
      network: failureNetwork,
      privateFeeds: privateFeeds,
    );
    final successRepository = FeedRepository(
      database: database,
      network: successNetwork,
      privateFeeds: privateFeeds,
    );

    final olderFailure = failureRepository.refreshFeed(subscribed);
    await failureAdapter.started.future;
    expect(await successRepository.refreshFeed(subscribed), isTrue);
    failureAdapter.release.complete();
    expect(await olderFailure, isFalse);

    final refreshed = await database.feedById(subscribed.id);
    expect(refreshed?.refreshError, isNull);
  });

  test('an older successful refresh cannot overwrite newer content', () async {
    final subscribed = await repository.subscribe(
      'https://example.test/feed.xml',
    );
    final olderAdapter = _BlockingSuccessfulFeedAdapter('Older response');
    final olderNetwork = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = olderAdapter,
      addressValidator: (_) async {},
    );
    final newerNetwork = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _FeedTitleAdapter('Newer response'),
      addressValidator: (_) async {},
    );
    addTearDown(olderNetwork.close);
    addTearDown(newerNetwork.close);
    final olderRepository = FeedRepository(
      database: database,
      network: olderNetwork,
      privateFeeds: privateFeeds,
    );
    final newerRepository = FeedRepository(
      database: database,
      network: newerNetwork,
      privateFeeds: privateFeeds,
    );

    final olderRefresh = olderRepository.refreshFeed(subscribed);
    await olderAdapter.started.future;
    expect(await newerRepository.refreshFeed(subscribed), isTrue);
    olderAdapter.release.complete();
    expect(await olderRefresh, isTrue);

    expect((await database.feedById(subscribed.id))?.title, 'Newer response');
  });

  test(
    'refresh uses current feed state when its caller has a stale row',
    () async {
      final subscribed = await repository.subscribe(
        'https://example.test/feed.xml',
      );
      await repository.updateFeedSettings(
        subscribed.id,
        autoDownload: true,
        autoDownloadLimit: 4,
        notifications: true,
        introSkipMs: 1000,
        outroSkipMs: 2000,
        autoQueue: true,
      );
      network.close();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _FeedTitleAdapter('Current response'),
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );

      expect(await repository.refreshFeed(subscribed), isTrue);

      final refreshed = await database.feedById(subscribed.id);
      expect(refreshed?.title, 'Current response');
      expect(refreshed?.autoDownload, isTrue);
      expect(refreshed?.autoDownloadLimit, 4);
      expect(refreshed?.notifications, isTrue);
      expect(refreshed?.introSkipMs, 1000);
      expect(refreshed?.outroSkipMs, 2000);
      expect(refreshed?.autoQueue, isTrue);
    },
  );

  test(
    'rotating private media tokens keep stable identities and subscriptions',
    () async {
      network.close();
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase.memory());
      final adapter = _RotatingFeedAdapter();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = adapter,
        addressValidator: (_) async {},
      );
      privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      const feedUrl =
          'https://example.test/private/feed.xml?token=SUBSCRIPTION_SECRET';

      final first = await repository.subscribe(feedUrl);
      final firstEpisode =
          (await database.select(database.episodes).get()).single;
      final firstCreatedAt = first.createdAt;
      expect(
        (await privateFeeds.readMediaUrl(
          firstEpisode.id,
        ))?.queryParameters['token'],
        'MEDIA_1',
      );

      expect(await repository.refreshFeed(first), isTrue);
      final refreshedFeed = await database.feedById(first.id);
      final refreshedEpisodes = await database.select(database.episodes).get();
      expect(refreshedEpisodes, hasLength(1));
      expect(refreshedEpisodes.single.id, firstEpisode.id);
      expect(refreshedFeed?.createdAt, firstCreatedAt);
      expect(
        (await privateFeeds.readMediaUrl(
          firstEpisode.id,
        ))?.queryParameters['token'],
        'MEDIA_2',
      );

      final duplicate = await repository.subscribe(feedUrl);
      expect(duplicate.id, first.id);
      expect(await database.select(database.feeds).get(), hasLength(1));
      expect(await database.select(database.episodes).get(), hasLength(1));
    },
  );

  test(
    'restores the previous feed secret when database storage fails',
    () async {
      const original =
          'https://example.test/feed.xml?access_token=ORIGINAL_SECRET';
      final feed = await repository.subscribe(original);
      await database.customStatement('''
      CREATE TRIGGER reject_feed_update
      BEFORE UPDATE ON feeds
      BEGIN
        SELECT RAISE(FAIL, 'forced update failure');
      END
    ''');

      await expectLater(
        repository.subscribe(
          'https://example.test/feed.xml?access_token=REPLACEMENT_SECRET',
        ),
        throwsA(anything),
      );

      final secret = await privateFeeds.read(feed.credentialRef!);
      expect(secret?.url.toString(), original);
    },
  );

  test('updates private access without replacing local state', () async {
    final feed = await repository.subscribe(
      'https://example.test/feed.xml?access_token=ORIGINAL',
    );
    final episode = (await database.select(database.episodes).get()).single;
    await (database.update(
      database.episodes,
    )..where((row) => row.id.equals(episode.id))).write(
      const EpisodesCompanion(played: Value(true), starred: Value(true)),
    );

    await repository.updatePrivateAccess(
      feed.id,
      'https://example.test/feed.xml?access_token=REPLACEMENT',
    );

    final updatedFeed = await database.feedById(feed.id);
    final updatedEpisode = await database.episodeById(episode.id);
    final secret = await privateFeeds.read(feed.credentialRef!);
    expect(await database.select(database.feeds).get(), hasLength(1));
    expect(updatedFeed?.id, feed.id);
    expect(updatedEpisode?.played, isTrue);
    expect(updatedEpisode?.starred, isTrue);
    expect(secret?.url.queryParameters['access_token'], 'REPLACEMENT');
  });

  test('failed private access update restores the previous secret', () async {
    const original = 'https://example.test/feed.xml?access_token=ORIGINAL';
    final feed = await repository.subscribe(original);
    await database.customStatement('''
      CREATE TRIGGER reject_private_access_update
      BEFORE UPDATE ON feeds
      BEGIN
        SELECT RAISE(FAIL, 'forced update failure');
      END
    ''');

    await expectLater(
      repository.updatePrivateAccess(
        feed.id,
        'https://example.test/feed.xml?access_token=REPLACEMENT',
      ),
      throwsA(anything),
    );

    expect(
      (await privateFeeds.read(feed.credentialRef!))?.url.toString(),
      original,
    );
  });

  test('private access update repairs a missing secret', () async {
    final feed = await repository.subscribe(
      'https://example.test/feed.xml?access_token=ORIGINAL',
    );
    await privateFeeds.delete(feed.credentialRef!);

    await repository.updatePrivateAccess(
      feed.id,
      'https://example.test/feed.xml?access_token=REPAIRED',
    );

    expect(
      (await privateFeeds.read(
        feed.credentialRef!,
      ))?.url.queryParameters['access_token'],
      'REPAIRED',
    );
  });

  test('private access update cannot recreate a deleted secret', () async {
    network.close();
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final adapter = _BlockingRefreshAdapter();
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
    final feed = await repository.subscribe(
      'https://example.test/feed.xml?access_token=ORIGINAL',
    );

    final update = repository.updatePrivateAccess(
      feed.id,
      'https://example.test/feed.xml?access_token=REPLACEMENT',
    );
    await adapter.refreshStarted.future;
    await repository.deleteFeed(feed.id);
    adapter.releaseRefresh.complete();

    await expectLater(update, throwsA(anything));
    expect(await database.feedById(feed.id), isNull);
    expect(await privateFeeds.read(feed.credentialRef!), isNull);
  });

  test('failed database deletion preserves private access', () async {
    final feed = await repository.subscribe(
      'https://example.test/feed.xml?access_token=KEEP',
    );
    final episode = (await database.select(database.episodes).get()).single;
    await database.customStatement('''
      CREATE TRIGGER reject_feed_delete
      BEFORE DELETE ON feeds
      BEGIN
        SELECT RAISE(FAIL, 'forced delete failure');
      END
    ''');

    await expectLater(repository.deleteFeed(feed.id), throwsA(anything));

    expect(await database.feedById(feed.id), isNotNull);
    expect(await privateFeeds.read(feed.credentialRef!), isNotNull);
    expect(await privateFeeds.readMediaUrl(episode.id), isNotNull);
  });

  test('concurrent delete callers both observe a failed transaction', () async {
    final feed = await repository.subscribe(
      'https://example.test/feed.xml?access_token=KEEP',
    );
    await database.customStatement('''
      CREATE TRIGGER reject_concurrent_feed_delete
      BEFORE DELETE ON feeds
      BEGIN
        SELECT RAISE(FAIL, 'forced delete failure');
      END
    ''');

    final first = repository.deleteFeed(feed.id);
    final firstFailure = expectLater(first, throwsA(anything));
    final second = repository.deleteFeed(feed.id);

    await expectLater(second, throwsA(isA<StateError>()));
    await firstFailure;
    expect(await database.feedById(feed.id), isNotNull);
    expect(await privateFeeds.read(feed.credentialRef!), isNotNull);
  });

  test(
    'failed racing deletion restores the previous feed credential',
    () async {
      network.close();
      await database.close();
      database = AppDatabase.forTesting(NativeDatabase.memory());
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _CredentialRaceAdapter(),
        addressValidator: (_) async {},
      );
      const storage = FlutterSecureStorage();
      privateFeeds = PrivateFeedStore(storage: storage);
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final feed = await repository.subscribe(
        'https://example.test/feed.xml?access_token=ORIGINAL',
      );
      await database.customStatement('''
        CREATE TRIGGER reject_racing_feed_delete
        BEFORE DELETE ON feeds
        BEGIN
          SELECT RAISE(FAIL, 'forced delete failure');
        END
      ''');
      Future<void>? deletion;
      void startFailingDeletion(String? value) {
        if (deletion != null || value?.contains('REPLACEMENT') != true) return;
        deletion = repository.deleteFeed(feed.id);
        unawaited(deletion!.catchError((Object _) {}));
      }

      final credentialKey = 'private-feed:${feed.credentialRef}';
      storage.registerListener(
        key: credentialKey,
        listener: startFailingDeletion,
      );
      try {
        await expectLater(
          repository.updatePrivateAccess(
            feed.id,
            'https://example.test/feed.xml?access_token=REPLACEMENT',
          ),
          throwsA(anything),
        );
        expect(deletion, isNotNull);
        await expectLater(deletion!, throwsA(anything));
      } finally {
        storage.unregisterListener(
          key: credentialKey,
          listener: startFailingDeletion,
        );
      }

      expect(await database.feedById(feed.id), isNotNull);
      expect(
        (await privateFeeds.read(
          feed.credentialRef!,
        ))?.url.queryParameters['access_token'],
        'ORIGINAL',
      );
    },
  );

  test('failed racing deletion restores previous private media URLs', () async {
    network.close();
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _RotatingFeedAdapter(),
      addressValidator: (_) async {},
    );
    const storage = FlutterSecureStorage();
    privateFeeds = PrivateFeedStore(storage: storage);
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
    final feed = await repository.subscribe(
      'https://example.test/feed.xml?access_token=PRIVATE',
    );
    final episode = (await database.select(database.episodes).get()).single;
    await database.customStatement('''
      CREATE TRIGGER reject_racing_refresh_delete
      BEFORE DELETE ON feeds
      BEGIN
        SELECT RAISE(FAIL, 'forced delete failure');
      END
    ''');
    Future<void>? deletion;
    void startFailingDeletion(String? value) {
      if (deletion != null || value?.contains('MEDIA_2') != true) return;
      deletion = repository.deleteFeed(feed.id);
      unawaited(deletion!.catchError((Object _) {}));
    }

    final mediaKey = 'private-media:${episode.id}';
    storage.registerListener(key: mediaKey, listener: startFailingDeletion);
    try {
      expect(await repository.refreshFeed(feed), isFalse);
      expect(deletion, isNotNull);
      await expectLater(deletion!, throwsA(anything));
    } finally {
      storage.unregisterListener(key: mediaKey, listener: startFailingDeletion);
    }

    expect(await database.feedById(feed.id), isNotNull);
    expect(
      (await privateFeeds.readMediaUrl(episode.id))?.queryParameters['token'],
      'MEDIA_1',
    );
  });

  test('an in-flight refresh cannot recreate a deleted feed', () async {
    network.close();
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final adapter = _BlockingRefreshAdapter();
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
    final feed = await repository.subscribe(
      'https://example.test/feed.xml?token=PRIVATE',
    );
    final episode = (await database.select(database.episodes).get()).single;

    final refresh = repository.refreshFeed(feed);
    await adapter.refreshStarted.future;
    await repository.deleteFeed(feed.id);
    adapter.releaseRefresh.complete();

    expect(await refresh, isFalse);
    expect(await database.feedById(feed.id), isNull);
    expect(await database.select(database.episodes).get(), isEmpty);
    expect(await privateFeeds.read(feed.credentialRef!), isNull);
    expect(await privateFeeds.readMediaUrl(episode.id), isNull);
  });

  test('YouTube channel and playlist URLs resolve to public Atom feeds', () async {
    network.close();
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final adapter = _YouTubeFeedAdapter();
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );

    final channel = await repository.subscribe(
      'https://www.youtube.com/@GoogleDevelopers',
    );
    final duplicate = await repository.subscribe(
      'https://www.youtube.com/feeds/videos.xml?channel_id=UC_x5XG1OV2P6uZZ5FSM9Ttw',
    );
    final playlist = await repository.subscribe(
      'https://www.youtube.com/playlist?list=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
    );

    expect(channel.id, duplicate.id);
    expect(channel.isPrivate, isFalse);
    expect(playlist.isPrivate, isFalse);
    expect(channel.feedUrl, contains('channel_id=UC_x5XG1OV2P6uZZ5FSM9Ttw'));
    expect(
      playlist.feedUrl,
      contains('playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs'),
    );
    expect(await database.select(database.feeds).get(), hasLength(2));
    expect(await database.select(database.episodes).get(), isEmpty);
    final articles = await database.select(database.articles).get();
    expect(articles, hasLength(2));
    expect(articles.every((article) => article.imageUrl != null), isTrue);
    expect(
      adapter.requests.map((uri) => uri.toString()),
      containsAll([
        'https://www.youtube.com/@GoogleDevelopers',
        'https://www.youtube.com/feeds/videos.xml?channel_id=UC_x5XG1OV2P6uZZ5FSM9Ttw',
        'https://www.youtube.com/feeds/videos.xml?playlist_id=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs',
      ]),
    );
  });
}

final class _FeedAdapter implements HttpClientAdapter {
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
          <title>Private Signal</title>
          <item>
            <guid>episode-1</guid>
            <title>Encrypted Dispatch</title>
            <enclosure
              url="https://cdn.example.test/audio.mp3?token=MEDIA_SECRET"
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

final class _YouTubeFeedAdapter implements HttpClientAdapter {
  final List<Uri> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    if (options.uri.path.startsWith('/@')) {
      return ResponseBody.fromString(
        '''
        <html><head>
          <meta itemprop="channelId" content="UC_x5XG1OV2P6uZZ5FSM9Ttw">
        </head></html>
        ''',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    final itemId = options.uri.queryParameters.containsKey('playlist_id')
        ? 'playlist'
        : 'channel';
    return ResponseBody.fromString(
      '''
      <feed xmlns="http://www.w3.org/2005/Atom"
        xmlns:media="http://search.yahoo.com/mrss/">
        <title>Signal Channel</title>
        <entry>
          <id>yt:video:$itemId</id>
          <title>New transmission</title>
          <link rel="alternate" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ" />
          <media:group>
            <media:description>Details and links</media:description>
            <media:thumbnail url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg" />
          </media:group>
        </entry>
      </feed>
      ''',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/atom+xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _SignedRedirectAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.uri.hasQuery) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [
            'https://example.test/feed.xml?access_token=REDIRECT_SECRET',
          ],
        },
      );
    }
    return _FeedAdapter().fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

final class _NotModifiedFeedAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length > 1) {
      return ResponseBody.fromString('', 304);
    }
    return ResponseBody.fromString(
      '''
      <rss version="2.0">
        <channel>
          <title>Mixed Signal</title>
          <item>
            <guid>episode-1</guid>
            <title>Audio Dispatch</title>
            <enclosure
              url="https://cdn.example.test/audio.mp3"
              type="audio/mpeg"
            />
          </item>
          <item>
            <guid>article-1</guid>
            <title>Written Dispatch</title>
            <link>https://example.test/articles/1</link>
            <description>Article summary.</description>
          </item>
        </channel>
      </rss>
      ''',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/rss+xml'],
        'etag': ['"mixed-v1"'],
        'last-modified': ['Wed, 01 Jan 2025 00:00:00 GMT'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _AlwaysNotModifiedFeedAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString('', 304);

  @override
  void close({bool force = false}) {}
}

final class _BlockingFailureFeedAdapter implements HttpClientAdapter {
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
    return ResponseBody.fromString('Not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

final class _FeedTitleAdapter implements HttpClientAdapter {
  _FeedTitleAdapter(this.title);

  final String title;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => _podcastFeedResponse(title);

  @override
  void close({bool force = false}) {}
}

final class _BlockingSuccessfulFeedAdapter implements HttpClientAdapter {
  _BlockingSuccessfulFeedAdapter(this.title);

  final String title;
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
    return _podcastFeedResponse(title);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _podcastFeedResponse(String title) => ResponseBody.fromString(
  '''
  <rss version="2.0">
    <channel>
      <title>$title</title>
      <item>
        <guid>episode-1</guid>
        <title>Dispatch</title>
        <enclosure url="https://cdn.example.test/audio.mp3"
          type="audio/mpeg" />
      </item>
    </channel>
  </rss>
  ''',
  200,
  headers: {
    Headers.contentTypeHeader: ['application/rss+xml'],
  },
);

final class _PodcastWithTextItemAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '''
      <rss version="2.0"
        xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>Imported show</title>
          <itunes:author>Publisher</itunes:author>
          <item>
            <guid>episode-1</guid>
            <title>Playable episode</title>
            <enclosure
              url="https://cdn.example.test/audio.mp3"
              type="audio/mpeg"
            />
          </item>
          <item>
            <guid>announcement-1</guid>
            <title>Announcement without audio</title>
            <description>Show announcement.</description>
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

final class _PodcastThenArticleAdapter implements HttpClientAdapter {
  var _requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _requests++;
    return ResponseBody.fromString(
      _requests == 1
          ? '''
            <rss version="2.0">
              <channel><title>Show</title><item>
                <guid>episode-1</guid><title>Episode</title>
                <enclosure url="https://example.test/audio.mp3"
                  type="audio/mpeg" />
              </item></channel>
            </rss>
            '''
          : '''
            <rss version="2.0">
              <channel><title>Temporarily malformed show</title><item>
                <guid>text-1</guid><title>Publisher notice</title>
                <description>Audio is temporarily unavailable.</description>
              </item></channel>
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

final class _RotatingFeedAdapter implements HttpClientAdapter {
  int _requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _requests++;
    return ResponseBody.fromString(
      '''
      <rss version="2.0">
        <channel>
          <title>Rotating Signal</title>
          <item>
            <title>Stable Dispatch</title>
            <enclosure
              url="https://cdn.example.test/audio.mp3?episode=42&amp;token=MEDIA_$_requests"
              type="audio/mpeg"
              length="${42000 + _requests}"
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

final class _CredentialRaceAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final token = options.uri.queryParameters['access_token'] ?? 'NONE';
    return ResponseBody.fromString(
      '''
      <rss version="2.0">
        <channel>
          <title>Credential Race</title>
          <item>
            <guid>episode-1</guid>
            <title>Dispatch</title>
            <enclosure
              url="https://cdn.example.test/audio.mp3?token=${token}_MEDIA"
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

final class _BlockingRefreshAdapter implements HttpClientAdapter {
  final Completer<void> refreshStarted = Completer<void>();
  final Completer<void> releaseRefresh = Completer<void>();
  var _requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _requests++;
    if (_requests == 2) {
      refreshStarted.complete();
      await releaseRefresh.future;
    }
    return ResponseBody.fromString(
      '''
      <rss version="2.0">
        <channel>
          <title>Concurrent Signal</title>
          <item>
            <guid>episode-1</guid>
            <title>Dispatch</title>
            <enclosure
              url="https://cdn.example.test/audio.mp3?token=MEDIA"
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
