import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/app/theme.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/article_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/presentation/widgets/article_content.dart';

void main() {
  late AppDatabase database;
  late PrivateFeedStore secrets;
  late _PageAdapter adapter;
  late SafeNetworkClient network;
  late ArticleRepository repository;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
    secrets = PrivateFeedStore(storage: const FlutterSecureStorage());
    adapter = _PageAdapter();
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    repository = ArticleRepository(database, network, secrets);
  });

  tearDown(() async {
    network.close();
    await database.close();
  });

  test(
    'long summaries fetch the article and short reader caches stay offline',
    () async {
      final article = await _seed(
        database,
        content: '<p>${List.filled(80, 'Feed summary').join(' ')}</p>',
      );
      adapter.body =
          '<html><head><title>Launch</title></head><body>'
          '<nav>Navigation</nav><article><h1>Launch</h1>'
          '<p>A short, complete article, with useful details and a conclusion.</p>'
          '<p>Read the <a href="/more">follow-up</a>.</p>'
          '</article><script>unsafe()</script></body></html>';
      final result = await repository.load(article);
      expect(result.readerFallback, isFalse);
      expect(result.text, contains('A short, complete article'));
      expect(result.html, contains('https://publisher.test/more'));
      expect(result.html, isNot(contains('unsafe()')));
      expect(result.text, isNot(contains('Feed summary')));

      final stored = (await database.articleById(article.id))!;
      expect(stored.contentHtml, article.contentHtml);
      expect(stored.readerFetchedAt, isNotNull);
      adapter.statusCode = 503;
      expect((await repository.load(stored)).html, result.html);
      expect(adapter.requests, hasLength(1));
      final offline = await repository.load(stored, forceRefresh: true);
      expect(offline.html, result.html);
      expect(offline.readerFallback, isTrue);
      expect((await database.articleById(article.id))?.readerHtml, result.html);
    },
  );

  test(
    'late article responses cannot replace a changed source or deleted item',
    () async {
      final article = await _seed(database);
      adapter.body =
          '<article><p>This is a readable article, with enough text '
          'to preserve the useful content, even though it is short.</p></article>';
      adapter.beforeResponse = () async {
        await (database.update(
          database.articles,
        )..where((a) => a.id.equals(article.id))).write(
          const ArticlesCompanion(
            canonicalUrl: Value('https://publisher.test/new'),
          ),
        );
      };
      await repository.load(article);
      expect((await database.articleById(article.id))?.readerHtml, isNull);
      adapter.beforeResponse = () async {
        await (database.delete(
          database.articles,
        )..where((a) => a.id.equals(article.id))).go();
      };
      await repository.load(article);
      expect(await database.articleById(article.id), isNull);
      expect(await database.search('readable'), isEmpty);
    },
  );

  test(
    'private reader requests keep credentials on their own origin and recover from non-HTML pages',
    () async {
      final article = await _seed(
        database,
        content: '<p>Offline feed text</p><script>unsafe()</script>',
      );
      final credential = await secrets.save(
        PrivateFeedSecret(
          url: Uri.parse('https://publisher.test/feed'),
          headers: const {'Authorization': 'Bearer private'},
        ),
      );
      await (database.update(
        database.feeds,
      )..where((f) => f.id.equals('feed'))).write(
        FeedsCompanion(
          isPrivate: const Value(true),
          credentialRef: Value(credential),
        ),
      );
      adapter.contentType = 'application/pdf';
      adapter.body = '%PDF';
      final fallback = await repository.load(article);
      expect(fallback.text, 'Offline feed text');
      expect(fallback.readerFallback, isTrue);
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer private',
      );
      await repository.load(
        article.copyWith(canonicalUrl: const Value('https://other.test/page')),
      );
      expect(
        adapter.requests.last.headers.containsKey('Authorization'),
        isFalse,
      );
      final feedOnly = await repository.load(
        article.copyWith(canonicalUrl: const Value(null)),
      );
      expect(feedOnly.text, 'Offline feed text');
      expect(feedOnly.readerFallback, isFalse);
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'preview discovery still deduplicates requests and stores publisher artwork',
    () async {
      final article = await _seed(database);
      adapter.body =
          '<head><meta property="og:image" content="/cover.jpg"></head>';
      final images = await Future.wait([
        repository.previewImageById(article.id),
        repository.previewImageById(article.id),
      ]);
      expect(images, everyElement('https://publisher.test/cover.jpg'));
      expect(adapter.requests, hasLength(1));
      expect((await database.articleById(article.id))?.imageUrl, images.first);
    },
  );

  test(
    'HTML safety preserves article structure without publisher code or styling',
    () {
      final result = sanitizeArticleHtml('''
      <p>inter<strong>operable</strong> text <a href="javascript:bad()">unsafe link</a></p>
      <table style="background-image:url(https://tracker.test/pixel)"><tr><th>Item</th><td colspan="2">Value</td><td colspan="999999999" rowspan="-1">Malformed spans</td></tr></table>
      <ol start="10"><li>Outer<ul><li>Inner</li></ul></li></ol>
      <picture><source srcset="/small.jpg 1x, /large.jpg 2x"><img src="data:image/gif;base64,a" alt="Artwork"></picture>
      <img src="file:///private/key"><script>secret()</script><iframe>Tracking</iframe>
    ''', 'https://publisher.test/article');
      expect(result.html, contains('inter<strong>operable</strong>'));
      expect(
        result.html,
        contains('<table><tbody><tr><th>Item</th><td colspan="2">Value</td>'),
      );
      expect(result.html, contains('<ol start="10"><li>Outer<ul><li>Inner'));
      expect(result.html, contains('https://publisher.test/large.jpg'));
      expect(result.html, contains('<td>Malformed spans</td>'));
      for (final unsafe in [
        'javascript:',
        'file:',
        'data:',
        '<script',
        '<iframe',
        'tracker.test',
        'secret()',
      ]) {
        expect(result.html, isNot(contains(unsafe)));
      }
    },
  );

  testWidgets('reader content stays scrollable and lazy at large text sizes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SelectionArea(
              child: CustomScrollView(
                slivers: [
                  ArticleContent(
                    html:
                        '<article><div><h1>Page title</h1><p>Introduction</p>'
                        '<table><tr><th>Item</th><th>Value</th></tr><tr><td>Signal</td><td>42</td></tr></table>'
                        '<ol start="100"><li>Outer<ul><li>Inner</li></ul></li></ol>'
                        '${List.generate(100, (i) => '<p>Paragraph $i</p>').join()}</div></article>',
                    scale: 1,
                    sliver: true,
                    leadingTitleToOmit: 'Page title',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Page title', findRichText: true), findsNothing);
    expect(find.text('Introduction', findRichText: true), findsOneWidget);
    expect(find.text('Paragraph 99', findRichText: true), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Paragraph 99', findRichText: true),
      500,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 100,
    );
    expect(find.text('Paragraph 99', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader images obey privacy settings and never forward credentials to other hosts',
    (tester) async {
      final enabled = StreamController<bool>();
      addTearDown(enabled.close);
      final requests = <({String url, Map<String, String> headers})>[];
      final opened = <String>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') {
          opened.add(call.arguments['url'] as String);
        }
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remoteImagesProvider.overrideWith((_) => enabled.stream),
            safeImageFileProvider.overrideWith((_, request) async {
              requests.add(request);
              return null;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ArticleContent(
                  html:
                      '<a href="https://publisher.test/full"><img src="https://publisher.test/cover.jpg" width="320" height="180"></a>'
                      '<table><tr><td><img src="https://cdn.test/cover.jpg"></td></tr></table><img src="file:///private/key">',
                  scale: 1,
                  privateSecret: PrivateFeedSecret(
                    url: Uri.parse('https://publisher.test/feed'),
                    headers: const {'Authorization': 'Bearer private'},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      enabled.add(false);
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      enabled.add(true);
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));
      expect(requests.first.headers['Authorization'], 'Bearer private');
      expect(requests.last.headers, isEmpty);
      expect(find.text('Image unavailable'), findsNWidgets(2));
      await tester.tap(
        find.byKey(
          const ValueKey('article-image:https://publisher.test/cover.jpg'),
        ),
      );
      await tester.pumpAndSettle();
      expect(opened, ['https://publisher.test/full']);
      enabled.add(false);
      await tester.pumpAndSettle();
      expect(find.text('Image unavailable'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<Article> _seed(AppDatabase database, {String? content}) async {
  final now = DateTime.utc(2026, 10, 7);
  await database
      .into(database.feeds)
      .insert(
        FeedsCompanion.insert(
          id: 'feed',
          title: 'Signal',
          feedUrl: 'https://publisher.test/feed',
          kind: Value(FeedKind.reader.index),
          createdAt: now,
          updatedAt: now,
        ),
      );
  await database
      .into(database.articles)
      .insert(
        ArticlesCompanion.insert(
          id: 'article',
          feedId: 'feed',
          title: 'Launch',
          contentHtml: Value(content),
          canonicalUrl: const Value('https://publisher.test/launch'),
          discoveredAt: now,
        ),
      );
  return (await database.articleById('article'))!;
}

final class _PageAdapter implements HttpClientAdapter {
  String body = '';
  String contentType = 'text/html';
  int statusCode = 200;
  Future<void> Function()? beforeResponse;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await beforeResponse?.call();
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
