import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/services/opml_service.dart';
import 'package:xml/xml.dart';

void main() {
  test('exports interoperable podcast OPML', () {
    final source = buildOpmlDocument(
      title: 'trickle podcasts',
      subscriptions: const [
        OpmlSubscription(
          title: 'Signal & Noise',
          feedUrl: 'https://example.com/feed.xml?token=a&mode=full',
          siteUrl: 'https://example.com/show',
        ),
      ],
    );

    final document = XmlDocument.parse(source);
    final root = document.rootElement;
    final outline = document.findAllElements('outline').single;

    expect(root.name.local, 'opml');
    expect(root.getAttribute('version'), '2.0');
    expect(
      document.findAllElements('title').single.innerText,
      'trickle podcasts',
    );
    expect(outline.getAttribute('type'), 'rss');
    expect(outline.getAttribute('text'), 'Signal & Noise');
    expect(
      outline.getAttribute('xmlUrl'),
      'https://example.com/feed.xml?token=a&mode=full',
    );
    expect(outline.getAttribute('htmlUrl'), 'https://example.com/show');
  });

  test('round-trips reader categories as standard OPML folders', () {
    final source = buildOpmlDocument(
      title: 'trickle feeds',
      subscriptions: const [
        OpmlSubscription(
          title: 'Science Daily',
          feedUrl: 'https://science.test/rss',
          category: 'Science',
        ),
        OpmlSubscription(
          title: 'World News',
          feedUrl: 'https://news.test/rss',
          category: 'News',
        ),
        OpmlSubscription(
          title: 'Loose Feed',
          feedUrl: 'https://loose.test/rss',
        ),
      ],
    );

    final document = XmlDocument.parse(source);
    final topLevel = document.rootElement
        .findElements('body')
        .single
        .findElements('outline')
        .toList();
    final imported = extractOpmlSubscriptions(source);

    expect(topLevel.map((outline) => outline.getAttribute('text')), [
      'News',
      'Science',
      'Loose Feed',
    ]);
    expect(
      imported.map(
        (subscription) => (subscription.title, subscription.category),
      ),
      [
        ('World News', 'News'),
        ('Science Daily', 'Science'),
        ('Loose Feed', null),
      ],
    );
  });

  test(
    'podcast, feed, and all exports preserve scope and portable URLs',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final privateFeeds = PrivateFeedStore(
        storage: const FlutterSecureStorage(),
      );
      addTearDown(database.close);
      final now = DateTime.utc(2026, 7, 15);
      for (final entry in const [
        ('podcast', 'Podcast', FeedKind.podcast, false),
        ('reader', 'Reader', FeedKind.reader, false),
        ('private', 'Private', FeedKind.podcast, true),
        ('token', 'Token', FeedKind.podcast, true),
        ('missing', 'Missing', FeedKind.podcast, true),
        ('corrupt', 'Corrupt', FeedKind.podcast, true),
      ]) {
        await database
            .into(database.feeds)
            .insert(
              FeedsCompanion.insert(
                id: entry.$1,
                title: entry.$2,
                feedUrl: entry.$4
                    ? 'private://${entry.$1}'
                    : 'https://${entry.$1}.test/rss',
                category: Value(entry.$1 == 'reader' ? 'Technology' : null),
                kind: Value(entry.$3.index),
                isPrivate: Value(entry.$4),
                credentialRef: Value(entry.$4 ? entry.$1 : null),
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      await privateFeeds.save(
        PrivateFeedSecret(
          url: Uri.parse('https://private.test/rss?token=SECRET'),
          headers: {'Authorization': 'Bearer omitted-from-opml'},
        ),
        existingId: 'private',
      );
      await privateFeeds.save(
        PrivateFeedSecret(
          url: Uri.parse('https://token.test/rss?token=SECRET'),
          headers: const {},
        ),
        existingId: 'token',
      );
      await const FlutterSecureStorage().write(
        key: 'private-feed:corrupt',
        value: 'not valid JSON',
      );

      final podcastDocument = await buildOpmlExportDocument(
        database,
        privateFeeds: privateFeeds,
        scope: OpmlExportScope.podcasts,
      );
      final allDocument = await buildOpmlExportDocument(
        database,
        privateFeeds: privateFeeds,
        scope: OpmlExportScope.allSubscriptions,
      );
      final readingDocument = await buildOpmlExportDocument(
        database,
        privateFeeds: privateFeeds,
        scope: OpmlExportScope.reading,
      );
      final podcasts = _opmlUrls(podcastDocument.xml);
      final allSubscriptions = _opmlUrls(allDocument.xml);
      final reading = _opmlUrls(readingDocument.xml);
      final podcastSubscriptions = extractOpmlSubscriptions(
        podcastDocument.xml,
      );
      final exportedSubscriptions = extractOpmlSubscriptions(allDocument.xml);
      final readingSubscriptions = extractOpmlSubscriptions(
        readingDocument.xml,
      );

      expect(podcasts, [
        'https://podcast.test/rss',
        'https://token.test/rss?token=SECRET',
      ]);
      expect(allSubscriptions, [
        'https://reader.test/rss',
        'https://podcast.test/rss',
        'https://token.test/rss?token=SECRET',
      ]);
      expect(reading, ['https://reader.test/rss']);
      expect(
        podcastSubscriptions.map((subscription) => subscription.category),
        everyElement(isNull),
      );
      expect(
        exportedSubscriptions
            .singleWhere(
              (subscription) =>
                  subscription.feedUrl == 'https://reader.test/rss',
            )
            .category,
        'Technology',
      );
      expect(
        exportedSubscriptions
            .where(
              (subscription) =>
                  subscription.feedUrl != 'https://reader.test/rss',
            )
            .map((subscription) => subscription.category),
        everyElement(isNull),
      );
      expect(readingSubscriptions.single.category, 'Technology');
      expect(podcastDocument.exported, 2);
      expect(podcastDocument.skippedHeaderAuth, 1);
      expect(podcastDocument.skippedMissingCredentials, 2);
      expect(allDocument.exported, 3);
      expect(allDocument.skippedHeaderAuth, 1);
      expect(allDocument.skippedMissingCredentials, 2);
      expect(readingDocument.exported, 1);
      expect(readingDocument.skippedHeaderAuth, 0);
      expect(readingDocument.skippedMissingCredentials, 0);
    },
  );

  test(
    'mixed import classifies podcasts and reading feeds exactly once',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final dio = Dio()..httpClientAdapter = _MixedOpmlFeedAdapter();
      final network = SafeNetworkClient.forTesting(
        dio,
        addressValidator: (_) async {},
      );
      final privateFeeds = PrivateFeedStore(
        storage: const FlutterSecureStorage(),
      );
      final feeds = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      const source = '''
        <opml version="2.0"><body>
          <outline text="Podcasts">
            <outline text="Imported show"
              xmlUrl="https://podcast.test/rss?token=SECRET" />
          </outline>
          <outline text="Technology">
            <outline text="Written signal"
              xmlUrl="https://reader.test/rss" />
          </outline>
        </body></opml>
      ''';
      final service = OpmlService(
        database,
        feeds,
        privateFeeds,
        pickFile: () async => XFile.fromData(
          Uint8List.fromList(utf8.encode(source)),
          name: 'subscriptions.opml',
          mimeType: 'text/x-opml',
        ),
      );
      addTearDown(() async {
        network.close();
        await database.close();
      });

      final result = await service.pickAndImport();

      expect(result?.imported, 2);
      expect(result?.failed, 0);
      final importedFeeds = await database.select(database.feeds).get();
      expect(importedFeeds, hasLength(2));
      final podcast = importedFeeds.singleWhere(
        (feed) => feed.kind == FeedKind.podcast.index,
      );
      final reader = importedFeeds.singleWhere(
        (feed) => feed.kind == FeedKind.reader.index,
      );
      expect(podcast.title, 'Imported show');
      expect(podcast.category, isNull);
      expect(podcast.isPrivate, isTrue);
      expect(reader.title, 'Written signal');
      expect(reader.category, 'Technology');
      final episodes = await database.select(database.episodes).get();
      final articles = await database.select(database.articles).get();
      expect(episodes, hasLength(1));
      expect(episodes.single.feedId, podcast.id);
      expect(articles, hasLength(1));
      expect(articles.single.feedId, reader.id);
    },
  );

  test('decodes UTF-8 and UTF-16 OPML files', () {
    const source =
        '<?xml version="1.0"?><opml version="2.0"><body></body></opml>';
    final utf16LittleEndian = <int>[0xFF, 0xFE];
    final utf16BigEndian = <int>[0xFE, 0xFF];
    for (final codeUnit in source.codeUnits) {
      utf16LittleEndian.add(codeUnit & 0xFF);
      utf16LittleEndian.add(codeUnit >> 8);
      utf16BigEndian.add(codeUnit >> 8);
      utf16BigEndian.add(codeUnit & 0xFF);
    }

    expect(decodeOpmlBytes(utf8.encode(source)), source);
    expect(decodeOpmlBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(source)]), source);
    expect(decodeOpmlBytes(utf16LittleEndian), source);
    expect(decodeOpmlBytes(utf16BigEndian), source);
  });

  test('imports nested OPML and deduplicates feed URLs', () async {
    const source = '''
      <opml version="1.0">
        <head><title>Podcast subscriptions</title></head>
        <body>
          <outline text="feeds" xmlUrl="">
            <outline text="One" type="rss" xmlUrl="https://one.test/rss" />
            <outline text="Duplicate" xmlUrl=" https://one.test/rss " />
            <outline text="Equivalent" xmlUrl="HTTP://ONE.TEST/rss#fragment" />
            <outline text="Two" XMLURL="https://two.test/feed.xml" />
          </outline>
        </body>
      </opml>
    ''';
    final imported = <OpmlSubscription>[];

    final result = await importOpmlSubscriptions(
      source,
      subscribe: (subscription) async => imported.add(subscription),
    );

    expect(imported.map((subscription) => subscription.feedUrl), [
      'https://one.test/rss',
      'https://two.test/feed.xml',
    ]);
    expect(
      imported.map((subscription) => subscription.category),
      everyElement('feeds'),
    );
    expect(result.imported, 2);
    expect(result.failed, 0);
  });

  test('continues after an individual subscription fails', () async {
    const source = '''
      <opml version="2.0"><body>
        <outline xmlUrl="https://one.test/rss" />
        <outline xmlUrl="not a feed URL" />
        <outline xmlUrl="https://two.test/rss" />
      </body></opml>
    ''';
    final attempted = <String>[];

    final result = await importOpmlSubscriptions(
      source,
      subscribe: (subscription) async {
        attempted.add(subscription.feedUrl);
        if (!subscription.feedUrl.startsWith('https://')) {
          throw const FormatException();
        }
      },
    );

    expect(attempted, hasLength(3));
    expect(result.imported, 2);
    expect(result.failed, 1);
  });

  test('reports deterministic progress for a standard podcast OPML', () async {
    const source = '''
      <?xml version="1.0" encoding="UTF-8"?>
      <opml version="2.0">
        <head>
          <title>Podcast subscriptions</title>
          <dateCreated>Sat, 18 Jul 2026 17:00:42 GMT</dateCreated>
        </head>
        <body>
          <outline text="One" type="rss" xmlUrl="https://one.test/rss" />
          <outline text="Two" type="rss" xmlUrl="https://two.test/rss" />
          <outline text="Three" type="rss" xmlUrl="https://three.test/rss" />
          <outline text="Four" type="rss" xmlUrl="https://four.test/rss" />
          <outline text="Five" type="rss" xmlUrl="https://five.test/rss" />
        </body>
      </opml>
    ''';
    final progress = <(int, int)>[];

    final result = await importOpmlSubscriptions(
      source,
      subscribe: (_) async {},
      onProgress: (completed, total) => progress.add((completed, total)),
    );

    expect(result.imported, 5);
    expect(result.failed, 0);
    expect(progress, [(0, 5), (4, 5), (5, 5)]);
  });

  test('reuses an active import instead of reopening the picker', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final network = SafeNetworkClient.forTesting(
      Dio(),
      addressValidator: (_) async {},
    );
    final privateFeeds = PrivateFeedStore(
      storage: const FlutterSecureStorage(),
    );
    final feeds = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
    final picker = Completer<XFile?>();
    var pickerCalls = 0;
    final service = OpmlService(
      database,
      feeds,
      privateFeeds,
      pickFile: () {
        pickerCalls++;
        return picker.future;
      },
    );
    addTearDown(() async {
      network.close();
      await database.close();
    });

    final first = service.pickAndImport();
    final second = service.pickAndImport();

    expect(identical(first, second), isTrue);
    expect(pickerCalls, 1);
    picker.complete(null);
    expect(await first, null);
    expect(await second, null);
    await Future<void>.delayed(Duration.zero);
    expect(await service.pickAndImport(), null);
    expect(pickerCalls, 2);
  });

  test('rejects malformed OPML without attempting partial import', () async {
    var attempts = 0;

    await expectLater(
      importOpmlSubscriptions(
        '<opml><body><outline xmlUrl="https://example.test/rss"></body>',
        subscribe: (_) async => attempts++,
      ),
      throwsA(isA<XmlException>()),
    );
    expect(attempts, 0);
  });

  test('rejects well-formed XML that is not OPML', () async {
    var attempts = 0;

    await expectLater(
      importOpmlSubscriptions(
        '<feeds><item xmlUrl="https://example.test/rss" /></feeds>',
        subscribe: (_) async => attempts++,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'The selected file is not an OPML document.',
        ),
      ),
    );
    expect(attempts, 0);
  });

  test('caps one import at one thousand unique subscriptions', () {
    final outlines = List.generate(
      1005,
      (index) => '<outline xmlUrl="https://example.test/$index" />',
    ).join();
    final subscriptions = extractOpmlSubscriptions(
      '<opml version="2.0"><body>$outlines</body></opml>',
    );

    expect(subscriptions, hasLength(1000));
    expect(subscriptions.first.feedUrl, 'https://example.test/0');
    expect(subscriptions.last.feedUrl, 'https://example.test/999');
  });
}

List<String> _opmlUrls(String source) => [
  for (final subscription in extractOpmlSubscriptions(source))
    subscription.feedUrl,
];

final class _MixedOpmlFeedAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final source = switch (options.uri.host) {
      'podcast.test' =>
        '''
        <rss version="2.0"><channel>
          <title>Imported show</title>
          <item>
            <guid>episode-1</guid>
            <title>Playable episode</title>
            <enclosure url="https://cdn.test/episode.mp3"
              type="audio/mpeg" />
          </item>
        </channel></rss>
      ''',
      'reader.test' =>
        '''
        <rss version="2.0"><channel>
          <title>Written signal</title>
          <item>
            <guid>article-1</guid>
            <title>Readable article</title>
            <link>https://reader.test/article</link>
          </item>
        </channel></rss>
      ''',
      _ => throw StateError('Unexpected request: ${options.uri}'),
    };
    return ResponseBody.fromString(
      source,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/rss+xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
