import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/core/content_filters.dart';
import 'package:trickle/core/errors.dart';
import 'package:trickle/core/feed_identity.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/domain/feed_models.dart';

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
    'refresh reads only incoming articles and leaves unchanged history alone',
    () async {
      await database.close();
      final reads = _RefreshReadSizes();
      database = AppDatabase.forTesting(
        NativeDatabase.memory().interceptWith(reads),
      );
      network.close();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _ReaderFeedAdapter(),
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final feed = await repository.subscribe(
        'https://example.test/reader.xml',
      );
      final article = (await database.select(database.articles).get()).single;
      await (database.update(
        database.articles,
      )..where((row) => row.id.equals(article.id))).write(
        ArticlesCompanion(
          starred: const Value(true),
          readAt: Value(DateTime.utc(2026, 9, 8)),
          readerHtml: const Value('<p>Cached reader text</p>'),
          readerFetchedAt: Value(DateTime.utc(2026, 9, 8)),
        ),
      );
      await database.customStatement(
        '''
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000)
      INSERT INTO articles(id,feed_id,title,content_html,discovered_at)
      SELECT 'old-'||x,?,'Older article', '<p>Old content</p>',x FROM n
    ''',
        [feed.id],
      );
      await database.customStatement(
        'CREATE TEMP TABLE changed_articles(id TEXT)',
      );
      await database.indexSearchItem(
        entityId: article.id,
        kind: 'article',
        title: article.title,
        body: 'Cached reader text',
        feedTitle: feed.title,
      );
      await database.customStatement(
        'CREATE TEMP TRIGGER record_article_update AFTER UPDATE ON articles BEGIN INSERT INTO changed_articles VALUES (new.id); END',
      );
      reads.largestResult = 0;
      expect(await repository.refreshFeed(feed), isTrue);
      expect(reads.largestResult, lessThanOrEqualTo(1));
      final refreshed = await database.articleById(article.id);
      expect(refreshed?.starred, isTrue);
      expect(refreshed?.readAt, isNotNull);
      expect(refreshed?.contentHtml, article.contentHtml);
      expect(refreshed?.readerHtml, '<p>Cached reader text</p>');
      expect(await database.search('cached reader'), hasLength(1));
      expect(
        await database.customSelect('SELECT * FROM changed_articles').get(),
        isEmpty,
      );
      expect(
        (await database
                .customSelect('SELECT COUNT(*) AS count FROM articles')
                .getSingle())
            .read<int>('count'),
        10001,
      );
    },
  );

  test('podcast preview rejects a non-podcast feed', () async {
    network.close();
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _ReaderFeedAdapter(),
      addressValidator: (_) async {},
    );
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );

    await expectLater(
      repository.loadPodcastPreview('https://example.test/articles.xml'),
      throwsA(isA<FeedParseException>()),
    );
    expect(await database.select(database.feeds).get(), isEmpty);
  });

  test(
    'podcast-only subscription rejects a reader feed before storage',
    () async {
      network.close();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _ReaderFeedAdapter(),
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );

      await expectLater(
        repository.subscribe(
          'https://example.test/articles.xml',
          expectedKind: FeedKind.podcast,
        ),
        throwsA(isA<FeedParseException>()),
      );
      expect(await database.select(database.feeds).get(), isEmpty);
    },
  );

  test(
    'category timeline and mark read use the same Unicode category',
    () async {
      final now = DateTime.utc(2026, 7, 26);
      for (final (id, category) in const [
        ('retained', 'Économie locale'),
        ('active', 'Économie locale'),
        ('active-two', 'économie   locale'),
        ('other', 'Other'),
      ]) {
        await database
            .into(database.feeds)
            .insert(
              FeedsCompanion.insert(
                id: id,
                title: id,
                feedUrl: 'https://example.test/$id.xml',
                category: Value(category),
                kind: Value(FeedKind.reader.index),
                createdAt: now,
                updatedAt: now,
              ),
            );
        await database
            .into(database.articles)
            .insert(
              ArticlesCompanion.insert(
                id: '$id-article',
                feedId: id,
                title: id,
                discoveredAt: now,
                starred: Value(id == 'retained'),
              ),
            );
      }

      await repository.deleteFeed('retained');
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      Future<T> watchOnce<T>(StreamProvider<T> provider) async {
        final subscription = container.listen(provider, (_, _) {});
        try {
          return await container
              .read(provider.future)
              .timeout(const Duration(seconds: 3));
        } finally {
          subscription.close();
        }
      }

      await watchOnce(feedsProvider);
      const query = (
        feedId: null,
        category: 'Économie locale',
        filter: ArticleFeedFilter.unread,
        query: '',
      );
      expect(await watchOnce(filteredArticleCountProvider(query)), 2);
      final items = await watchOnce(
        filteredArticlesProvider((
          feedId: query.feedId,
          category: query.category,
          filter: query.filter,
          query: query.query,
          limit: 10,
          sort: ContentSort.newest,
        )),
      );
      expect(
        items.map((item) => item.id),
        unorderedEquals(['active-article', 'active-two-article']),
      );
      await repository.markAllArticlesRead(category: query.category);
      expect((await database.articleById('active-article'))?.readAt, isNotNull);
      expect(
        (await database.articleById('active-two-article'))?.readAt,
        isNotNull,
      );
      expect((await database.articleById('other-article'))?.readAt, isNull);
      await repository.markAllArticlesRead();

      expect((await database.feedById('retained'))?.subscribed, isFalse);
      expect((await database.articleById('retained-article'))?.readAt, isNull);
      expect((await database.articleById('other-article'))?.readAt, isNotNull);
    },
  );

  test(
    'unsubscribing preserves staged Up next additions and removes untouched episodes',
    () async {
      final feed = await repository.subscribe('https://example.test/feed.xml');
      final queued = (await database.select(database.episodes).get()).single;
      await (database.update(database.feeds)
            ..where((row) => row.id.equals(feed.id)))
          .write(const FeedsCompanion(autoQueue: Value(true)));
      await (database.update(database.episodes)
            ..where((row) => row.id.equals(queued.id)))
          .write(const EpisodesCompanion(automationApplied: Value(false)));
      await database.stageAutomaticQueueAdditions([queued.id]);
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: 'untouched',
              feedId: feed.id,
              title: 'Untouched episode',
              enclosureUrl: 'https://example.test/untouched.mp3',
              discoveredAt: queued.discoveredAt,
            ),
          );
      await database.indexSearchItem(
        entityId: 'untouched',
        kind: 'episode',
        title: 'Untouched episode',
        body: '',
        feedTitle: feed.title,
      );

      expect(await repository.deleteFeed(feed.id), ['untouched']);
      expect((await database.feedById(feed.id))?.subscribed, isFalse);
      expect(await database.search('untouched'), isEmpty);
      expect(await database.episodeById('untouched'), isNull);
      expect((await database.loadQueue()).single.$1.id, queued.id);
    },
  );

  test(
    'catalog preview caching preserves an existing reader subscription',
    () async {
      const url = 'https://example.test/feed.xml';
      final feed = await repository.subscribe(
        url,
        expectedKind: FeedKind.reader,
      );
      final preview = await repository.loadPodcastPreview(url);
      final podcast = PodcastSearchResult(
        name: 'Podcast',
        author: '',
        feedUrl: Uri.parse(url),
        artworkUrl: null,
        genre: null,
        episodeCount: null,
        explicit: false,
      );
      await expectLater(
        repository.cachePodcastPreviewEpisode(
          podcast: podcast,
          preview: preview,
          episode: preview.feed.episodes.single,
        ),
        throwsA(isA<FeedParseException>()),
      );
      expect((await database.feedById(feed.id))?.kind, FeedKind.reader.index);
      expect(await database.select(database.episodes).get(), isEmpty);
      expect(await database.select(database.articles).get(), hasLength(1));
      await repository.deleteFeed(feed.id);
      final cached = await repository.cachePodcastPreviewEpisode(
        podcast: podcast,
        preview: preview,
        episode: preview.feed.episodes.single,
      );
      expect((await database.feedById(cached.feedId))?.subscribed, isFalse);
      expect(await database.select(database.articles).get(), isEmpty);
    },
  );

  test(
    'catalog preview and subscription share the discovered podcast address',
    () async {
      const url = 'https://example.test/podcast';
      const discovered = 'https://example.test/feed.xml';
      network.close();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _FeedAdapter(feedPage: Uri.parse(url).path),
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final preview = await repository.loadPodcastPreview(url);
      final podcast = PodcastSearchResult(
        name: preview.feed.title,
        author: '',
        feedUrl: Uri.parse(url),
        artworkUrl: null,
        genre: null,
        episodeCount: null,
        explicit: false,
      );
      Future<Episode> cache() => repository.cachePodcastPreviewEpisode(
        podcast: podcast,
        preview: preview,
        episode: preview.feed.episodes.single,
      );

      final cached = await cache();
      final subscribed = await repository.subscribe(
        url,
        expectedKind: FeedKind.podcast,
      );
      expect(subscribed.feedUrl, discovered);
      expect(subscribed.id, cached.feedId);
      await (database.update(
        database.episodes,
      )..where((row) => row.id.equals(cached.id))).write(
        const EpisodesCompanion(
          title: Value('Updated title'),
          starred: Value(true),
        ),
      );

      final reopened = await cache();
      expect(reopened.title, 'Updated title');
      expect(reopened.starred, isTrue);
      expect(await database.feedById(cached.feedId), subscribed);
      expect(await database.feedByUrl(url), isNull);
      final direct = await repository.subscribe(discovered);
      expect(direct.id, subscribed.id);
      expect(await database.select(database.feeds).get(), [direct]);
    },
  );

  test(
    'catalog preview playback reuses the matching private podcast',
    () async {
      const url = 'https://example.test/feed.xml?token=private';
      final other = await repository.subscribe(
        url,
        bearerToken: 'separate-account',
      );
      final preview = await repository.loadPodcastPreview(url);
      Future<Episode> cache() => repository.cachePodcastPreviewEpisode(
        podcast: PodcastSearchResult(
          name: preview.feed.title,
          author: '',
          feedUrl: Uri.parse(url),
          artworkUrl: null,
          genre: null,
          episodeCount: null,
          explicit: false,
        ),
        preview: preview,
        episode: preview.feed.episodes.single,
      );
      final cached = await cache();
      final retained = (await database.feedById(cached.feedId))!;
      expect(retained.subscribed, isFalse);
      expect(retained.isPrivate, isTrue);
      expect(cached.enclosureUrl, 'private-media://${cached.id}');
      expect(
        await privateFeeds.readMediaUrl(cached.id),
        preview.feed.episodes.single.enclosureUrl,
      );
      final feed = await repository.subscribe(url);
      expect(cached.feedId, feed.id);
      expect(cached.feedId, isNot(other.id));
      expect((await cache()).id, cached.id);
      expect(await database.feedByUrl(url), isNull);
      expect(await database.select(database.episodes).get(), hasLength(2));
    },
  );

  test(
    'reader categories normalize, move, rename, survive refresh, and stay reader-only',
    () async {
      network.close();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _ReaderFeedAdapter(),
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final reader = await repository.subscribe(
        'https://example.test/articles.xml',
        category: '  Science   & Tech  ',
      );
      final categorized = (await database.feedById(reader.id))!;
      expect(categorized.category, 'Science & Tech');

      await repository.updateFeedSettings(
        reader.id,
        autoDownload: false,
        autoDownloadLimit: 3,
        notifications: false,
        introSkipMs: 0,
        outroSkipMs: 0,
        autoQueue: false,
        category: 'Science & Tech',
      );
      expect(
        (await database.feedById(reader.id))?.updatedAt,
        categorized.updatedAt,
      );

      await database
          .into(database.feeds)
          .insert(
            reader.copyWith(
              id: 'second-reader',
              feedUrl: 'https://example.test/second.xml',
              category: const Value('science & tech'),
            ),
          );
      expect(
        await repository.renameFeedCategory('SCIENCE & TECH', 'Research'),
        2,
      );
      expect((await database.feedById(reader.id))?.category, 'Research');
      expect((await database.feedById('second-reader'))?.category, 'Research');

      expect(await repository.refreshFeed(reader), isTrue);
      expect((await database.feedById(reader.id))?.category, 'Research');
      await repository.updateFeedCategories([reader.id], '   ');
      expect((await database.feedById(reader.id))?.category, isNull);

      network.close();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _FeedAdapter(),
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final podcast = await repository.subscribe(
        'https://example.test/podcast.xml',
      );
      expect(
        await repository.updateFeedCategories([reader.id, podcast.id], 'News'),
        1,
      );
      expect((await database.feedById(reader.id))?.category, 'News');
      expect((await database.feedById(podcast.id))?.category, isNull);
    },
  );

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

  test(
    'private URLs retain tokens and do not merge distinct subscriptions',
    () async {
      const secretUrl =
          'https://example.test/feed.xml?access_token=QUERY_SECRET';

      final feed = await repository.subscribe(secretUrl);
      final secret = await privateFeeds.read(feed.credentialRef!);

      expect(feed.isPrivate, isTrue);
      expect(feed.feedUrl, startsWith('private://'));
      expect(feed.feedUrl, isNot(contains('QUERY_SECRET')));
      expect(secret?.url.toString(), secretUrl);

      final other = await repository.subscribe(
        'https://example.test/feed.xml?access_token=REPLACEMENT_SECRET',
      );
      final updatedSecret = await privateFeeds.read(other.credentialRef!);
      expect(other.id, isNot(feed.id));
      expect(await database.select(database.feeds).get(), hasLength(2));
      final episodes = await database.select(database.episodes).get();
      expect(episodes.map((episode) => episode.feedId).toSet(), {
        feed.id,
        other.id,
      });
      expect(episodes.map((episode) => episode.id).toSet(), hasLength(2));
      expect(
        (await privateFeeds.read(feed.credentialRef!))?.url.toString(),
        secretUrl,
      );
      expect(
        updatedSecret?.url.queryParameters['access_token'],
        'REPLACEMENT_SECRET',
      );

      await repository.deleteFeed(other.id);
      expect((await repository.subscribe(secretUrl)).id, feed.id);
      await repository.deleteFeed(feed.id);
      final resubscribed = await repository.subscribe(secretUrl);
      expect(resubscribed.id, isNot(feed.id));
      expect(await database.select(database.feeds).get(), hasLength(1));
    },
  );

  test(
    'subscription identity survives portable backup storage and private toggles',
    () async {
      const url = 'https://example.test/feed.xml?token=portable';
      final now = DateTime.now().toUtc();
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'restored',
              title: 'Restored podcast',
              feedUrl: url,
              kind: Value(FeedKind.podcast.index),
              createdAt: now,
              updatedAt: now,
            ),
          );
      final restored = await repository.subscribe(url);
      expect(restored.id, 'restored');
      expect(restored.isPrivate, isTrue);
      final opaque = await repository.subscribe(
        'https://example.test/opaque.xml',
        forcePrivate: true,
      );
      expect(
        (await repository.subscribe('https://example.test/opaque.xml')).id,
        opaque.id,
      );
      final authenticated = await repository.subscribe(
        url,
        bearerToken: 'separate-account',
      );
      expect(authenticated.id, isNot(restored.id));
      expect(await database.select(database.feeds).get(), hasLength(3));
      await expectLater(
        repository.updatePrivateAccess(opaque.id, url),
        throwsA(isA<FeedParseException>()),
      );
      expect(
        (await privateFeeds.read(opaque.credentialRef!))?.url.path,
        '/opaque.xml',
      );
    },
  );

  test(
    'making a restored podcast private preserves its episode history',
    () async {
      network.close();
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = _RotatingFeedAdapter(),
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      const feedId = 'restored-podcast';
      const address = 'https://example.test/podcast.xml?token=private';
      final now = DateTime.utc(2026, 10, 2);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: feedId,
              title: 'Rotating Signal',
              feedUrl: address,
              kind: Value(FeedKind.podcast.index),
              createdAt: now,
              updatedAt: now,
            ),
          );
      const currentUrl =
          'https://cdn.example.test/audio.mp3?episode=42&token=OLD';
      const olderUrl = 'https://cdn.example.test/older.mp3?token=OLD';
      final currentId = stableContentId(
        feedId,
        episodeIdentity(
          guid: null,
          enclosureUrl: Uri.parse(currentUrl),
          publishedAt: null,
          title: 'Stable Dispatch',
        ),
      );
      for (final (id, title, url) in [
        (currentId, 'Stable Dispatch', currentUrl),
        ('older', 'Older', olderUrl),
      ]) {
        await database
            .into(database.episodes)
            .insert(
              EpisodesCompanion.insert(
                id: id,
                feedId: feedId,
                title: title,
                enclosureUrl: url,
                discoveredAt: now,
                starred: const Value(true),
              ),
            );
        await database
            .into(database.playbackProgresses)
            .insert(
              PlaybackProgressesCompanion.insert(
                episodeId: id,
                positionMs: const Value(18000),
                updatedAt: now,
              ),
            );
      }
      final feed = await repository.subscribe(address);
      expect(feed.id, feedId);
      expect(feed.isPrivate, isTrue);
      expect(await repository.refreshFeed(feed), isTrue);
      final episodes = await database.select(database.episodes).get();
      expect(
        episodes.map((episode) => episode.id),
        unorderedEquals([currentId, 'older']),
      );
      expect(
        episodes.every(
          (episode) =>
              episode.starred &&
              episode.enclosureUrl == 'private-media://${episode.id}',
        ),
        isTrue,
      );
      expect(await privateFeeds.readMediaUrl('older'), Uri.parse(olderUrl));
      expect(
        (await privateFeeds.readMediaUrl(currentId))?.queryParameters['token'],
        'MEDIA_2',
      );
      expect(
        (await database.watchPlaybackProgressForEpisode(currentId).first)
            ?.positionMs,
        18000,
      );
    },
  );

  test(
    'making a restored reader feed private preserves a saved article without merging another link',
    () async {
      network.close();
      network = SafeNetworkClient.forTesting(
        Dio()
          ..httpClientAdapter = _ReaderFeedAdapter(
            includeGuid: false,
            links: [
              'https://example.test/other-notes',
              'https://example.test/field-notes?token=new',
            ],
          ),
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      const feedId = 'restored-reader';
      const address = 'https://example.test/reader.xml?token=private';
      final now = DateTime.utc(2026, 10, 2);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: feedId,
              title: 'Written Signal',
              feedUrl: address,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.articles)
          .insert(
            ArticlesCompanion.insert(
              id: 'saved',
              feedId: feedId,
              title: 'Field notes',
              canonicalUrl: const Value(
                'https://example.test/field-notes?token=old',
              ),
              discoveredAt: now,
              readAt: Value(now),
              starred: const Value(true),
              readerHtml: const Value('<p>Saved offline text</p>'),
            ),
          );
      final feed = await repository.subscribe(address);
      expect(await repository.refreshFeed(feed), isTrue);
      final items = await database.select(database.articles).get();
      expect(items, hasLength(2));
      final item = items.singleWhere((item) => item.id == 'saved');
      expect(item.id, 'saved');
      expect(item.canonicalUrl, 'https://example.test/field-notes?token=new');
      expect(item.starred, isTrue);
      expect(item.readAt?.toUtc(), now);
      expect(item.readerHtml, '<p>Saved offline text</p>');
      final other = items.singleWhere((item) => item.id != 'saved');
      expect(other.canonicalUrl, 'https://example.test/other-notes');
      expect(other.starred, isFalse);
      expect(other.readAt, isNull);
    },
  );

  test(
    'private refresh matches a legacy saved article only by its stored link',
    () async {
      network.close();
      final adapter = _ReaderFeedAdapter(includeGuid: false);
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = adapter,
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final feed = await repository.subscribe(
        'https://example.test/reader.xml?token=private',
      );
      await database.delete(database.articles).go();
      final id = stableContentId(
        feed.id,
        articleIdentity(
          guid: null,
          canonicalUrl: null,
          publishedAt: null,
          title: 'Field notes',
        ),
      );
      await database
          .into(database.articles)
          .insert(
            ArticlesCompanion.insert(
              id: id,
              feedId: feed.id,
              title: 'Field notes',
              discoveredAt: DateTime.utc(2026, 10, 2),
              canonicalUrl: const Value(
                'https://example.test/field-notes?token=old',
              ),
              starred: const Value(true),
            ),
          );
      adapter.links = ['https://example.test/other-notes'];
      expect(await repository.refreshFeed(feed), isTrue);
      adapter.links = [
        'https://example.test/field-notes?token=new',
        'https://example.test/other-notes',
      ];
      expect(await repository.refreshFeed(feed), isTrue);
      final items = await database.select(database.articles).get();
      expect(items, hasLength(2));
      expect(items.singleWhere((item) => item.starred).id, id);
      expect(
        items.singleWhere((item) => item.starred).canonicalUrl,
        'https://example.test/field-notes?token=new',
      );
    },
  );

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

  test(
    'a slow feed does not block free refresh slots or healthy feeds',
    () async {
      for (final name in ['a-slow', 'b-failed', 'c-healthy']) {
        await repository.subscribe('https://example.test/$name.xml');
      }
      final slowStarted = Completer<void>();
      final releaseSlow = Completer<void>();
      final healthyStarted = Completer<void>();
      network.close();
      final dio = Dio()
        ..httpClientAdapter = _FeedTitleAdapter('Updated podcast');
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.path.endsWith('/a-slow.xml')) {
              slowStarted.complete();
              await releaseSlow.future;
            } else if (options.path.endsWith('/b-failed.xml')) {
              handler.resolve(
                Response(requestOptions: options, statusCode: 500),
              );
              return;
            } else {
              healthyStarted.complete();
            }
            handler.next(options);
          },
        ),
      );
      network = SafeNetworkClient.forTesting(
        dio,
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final failedFeed = (await database.feedByUrl(
        'https://example.test/b-failed.xml',
      ))!;
      final oldest = DateTime.utc(2026, 7, 18);
      await (database.update(database.feeds)
            ..where((row) => row.feedUrl.like('%/a-slow.xml')))
          .write(FeedsCompanion(lastRefresh: Value(oldest)));
      await (database.update(
        database.feeds,
      )..where((row) => row.id.equals(failedFeed.id))).write(
        FeedsCompanion(
          lastRefresh: Value(oldest.add(const Duration(seconds: 1))),
        ),
      );
      await database.customStatement('''
      CREATE TRIGGER reject_refresh_failure BEFORE UPDATE OF refresh_error ON feeds
      WHEN NEW.refresh_error IS NOT NULL
      BEGIN SELECT RAISE(FAIL, 'forced failure saving the refresh error'); END
    ''');
      final before = (await database.feedById(failedFeed.id))!.updatedAt;
      final refresh = repository.refreshAll(maxConcurrent: 2);
      try {
        await slowStarted.future.timeout(const Duration(seconds: 3));
        await healthyStarted.future.timeout(const Duration(seconds: 3));
      } finally {
        releaseSlow.complete();
      }
      expect((await refresh).failedFeeds, 1);
      expect((await database.feedById(failedFeed.id))!.updatedAt, before);
      expect(
        (await database.feedByUrl('https://example.test/c-healthy.xml'))?.title,
        'Updated podcast',
      );
    },
  );

  test(
    'unreadable private credentials do not abort refresh for other feeds',
    () async {
      final privateFeed = await repository.subscribe(
        'https://example.test/private.xml?token=private',
      );
      final publicFeed = await repository.subscribe(
        'https://example.test/public.xml',
      );
      await const FlutterSecureStorage().write(
        key: 'private-feed:${privateFeed.credentialRef}',
        value: 'invalid secure-store record',
      );
      final before = (await database.feedById(publicFeed.id))!.updatedAt;

      final result = await repository.refreshAll(maxConcurrent: 1);

      expect(result.failedFeeds, 1);
      expect(
        (await database.feedById(privateFeed.id))?.refreshError,
        isNotNull,
      );
      expect(
        (await database.feedById(publicFeed.id))!.updatedAt.isAfter(before),
        isTrue,
      );
    },
  );

  test('a permanent move keeps the podcast and its episode history', () async {
    const oldUrl = 'https://example.test/old.xml';
    const newUrl = 'https://example.test/new.xml';
    final adapter = _MovedFeedAdapter();
    network.close();
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
    final original = await repository.subscribe(oldUrl);
    final episode = await database.select(database.episodes).getSingle();
    await repository.starEpisode(episode.id, starred: true);

    adapter.redirect = true;
    expect(await repository.refreshFeed(original), isTrue);
    expect((await database.feedById(original.id))?.feedUrl, newUrl);
    expect((await repository.subscribe(newUrl)).id, original.id);
    expect((await repository.subscribe(oldUrl)).id, original.id);
    expect((await database.episodeById(episode.id))?.starred, isTrue);
    expect(await database.select(database.feeds).get(), hasLength(1));

    adapter.redirect = false;
    final replacement = await repository.subscribe(oldUrl);
    expect(replacement.id, isNot(original.id));
    adapter.redirect = true;
    expect(await repository.refreshFeed(replacement), isTrue);
    expect((await database.feedById(replacement.id))?.feedUrl, oldUrl);
    expect((await database.feedById(original.id))?.feedUrl, newUrl);
    expect((await database.episodeById(episode.id))?.starred, isTrue);
  });

  test('a signed redirect is not persisted as the refresh address', () async {
    network.close();
    await database.close();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final adapter = _SignedRedirectAdapter();
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
      'https://example.test/discover.xml',
    );
    expect(feed.isPrivate, isFalse);
    expect(feed.credentialRef, isNull);
    expect(feed.feedUrl, 'https://example.test/discover.xml');
    expect(feed.etag, isNull);
    expect(feed.feedUrl, isNot(contains('REDIRECT_SECRET')));
    expect(
      jsonEncode((await database.select(database.feeds).get()).single.toJson()),
      isNot(contains('REDIRECT_SECRET')),
    );

    // An older app may have persisted a validator from the signed target.
    await database
        .update(database.feeds)
        .write(const FeedsCompanion(etag: Value('"old-target"')));
    adapter.redirectStatus = 302;
    expect(await repository.refreshFeed(feed), isTrue);
    final refreshed = await database.feedById(feed.id);
    expect(refreshed?.title, 'Refreshed feed');
    expect(refreshed?.etag, isNull);
    expect(refreshed?.feedUrl, feed.feedUrl);
  });

  test(
    'podcast subscriptions are stored only in the podcast library',
    () async {
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

      final feed = await repository.subscribe(
        'https://example.test/show.xml',
        expectedKind: FeedKind.podcast,
      );

      expect(feed.kind, FeedKind.podcast.index);
      expect(await database.select(database.episodes).get(), hasLength(1));
      expect(await database.select(database.articles).get(), isEmpty);
      final feeds = await database.watchFeeds().first;
      expect(
        feeds.where((feed) => feed.kind == FeedKind.podcast.index),
        hasLength(1),
      );
      expect(
        feeds.where((feed) => feed.kind == FeedKind.reader.index),
        isEmpty,
      );
    },
  );

  test(
    'empty subscriptions keep their type as the entry mix changes',
    () async {
      for (final kind in FeedKind.values) {
        network.close();
        await database.close();
        database = AppDatabase.forTesting(NativeDatabase.memory());
        network = SafeNetworkClient.forTesting(
          Dio()..httpClientAdapter = _ChangingFeedAdapter(),
          addressValidator: (_) async {},
        );
        repository = FeedRepository(
          database: database,
          network: network,
          privateFeeds: privateFeeds,
        );
        final subscribed = await repository.subscribe(
          'https://example.test/show.xml',
          expectedKind: kind,
        );
        expect(subscribed.kind, kind.index);
        expect(await database.select(database.episodes).get(), isEmpty);
        expect(await database.select(database.articles).get(), isEmpty);
        for (final counts in [(1, 1), (1, 2), (2, 5)]) {
          expect(await repository.refreshFeed(subscribed), isTrue);
          expect((await database.feedById(subscribed.id))?.kind, kind.index);
          expect(
            await database.select(database.episodes).get(),
            hasLength(kind == FeedKind.podcast ? counts.$1 : 0),
          );
          expect(
            await database.select(database.articles).get(),
            hasLength(kind == FeedKind.reader ? counts.$2 : 0),
          );
        }
      }
    },
  );

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

  test(
    'a retained private podcast resubscribes without waiting for an old refresh',
    () async {
      final old = _BlockingSuccessfulFeedAdapter('Obsolete response');
      final dio = Dio()..httpClientAdapter = _FeedTitleAdapter('New response');
      final requests = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            dio.httpClientAdapter = requests.length == 2
                ? old
                : _FeedTitleAdapter('New response');
            handler.next(options);
          },
        ),
      );
      final refreshNetwork = SafeNetworkClient.forTesting(
        dio,
        addressValidator: (_) async {},
      );
      addTearDown(refreshNetwork.close);
      final freshRepository = FeedRepository(
        database: database,
        network: refreshNetwork,
        privateFeeds: privateFeeds,
      );
      final feed = await freshRepository.subscribe(
        'https://example.test/feed.xml?token=private',
      );
      final kept = await database.select(database.episodes).getSingle();
      await freshRepository.starEpisode(kept.id, starred: true);
      await database
          .update(database.feeds)
          .write(const FeedsCompanion(etag: Value('old-etag')));
      final oldRefresh = freshRepository.refreshFeed(feed);
      try {
        await old.started.future.timeout(const Duration(seconds: 3));
        await freshRepository.deleteFeed(feed.id);
        final retained = (await database.feedById(feed.id))!;
        final renewed = await freshRepository
            .resubscribe(retained)
            .timeout(const Duration(seconds: 3));
        expect(renewed.subscribed, isTrue);
        expect(renewed.id, feed.id);
        expect(requests[1].headers['If-None-Match'], 'old-etag');
        expect(requests[2].headers, isNot(contains('If-None-Match')));
      } finally {
        old.release.complete();
        await oldRefresh;
      }
      expect((await database.feedById(feed.id))?.title, 'New response');
      expect((await database.episodeById(kept.id))?.starred, isTrue);
    },
  );

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

  test('an in-flight refresh cannot resubscribe a retained podcast', () async {
    final subscribed = await repository.subscribe(
      'https://example.test/feed.xml',
    );
    await database
        .update(database.episodes)
        .write(const EpisodesCompanion(starred: Value(true)));
    final adapter = _BlockingSuccessfulFeedAdapter('Late response');
    final refreshNetwork = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    addTearDown(refreshNetwork.close);
    final backgroundRepository = FeedRepository(
      database: database,
      network: refreshNetwork,
      privateFeeds: privateFeeds,
    );
    final refresh = backgroundRepository.refreshFeed(subscribed);
    await adapter.started.future;

    await repository.deleteFeed(subscribed.id);
    // The write guard must also hold if both operations share the same stored
    // timestamp, for example after restoring a backup of the retained feed.
    await (database.update(database.feeds)
          ..where((row) => row.id.equals(subscribed.id)))
        .write(FeedsCompanion(updatedAt: Value(subscribed.updatedAt)));
    adapter.release.complete();

    expect(await refresh, isFalse);
    final retained = await database.feedById(subscribed.id);
    expect(retained?.subscribed, isFalse);
    expect(retained?.title, subscribed.title);
    expect(
      (await database.select(database.episodes).getSingle()).starred,
      isTrue,
    );
  });

  test(
    'a deleted public feed cannot share the ID of an in-flight refresh',
    () async {
      const url = 'https://example.test/feed.xml';
      final feed = await repository.subscribe(url);
      final adapter = _BlockingSuccessfulFeedAdapter('Deleted subscription');
      final refreshNetwork = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = adapter,
        addressValidator: (_) async {},
      );
      addTearDown(refreshNetwork.close);
      final backgroundRepository = FeedRepository(
        database: database,
        network: refreshNetwork,
        privateFeeds: privateFeeds,
      );
      final refresh = backgroundRepository.refreshFeed(feed);
      try {
        await adapter.started.future.timeout(const Duration(seconds: 3));
        await repository.deleteFeed(feed.id);
        final renewed = await repository.subscribe(url);
        // SQLite stores the revision to the second. Make a same-second
        // recreation deterministic instead of relying on the wall clock.
        await (database.update(database.feeds)
              ..where((row) => row.id.equals(renewed.id)))
            .write(FeedsCompanion(updatedAt: Value(feed.updatedAt)));
        adapter.release.complete();
        await refresh;
        expect((await database.feedByUrl(url))?.title, renewed.title);
      } finally {
        if (!adapter.release.isCompleted) adapter.release.complete();
        await refresh;
      }
    },
  );

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
        category: null,
      );
      await (database.update(
        database.feeds,
      )..where((row) => row.id.equals(subscribed.id))).write(
        const FeedsCompanion(
          imageUrl: Value('https://example.test/current-artwork.png'),
        ),
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
      expect(refreshed?.imageUrl, 'https://example.test/current-artwork.png');
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
    'private refresh preserves the original episode and separates media selectors',
    () async {
      network.close();
      final adapter = _RotatingFeedAdapter(episodeNumbers: [41, 42]);
      network = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = adapter,
        addressValidator: (_) async {},
      );
      repository = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final now = DateTime.utc(2026, 10, 2);
      const feedId = 'private-podcast';
      const feedUrl = 'https://example.test/feed.xml?token=private';
      final ref = await privateFeeds.save(
        PrivateFeedSecret(url: Uri.parse(feedUrl), headers: const {}),
      );
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: feedId,
              title: 'Rotating Signal',
              feedUrl: 'private://$ref',
              isPrivate: const Value(true),
              credentialRef: Value(ref),
              kind: Value(FeedKind.podcast.index),
              createdAt: now,
              updatedAt: now,
            ),
          );
      final url = Uri.parse(
        'https://cdn.example.test/audio.mp3?episode=42&token=OLD',
      );
      final oldId = stableContentId(
        feedId,
        legacyPrivateEpisodeIdentity(
          enclosureUrl: url,
          publishedAt: null,
          title: 'Stable Dispatch',
        ),
      );
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: oldId,
              feedId: feedId,
              title: 'Stable Dispatch',
              enclosureUrl: 'private-media://$oldId',
              discoveredAt: now,
              starred: const Value(true),
            ),
          );
      await privateFeeds.saveMediaUrl(oldId, url);
      await database
          .into(database.playbackProgresses)
          .insert(
            PlaybackProgressesCompanion.insert(
              episodeId: oldId,
              positionMs: const Value(18000),
              updatedAt: now,
            ),
          );
      final feed = (await database.feedById(feedId))!;
      expect(await repository.refreshFeed(feed), isTrue);
      adapter.episodeNumbers = [42, 41];
      expect(await repository.refreshFeed(feed), isTrue);
      final episodes = await database.select(database.episodes).get();
      expect(episodes, hasLength(2));
      for (final episode in episodes) {
        final media = (await privateFeeds.readMediaUrl(episode.id))!;
        expect(
          media.queryParameters['episode'],
          episode.id == oldId ? '42' : '41',
        );
        expect(media.queryParameters['token'], 'MEDIA_2');
        expect(episode.starred, episode.id == oldId);
      }
      expect(
        (await database.watchPlaybackProgressForEpisode(oldId).first)
            ?.positionMs,
        18000,
      );
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
    final secret = await privateFeeds.read(updatedFeed!.credentialRef!);
    expect(await database.select(database.feeds).get(), hasLength(1));
    expect(updatedFeed.id, feed.id);
    expect(updatedEpisode?.played, isTrue);
    expect(updatedEpisode?.starred, isTrue);
    expect(secret?.url.queryParameters['access_token'], 'REPLACEMENT');
    expect(await privateFeeds.read(feed.credentialRef!), isNull);
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

    final repaired = (await database.feedById(feed.id))!;
    expect(
      (await privateFeeds.read(
        repaired.credentialRef!,
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

    await expectLater(second, throwsA(anything));
    await firstFailure;
    expect(await database.feedById(feed.id), isNotNull);
    expect(await privateFeeds.read(feed.credentialRef!), isNotNull);
  });

  test(
    'concurrent private additions with the same credentials share one subscription',
    () async {
      const url = 'https://example.test/feed.xml?access_token=PRIVATE';
      final added = await Future.wait([
        repository.subscribe(url),
        repository.subscribe(url),
      ]);
      expect(added.map((feed) => feed.id).toSet(), hasLength(1));
      expect(await database.select(database.feeds).get(), hasLength(1));
      expect(await database.select(database.episodes).get(), hasLength(1));
    },
  );

  test('a stale credential update cannot restore an older media URL', () async {
    final adapter = _CredentialRaceAdapter();
    network.close();
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    repository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
    final feed = await repository.subscribe(
      'https://example.test/feed.xml?access_token=ORIGINAL',
    );
    final episode = (await database.select(database.episodes).getSingle());
    final stale = repository.updatePrivateAccess(
      feed.id,
      'https://example.test/feed.xml?access_token=STALE',
    );
    final staleResult = expectLater(stale, throwsA(anything));
    await adapter.started.future;
    await repository.updatePrivateAccess(
      feed.id,
      'https://example.test/feed.xml?access_token=LATEST',
    );
    adapter.release.complete();
    await staleResult;
    final latest = (await database.feedById(feed.id))!;
    expect(
      (await privateFeeds.read(
        latest.credentialRef!,
      ))?.url.queryParameters['access_token'],
      'LATEST',
    );
    expect(
      (await privateFeeds.readMediaUrl(episode.id))?.queryParameters['token'],
      'LATEST_MEDIA',
    );
    expect(
      (await repository.subscribe(
        'https://example.test/feed.xml?access_token=LATEST',
      )).id,
      feed.id,
    );
  });

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
    Future<List<String>>? deletion;
    void startFailingDeletion(String? value) {
      if (deletion != null || value?.contains('MEDIA_2') != true) return;
      deletion = repository.deleteFeed(feed.id);
      unawaited(deletion!.then<void>((_) {}, onError: (Object _) {}));
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
  _FeedAdapter({this.feedPage});

  final String? feedPage;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == feedPage) {
      return ResponseBody.fromString(
        '<html><head>'
        '<link rel="alternate" type="application/rss+xml" href="/retired.xml">'
        '<link rel="alternate" type="application/rss+xml" href="/articles.xml">'
        '<link rel="alternate" type="application/rss+xml" href="/feed.xml">'
        '</head></html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    if (options.uri.path == '/retired.xml') {
      return ResponseBody.fromString('', 404);
    }
    if (options.uri.path == '/articles.xml') {
      return ResponseBody.fromString(
        '<rss version="2.0"><channel><title>Articles</title>'
        '<item><title>Text only</title></item></channel></rss>',
        200,
      );
    }
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

final class _RefreshReadSizes extends QueryInterceptor {
  int largestResult = 0;
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(statement, args);
    if (rows.length > largestResult) largestResult = rows.length;
    return rows;
  }
}

final class _ReaderFeedAdapter implements HttpClientAdapter {
  _ReaderFeedAdapter({
    this.includeGuid = true,
    this.links = const ['https://example.test/field-notes'],
  });

  final bool includeGuid;
  List<String> links;

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
          <title>Written Signal</title>
          ${links.map((link) => '''<item>
            ${includeGuid ? '<guid>article-1</guid>' : ''}
            <title>Field notes</title>
            <link>$link</link>
          </item>''').join()}
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

final class _MovedFeedAdapter implements HttpClientAdapter {
  bool redirect = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (redirect && options.uri.path == '/old.xml') {
      return Future.value(
        ResponseBody.fromString(
          '',
          301,
          headers: {
            'location': ['/new.xml'],
          },
        ),
      );
    }
    return _FeedAdapter().fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

final class _SignedRedirectAdapter implements HttpClientAdapter {
  int redirectStatus = 308;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.uri.hasQuery) {
      return ResponseBody.fromString(
        '',
        redirectStatus,
        headers: {
          'location': [
            'https://example.test/feed.xml?access_token=REDIRECT_SECRET',
          ],
        },
      );
    }
    if (options.headers.containsKey('If-None-Match')) {
      return ResponseBody.fromString('', 304);
    }
    if (redirectStatus == 302) {
      return ResponseBody.fromString(
        '<rss version="2.0"><channel><title>Refreshed feed</title></channel></rss>',
        200,
        headers: {
          'etag': ['"new-target"'],
        },
      );
    }
    final body = await _FeedAdapter().fetch(
      options,
      requestStream,
      cancelFuture,
    );
    body.headers['etag'] = ['"signed-target"'];
    return body;
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
      <rss version="2.0">
        <channel>
          <title>Imported show</title>
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

final class _ChangingFeedAdapter implements HttpClientAdapter {
  var _requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _requests++;
    return ResponseBody.fromString(
      switch (_requests) {
        1 =>
          '''
          <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
            <channel><title>Show</title><itunes:author>Publisher</itunes:author></channel>
          </rss>
        ''',
        2 =>
          '''
            <rss version="2.0">
              <channel><title>Show</title><item>
                <guid>episode-1</guid><title>Episode</title>
                <enclosure url="https://example.test/audio.mp3"
                  type="audio/mpeg" />
              </item></channel>
            </rss>
            ''',
        3 =>
          '''
            <rss version="2.0">
              <channel><title>Temporarily malformed show</title><item>
                <guid>text-1</guid><title>Publisher notice</title>
                <description>Audio is temporarily unavailable.</description>
              </item></channel>
            </rss>
            ''',
        _ =>
          '''
          <rss><channel><title>Show</title>
            <item><guid>episode-2</guid><title>Second episode</title>
              <enclosure url="https://example.test/second.mp3" type="audio/mpeg" /></item>
            <item><guid>text-2</guid><title>Announcement</title></item>
            <item><guid>text-3</guid><title>Another announcement</title></item>
          </channel></rss>
        ''',
      },
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
  _RotatingFeedAdapter({this.episodeNumbers = const [42]});

  List<int> episodeNumbers;
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
          ${episodeNumbers.map((episode) => '''
          <item>
            <title>Stable Dispatch</title>
            <enclosure
              url="https://cdn.example.test/audio.mp3?episode=$episode&amp;token=MEDIA_$_requests"
              type="audio/mpeg"
              length="${42000 + _requests}"
            />
          </item>
          ''').join()}
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
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final token = options.uri.queryParameters['access_token'] ?? 'NONE';
    if (token == 'STALE') {
      started.complete();
      await release.future;
    }
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
