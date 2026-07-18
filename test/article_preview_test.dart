import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/article_repository.dart';
import 'package:trickle/data/repositories/feed_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/presentation/pages/article_page.dart';
import 'package:trickle/presentation/widgets/article_content.dart';

void main() {
  late AppDatabase database;
  late PrivateFeedStore privateFeeds;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
    privateFeeds = PrivateFeedStore(storage: const FlutterSecureStorage());
  });

  tearDown(() async {
    await database.close();
  });

  test('discovers, deduplicates, and stores an Open Graph preview', () async {
    final adapter = _StaticAdapter(
      body: '''
        <html><head>
          <meta property="og:image" content="/images/launch.jpg">
        </head><body></body></html>
      ''',
      contentType: 'text/html; charset=utf-8',
    );
    final network = _client(adapter);
    final repository = ArticleRepository(database, network, privateFeeds);
    final article = await _seedArticle(database);

    final results = await Future.wait([
      repository.previewImage(article),
      repository.previewImage(article),
    ]);

    expect(results, everyElement('https://publisher.test/images/launch.jpg'));
    expect(adapter.requests, 1);
    expect(
      (await database.articleById(article.id))?.imageUrl,
      'https://publisher.test/images/launch.jpg',
    );
  });

  test('a non-HTML preview miss is not repeatedly fetched', () async {
    final adapter = _StaticAdapter(
      body: '%PDF',
      contentType: 'application/pdf',
    );
    final network = _client(adapter);
    final repository = ArticleRepository(database, network, privateFeeds);
    final article = await _seedArticle(database);

    expect(await repository.previewImage(article), isNull);
    expect(await repository.previewImage(article), isNull);
    expect(adapter.requests, 1);
    expect((await database.articleById(article.id))?.imageUrl, isNull);
  });

  test(
    'whitespace image metadata does not suppress preview discovery',
    () async {
      final adapter = _StaticAdapter(
        body: '''
        <html><head>
          <meta property="og:image" content="/images/discovered.jpg">
        </head><body></body></html>
      ''',
        contentType: 'text/html',
      );
      final network = _client(adapter);
      final repository = ArticleRepository(database, network, privateFeeds);
      final article = await _seedArticle(database);
      await (database.update(database.articles)
            ..where((row) => row.id.equals(article.id)))
          .write(const ArticlesCompanion(imageUrl: Value('   ')));
      final stored = (await database.articleById(article.id))!;

      expect(
        await repository.previewImage(stored),
        'https://publisher.test/images/discovered.jpg',
      );
      expect(adapter.requests, 1);
      expect(
        (await database.articleById(article.id))?.imageUrl,
        'https://publisher.test/images/discovered.jpg',
      );
    },
  );

  test(
    'reader mode sanitizes complete feed content without fetching',
    () async {
      final adapter = _StaticAdapter(body: 'unused', contentType: 'text/html');
      final network = _client(adapter);
      final repository = ArticleRepository(database, network, privateFeeds);
      final article = await _seedArticle(
        database,
        contentHtml:
            '<p>${List.filled(70, 'Readable feed content').join(' ')}</p>'
            '<a href="/details">Details</a><script>unsafe()</script>',
      );

      final result = await repository.load(article);

      expect(adapter.requests, 0);
      expect(result.text, contains('Readable feed content'));
      expect(result.html, isNot(contains('<script')));
      expect(result.html, contains('https://publisher.test/details'));
    },
  );

  test(
    'reader sanitizer discards unsafe subtrees and preserves block wrappers',
    () async {
      final adapter = _StaticAdapter(body: 'unused', contentType: 'text/html');
      final network = _client(adapter);
      final repository = ArticleRepository(database, network, privateFeeds);
      final longBody = List.filled(55, 'Readable body content').join(' ');
      final article = await _seedArticle(
        database,
        contentHtml:
            '''
          <div><p>First block $longBody</p>
            <section><p>Second block</p>
              <img src="/signal.jpg" width="320" height="180" style="display:none">
            </section>
          </div>
          <ol start="301"><li>Numbered block</li></ol>
          <content-wrapper><p>Neutral wrapper child</p></content-wrapper>
          <script>SCRIPT_SECRET</script><style>STYLE_SECRET</style>
          <noscript>NOSCRIPT_SECRET</noscript><iframe>IFRAME_SECRET</iframe>
          <object>OBJECT_SECRET</object><form>FORM_SECRET</form>
          <nav>NAV_SECRET</nav><header>HEADER_SECRET</header>
          <footer>FOOTER_SECRET</footer><aside>ASIDE_SECRET</aside>
          <div class="ad">AD_SECRET</div>
          <div class="social">SOCIAL_SECRET</div>
          <div class="comments">COMMENTS_SECRET</div>
          <label class="share">SHARE_CONTROL</label>
        ''',
      );

      final result = await repository.load(article);

      expect(adapter.requests, 0);
      expect(result.html, contains('<div><p>First block'));
      expect(result.html, contains('<section><p>Second block</p>'));
      expect(result.html, contains('<p>Neutral wrapper child</p>'));
      expect(result.html, contains('width="320"'));
      expect(result.html, contains('height="180"'));
      expect(result.html, isNot(contains('display:none')));
      expect(result.html, contains('<ol start="301">'));
      expect(result.html, isNot(contains('<content-wrapper')));
      for (final secret in const [
        'SCRIPT_SECRET',
        'STYLE_SECRET',
        'NOSCRIPT_SECRET',
        'IFRAME_SECRET',
        'OBJECT_SECRET',
        'FORM_SECRET',
        'NAV_SECRET',
        'HEADER_SECRET',
        'FOOTER_SECRET',
        'ASIDE_SECRET',
        'AD_SECRET',
        'SOCIAL_SECRET',
        'COMMENTS_SECRET',
        'SHARE_CONTROL',
      ]) {
        expect(result.text, isNot(contains(secret)));
        expect(result.html, isNot(contains(secret)));
      }
    },
  );

  test('reader sanitizer separates adjacent inline wrappers', () async {
    final repository = ArticleRepository(
      database,
      _client(_StaticAdapter(body: 'unused', contentType: 'text/html')),
      privateFeeds,
    );

    final result = await repository.sanitizeContent('''
      <div>
        <span><time>June 2025</time></span><span>Science</span>
        <a href="https://publisher.test/details">
          <div></div><div>Learn more</div>
        </a>
      </div>
    ''');

    expect(result.text, contains('June 2025 Science'));
    expect(result.text, isNot(contains('2025Science')));
  });

  test('reader resolves base URLs and publisher lazy images', () async {
    final adapter = _StaticAdapter(
      body: '''
        <html><head><base href="https://cdn.publisher.test/articles/"></head>
        <body><article>
          <p>The article uses publisher-relative resources.</p>
          <a href="sources/report.html">Source report</a>
          <img data-src="images/lazy.jpg" alt="Lazy image">
          <picture>
            <source srcset="images/small.jpg 480w, images/large.jpg 1280w">
            <img alt="Responsive image">
          </picture>
          <img src="javascript:unsafe()" alt="Unsafe image">
        </article></body></html>
      ''',
      contentType: 'text/html',
    );
    final repository = ArticleRepository(
      database,
      _client(adapter),
      privateFeeds,
    );

    final result = await repository.load(await _seedArticle(database));

    expect(
      result.html,
      contains(
        'href="https://cdn.publisher.test/articles/sources/report.html"',
      ),
    );
    expect(
      result.html,
      contains('src="https://cdn.publisher.test/articles/images/lazy.jpg"'),
    );
    expect(
      result.html,
      contains('src="https://cdn.publisher.test/articles/images/large.jpg"'),
    );
    expect(result.html, isNot(contains('data-src')));
    expect(result.html, isNot(contains('srcset')));
    expect(result.html, isNot(contains('javascript:')));
    expect(result.html, isNot(contains('Unsafe image')));
  });

  test(
    'preview discovery tries responsive sources before placeholders',
    () async {
      final adapter = _StaticAdapter(
        body: '''
        <html><body><main>
          <picture>
            <source data-srcset="" srcset="/images/card-small.jpg 480w, /images/card-large.jpg 1280w">
            <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" alt="Preview">
          </picture>
        </main></body></html>
      ''',
        contentType: 'text/html',
      );
      final repository = ArticleRepository(
        database,
        _client(adapter),
        privateFeeds,
      );

      final image = await repository.previewImage(await _seedArticle(database));

      expect(image, 'https://publisher.test/images/card-large.jpg');
    },
  );

  test('reader falls back instead of rendering a non-HTML response', () async {
    final repository = ArticleRepository(
      database,
      _client(_StaticAdapter(body: '%PDF', contentType: 'application/pdf')),
      privateFeeds,
    );

    final result = await repository.load(
      await _seedArticle(database, summary: 'Publisher supplied summary.'),
    );

    expect(result.readerFallback, isTrue);
    expect(result.text, 'Publisher supplied summary.');
    expect(result.text, isNot(contains('%PDF')));
  });

  test(
    'reader refreshes a markup-heavy card cache and selects the article body',
    () async {
      final actualBody = List.filled(
        35,
        'The actual article explains the important research.',
      ).join(' ');
      final adapter = _StaticAdapter(
        body:
            '''
          <html><body><main>
            <div><div>Vision</div><h1>Research update</h1>
              <div>&nbsp;min Read</div><div>&nbsp;min watch</div>
            </div>
            <div><p>$actualBody</p><p>A second substantive paragraph.</p></div>
            <section><article>
              <h3>Related story card</h3><div>June 2025Science</div>
            </article></section>
          </main></body></html>
        ''',
        contentType: 'text/html',
      );
      final repository = ArticleRepository(
        database,
        _client(adapter),
        privateFeeds,
      );
      final article = await _seedArticle(
        database,
        contentHtml:
            '<div>June 2025Science'
            '<img src="https://publisher.test/${'x' * 450}.jpg"></div>',
      );

      final result = await repository.load(article);

      expect(adapter.requests, 1);
      expect(result.text, contains('The actual article explains'));
      expect(result.text, contains('A second substantive paragraph.'));
      expect(result.text, isNot(contains('min Read')));
      expect(result.text, isNot(contains('Related story card')));
      expect(
        (await database.articleById(article.id))?.contentHtml,
        result.html,
      );
    },
  );

  test(
    'reader mode extracts and caches article content from the web page',
    () async {
      final adapter = _StaticAdapter(
        body: '''
        <html><body class="has-comments social-sharing-enabled">
          <nav>Navigation noise</nav>
          <article>
            <h1>Launch details</h1>
            <p>The readable article body lives here.</p>
            <a href="/source">Supporting source</a>
          </article>
        </body></html>
      ''',
        contentType: 'text/html',
      );
      final network = _client(adapter);
      final repository = ArticleRepository(database, network, privateFeeds);
      final article = await _seedArticle(database);

      final result = await repository.load(article);

      expect(adapter.requests, 1);
      expect(result.text, contains('The readable article body lives here.'));
      expect(result.readerFallback, isFalse);
      expect(result.text, isNot(contains('Navigation noise')));
      expect(result.html, contains('https://publisher.test/source'));
      expect(
        (await database.articleById(article.id))?.contentHtml,
        result.html,
      );
    },
  );

  test('reader focuses a generic page wrapper on its paragraph body', () async {
    final adapter = _StaticAdapter(
      body:
          '''
        <html><body><div class="page">
          <div><div>Vision</div><h1>Research update</h1>
            <div>&nbsp;min Read</div><div>&nbsp;min watch</div>
          </div>
          <div><div>A concise lead introduces the research.</div>
            <div><p>${List.filled(35, 'Substantive research detail.').join(' ')}</p>
              <p>The article concludes here.</p>
            </div>
          </div>
        </div></body></html>
      ''',
      contentType: 'text/html',
    );
    final repository = ArticleRepository(
      database,
      _client(adapter),
      privateFeeds,
    );

    final result = await repository.load(await _seedArticle(database));

    expect(result.text, contains('A concise lead introduces the research.'));
    expect(result.text, contains('Substantive research detail.'));
    expect(result.text, contains('The article concludes here.'));
    expect(result.text, isNot(contains('min Read')));
    expect(result.text, isNot(contains('min watch')));
  });

  test('reader extraction survives a local cache write failure', () async {
    final adapter = _StaticAdapter(
      body: '''
        <html><body><article>
          <p>The extracted article remains readable.</p>
        </article></body></html>
      ''',
      contentType: 'text/html',
    );
    final network = _client(adapter);
    final repository = ArticleRepository(database, network, privateFeeds);
    final article = await _seedArticle(database);
    await database.customStatement('DROP TABLE search_index');

    final result = await repository.load(article);

    expect(result.text, contains('The extracted article remains readable.'));
    expect(result.readerFallback, isFalse);
  });

  test(
    'reader mode falls back to the feed summary when extraction fails',
    () async {
      final adapter = _StaticAdapter(
        body: 'blocked',
        contentType: 'text/html',
        statusCode: 403,
      );
      final network = _client(adapter);
      final repository = ArticleRepository(database, network, privateFeeds);
      final article = await _seedArticle(
        database,
        summary: 'Publisher supplied summary.',
      );

      final result = await repository.load(article);

      expect(adapter.requests, 1);
      expect(result.text, 'Publisher supplied summary.');
      expect(result.readerFallback, isTrue);
    },
  );

  test(
    'reader mode classifies a short summary without a web URL as fallback',
    () async {
      final adapter = _StaticAdapter(body: 'unused', contentType: 'text/html');
      final network = _client(adapter);
      final repository = ArticleRepository(database, network, privateFeeds);
      final article = await _seedArticle(
        database,
        summary: 'Publisher supplied summary.',
        canonicalUrl: null,
      );

      final result = await repository.load(article);

      expect(adapter.requests, 0);
      expect(result.text, 'Publisher supplied summary.');
      expect(result.readerFallback, isTrue);
    },
  );

  test(
    'reader mode falls back when the fetched page has no readable body',
    () async {
      final adapter = _StaticAdapter(
        body: '<html><body><nav>Navigation only</nav></body></html>',
        contentType: 'text/html',
      );
      final network = _client(adapter);
      final repository = ArticleRepository(database, network, privateFeeds);
      final article = await _seedArticle(
        database,
        summary: 'Publisher supplied summary.',
      );

      final result = await repository.load(article);

      expect(adapter.requests, 1);
      expect(result.text, 'Publisher supplied summary.');
      expect(result.readerFallback, isTrue);
    },
  );

  testWidgets('reader fallback is clearly labeled with recovery actions', (
    tester,
  ) async {
    final adapter = _StaticAdapter(
      body: 'blocked',
      contentType: 'text/html',
      statusCode: 403,
    );
    final network = _client(adapter);
    final article = await _seedArticle(
      database,
      summary: 'Publisher supplied summary.',
    );
    final feed = (await database.feedById(article.feedId))!;
    final articles = ArticleRepository(database, network, privateFeeds);
    final feeds = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          networkProvider.overrideWithValue(network),
          privateFeedStoreProvider.overrideWithValue(privateFeeds),
          articleRepositoryProvider.overrideWithValue(articles),
          feedRepositoryProvider.overrideWithValue(feeds),
          articleProvider(
            article.id,
          ).overrideWith((_) => Stream.value(article)),
          feedProvider(feed.id).overrideWith((_) => Stream.value(feed)),
          privateFeedSecretProvider(feed.id).overrideWith((_) async => null),
        ],
        child: MaterialApp(home: ArticlePage(articleId: article.id)),
      ),
    );
    await _waitForText(tester, 'Reader view unavailable');

    expect(find.text('Reader view unavailable'), findsOneWidget);
    expect(find.text('Showing the feed summary instead.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open in browser'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'feed refresh preserves a preview discovered outside the feed',
    () async {
      final adapter = _StaticAdapter(
        body: '''
        <rss version="2.0"><channel>
          <title>Signal</title>
          <link>https://publisher.test/</link>
          <item>
            <guid>post-1</guid>
            <title>Launch</title>
            <link>https://publisher.test/launch</link>
            <description>Details</description>
          </item>
        </channel></rss>
      ''',
        contentType: 'application/rss+xml',
      );
      final network = _client(adapter);
      final feeds = FeedRepository(
        database: database,
        network: network,
        privateFeeds: privateFeeds,
      );
      final feed = await feeds.subscribe('https://publisher.test/feed.xml');
      final article = (await database.select(database.articles).get()).single;
      await (database.update(
        database.articles,
      )..where((row) => row.id.equals(article.id))).write(
        const ArticlesCompanion(
          imageUrl: Value('https://publisher.test/preview.jpg'),
        ),
      );

      expect(await feeds.refreshFeed(feed), isTrue);

      expect(
        (await database.articleById(article.id))?.imageUrl,
        'https://publisher.test/preview.jpg',
      );
    },
  );

  testWidgets(
    'article renderer preserves wrappers and renders nested linked images once',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remoteImagesProvider.overrideWith((_) => Stream.value(true)),
            safeImageFileProvider.overrideWith(
              (_, _) => Completer<String?>().future,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 700,
                  child: ArticleContent(
                    scale: 1,
                    html: '''
                    <div><p>First paragraph.</p>
                      <section><p>Second paragraph.</p></section>
                    </div>
                    <p>Image paragraph
                      <a href="https://publisher.test/gallery">
                        <img src="https://publisher.test/one.jpg" alt="First image">
                      </a>
                    </p>
                    <figure>
                      <a href="https://publisher.test/source">
                        <img src="https://publisher.test/two.jpg" alt="Second image">
                      </a>
                      <figcaption>Image caption.</figcaption>
                    </figure>
                    <p><a href="javascript:unsafe()">
                      <img src="https://publisher.test/three.jpg" alt="Unlinked image">
                    </a></p>
                  ''',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('First paragraph.'), findsOneWidget);
      expect(find.text('Second paragraph.'), findsOneWidget);
      expect(find.textContaining('Image paragraph'), findsOneWidget);
      expect(find.text('Image caption.'), findsOneWidget);
      for (final url in const [
        'https://publisher.test/one.jpg',
        'https://publisher.test/two.jpg',
        'https://publisher.test/three.jpg',
      ]) {
        expect(find.byKey(ValueKey('article-image:$url')), findsOneWidget);
        expect(
          tester.getSize(find.byKey(ValueKey('article-image:$url'))).height,
          96,
        );
      }
      // Only HTTPS image links become tap targets.
      expect(find.byType(InkWell), findsNWidgets(2));
      for (final label in const ['First image', 'Second image']) {
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      }
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('article renderer omits only a matching first heading', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ArticleContent(
            scale: 1,
            leadingTitleToOmit: 'A Useful Headline: Studio Name',
            html: '''
              <div>July 16, 2026 · Science</div>
              <h1> A Useful   Headline </h1>
              <p>Article body.</p>
              <h2>A Useful Headline</h2>
            ''',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('July 16, 2026 · Science'), findsOneWidget);
    expect(find.text('A Useful Headline'), findsOneWidget);
    expect(find.text('Article body.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('article renderer preserves a matching heading after content', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ArticleContent(
            scale: 1,
            leadingTitleToOmit: 'Section title',
            html: '<p>Opening paragraph.</p><h2>Section title</h2>',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Opening paragraph.'), findsOneWidget);
    expect(find.text('Section title'), findsOneWidget);
  });

  testWidgets('article renderer normalizes inline and link whitespace', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ArticleContent(
            scale: 1,
            html: '''
              <p>  Alpha
                <strong>signal</strong>  </p>
              <a href="https://publisher.test/details">
                <div></div> <div>Learn more</div>
              </a>
              <p>First line<br>Second line</p>
            ''',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Alpha signal'), findsOneWidget);
    expect(find.text('Learn more'), findsOneWidget);
    expect(find.text('First line\nSecond line'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty headings do not block duplicate-title suppression', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ArticleContent(
            scale: 1,
            leadingTitleToOmit: 'Article title',
            html:
                '<h1><img src="bad:" alt=""></h1><h1>Article title</h1><p>Body.</p>',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Article title'), findsNothing);
    expect(find.text('Body.'), findsOneWidget);
  });

  testWidgets(
    'article image placeholders honor dimensions and survive errors',
    (tester) async {
      const sizedUrl = 'https://publisher.test/sized.jpg';
      const failedUrl = 'https://publisher.test/failed.jpg';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remoteImagesProvider.overrideWith((_) => Stream.value(true)),
            safeImageFileProvider.overrideWith((_, request) async {
              return request.url == failedUrl
                  ? null
                  : Completer<String?>().future;
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 700,
                child: ArticleContent(
                  scale: 1,
                  html:
                      '''
                  <img src="$sizedUrl" width="160" height="90" alt="Sized image">
                  <img src="$failedUrl" alt="Failed image">
                ''',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        tester.getSize(find.byKey(const ValueKey('article-image:$sizedUrl'))),
        const Size(160, 90),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('article-image:$failedUrl'))),
        const Size(700, 96),
      );
      expect(find.text('Image unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('article renderer keeps images inside quotes and list items', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remoteImagesProvider.overrideWith((_) => Stream.value(true)),
          safeImageFileProvider.overrideWith(
            (_, _) => Completer<String?>().future,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ArticleContent(
                scale: 1,
                html: '''
                  <blockquote>
                    Quoted signal.
                    <a href="https://publisher.test/quote">
                      <img src="https://publisher.test/quote.jpg" alt="Quote image">
                    </a>
                  </blockquote>
                  <ul>
                    <li>
                      Listed signal.
                      <img src="https://publisher.test/list.jpg" alt="List image">
                    </li>
                  </ul>
                ''',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Quoted signal.'), findsOneWidget);
    expect(find.textContaining('Listed signal.'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('article-image:https://publisher.test/quote.jpg'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('article-image:https://publisher.test/list.jpg'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('three-digit ordered-list markers do not clip when scaled', (
    tester,
  ) async {
    final items = List.generate(
      105,
      (index) => '<li>Item ${index + 1}</li>',
    ).join();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 400,
                  child: ArticleContent(html: '<ol>$items</ol>', scale: 1.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final marker = find.text('105.');
    final markerBox = find.ancestor(
      of: marker,
      matching: find.byType(SizedBox),
    );
    expect(marker, findsOneWidget);
    expect(tester.getSize(markerBox.first).width, greaterThan(28));
    expect(tester.takeException(), isNull);
  });

  testWidgets('very long articles reveal blocks progressively', (tester) async {
    final html = List.generate(
      205,
      (index) => '<p>Paragraph $index</p>',
    ).join();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ArticleContent(html: html, scale: 1),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Paragraph 199'), findsOneWidget);
    expect(find.text('Paragraph 204'), findsNothing);
    expect(find.text('Show more'), findsOneWidget);

    await tester.ensureVisible(find.text('Show more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show more'));
    await tester.pump();

    expect(find.text('Paragraph 204'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an oversized paragraph is prepared and revealed in chunks', (
    tester,
  ) async {
    final body = List.generate(8000, (index) => 'signal$index').join(' ');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ArticleContent(
                html: '<p>Paragraph beginning $body paragraph-ending</p>',
                scale: 1,
              ),
            ),
          ),
        ),
      ),
    );
    await _waitForArticlePreparation(tester);

    expect(find.textContaining('Paragraph beginning'), findsOneWidget);
    expect(find.textContaining('paragraph-ending'), findsNothing);
    expect(find.text('Show more'), findsOneWidget);

    await _revealAllArticleContent(tester);

    expect(find.textContaining('paragraph-ending'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'oversized ordered and unordered lists reveal progressively without '
    'resetting numbering',
    (tester) async {
      for (final tag in const ['ol', 'ul']) {
        final items = List.generate(
          80,
          (index) => '<li>$tag item ${index + 1} ${'signal ' * 90}</li>',
        ).join();
        final start = tag == 'ol' ? ' start="301"' : '';
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(tag),
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: ArticleContent(
                    html: '<$tag$start>$items</$tag>',
                    scale: 1,
                  ),
                ),
              ),
            ),
          ),
        );
        await _waitForArticlePreparation(tester);

        expect(find.textContaining('$tag item 80'), findsNothing);
        expect(find.text('Show more'), findsOneWidget);
        if (tag == 'ol') expect(find.text('301.'), findsOneWidget);

        await _revealAllArticleContent(tester);

        expect(find.textContaining('$tag item 80'), findsOneWidget);
        if (tag == 'ol') {
          expect(find.text('301.'), findsOneWidget);
          expect(find.text('380.'), findsOneWidget);
        }
        expect(find.text('Show more'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('an oversized list item keeps a single ordered marker', (
    tester,
  ) async {
    final body = List.generate(8000, (index) => 'item$index').join(' ');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ArticleContent(
                html:
                    '<ol start="7"><li>Item beginning $body item-ending</li></ol>',
                scale: 1,
              ),
            ),
          ),
        ),
      ),
    );
    await _waitForArticlePreparation(tester);

    expect(
      find.text('7.'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
          .where((value) => value.isNotEmpty)
          .join(' | '),
    );
    expect(find.text('8.'), findsNothing);
    expect(find.textContaining('item-ending'), findsNothing);
    expect(find.text('Show more'), findsOneWidget);

    await _revealAllArticleContent(tester);

    expect(find.text('7.'), findsOneWidget);
    expect(find.text('8.'), findsNothing);
    expect(find.textContaining('item-ending'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('oversized raw text is chunked without corrupting text', (
    tester,
  ) async {
    final body = List.generate(5000, (index) => 'raw$index 🚀 &amp;').join(' ');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ArticleContent(
                html: 'Raw beginning $body raw-ending',
                scale: 1,
              ),
            ),
          ),
        ),
      ),
    );
    await _waitForArticlePreparation(tester);

    expect(find.textContaining('Raw beginning'), findsOneWidget);
    expect(find.textContaining('raw-ending'), findsNothing);
    expect(find.text('Show more'), findsOneWidget);

    await _revealAllArticleContent(tester);

    final rendered = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(ArticleContent),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .join();
    expect(rendered, contains('🚀 &'));
    expect(rendered, isNot(contains('�')));
    expect(find.textContaining('raw-ending'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('oversized leaf blocks are revealed progressively', (
    tester,
  ) async {
    final body = List.generate(5000, (index) => 'leaf$index').join(' ');
    for (final tag in const ['h2', 'blockquote', 'pre', 'a', 'code']) {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(tag),
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ArticleContent(
                  html: '<$tag>$tag beginning $body $tag-ending</$tag>',
                  scale: 1,
                ),
              ),
            ),
          ),
        ),
      );
      await _waitForArticlePreparation(tester);

      expect(find.textContaining('$tag beginning'), findsOneWidget);
      expect(find.textContaining('$tag-ending'), findsNothing);
      expect(find.text('Show more'), findsOneWidget);

      await _revealAllArticleContent(tester);

      expect(find.textContaining('$tag-ending'), findsOneWidget);
      expect(find.text('Show more'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('pathological leaf attributes stay within fragment bounds', (
    tester,
  ) async {
    const retainedUrl = 'https://publisher.test/retained.jpg';
    final hugeAlt = List.filled(5000, '🚀').join();
    final hugeUrl =
        'https://publisher.test/${List.filled(9000, 'x').join()}.jpg';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remoteImagesProvider.overrideWith((_) => Stream.value(true)),
          safeImageFileProvider.overrideWith(
            (_, _) => Completer<String?>().future,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ArticleContent(
              html:
                  '<img src="$retainedUrl" alt="$hugeAlt">'
                  '<img src="$hugeUrl" alt="Discarded">',
              scale: 1,
            ),
          ),
        ),
      ),
    );
    await _waitForArticlePreparation(tester);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('article-image:$retainedUrl')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('article-image:$hugeUrl')), findsNothing);
    expect(find.text('This article couldn’t be prepared.'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _revealAllArticleContent(WidgetTester tester) async {
  for (var page = 0; page < 20; page++) {
    final button = find.text('Show more');
    if (button.evaluate().isEmpty) return;
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }
  fail('Article content still had another page after 20 expansions.');
}

Future<void> _waitForArticlePreparation(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  fail('Article preparation did not finish within one second.');
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (find.text(text).evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  final visibleText = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
      .where((value) => value.isNotEmpty)
      .join(' | ');
  fail(
    'Expected text did not appear within five seconds: $text. '
    'Visible text: $visibleText',
  );
}

Future<Article> _seedArticle(
  AppDatabase database, {
  String? contentHtml,
  String? summary,
  String? canonicalUrl = 'https://publisher.test/launch',
}) async {
  final now = DateTime.utc(2026, 7, 17);
  await database
      .into(database.feeds)
      .insert(
        FeedsCompanion.insert(
          id: 'feed',
          title: 'Signal',
          feedUrl: 'https://publisher.test/feed.xml',
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
          summary: Value(summary),
          contentHtml: Value(contentHtml),
          canonicalUrl: Value(canonicalUrl),
          discoveredAt: now,
        ),
      );
  return (await database.articleById('article'))!;
}

SafeNetworkClient _client(HttpClientAdapter adapter) {
  final client = SafeNetworkClient.forTesting(
    Dio()..httpClientAdapter = adapter,
    addressValidator: (_) async {},
  );
  addTearDown(client.close);
  return client;
}

final class _StaticAdapter implements HttpClientAdapter {
  _StaticAdapter({
    required this.body,
    required this.contentType,
    this.statusCode = 200,
  });

  final String body;
  final String contentType;
  final int statusCode;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
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
