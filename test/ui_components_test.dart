import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column, isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/app/theme.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/repositories/article_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/presentation/pages/episode_page.dart';
import 'package:trickle/presentation/pages/feed_detail_page.dart';
import 'package:trickle/presentation/widgets/common.dart';
import 'package:trickle/presentation/widgets/content_tiles.dart';

void main() {
  test('download lookup returns the keyed episode row', () async {
    final now = DateTime.utc(2026, 7, 17);
    final downloads = [
      MediaDownload(
        episodeId: 'first',
        taskId: 'task-1',
        status: 0,
        bytesDownloaded: 0,
        keep: false,
        updatedAt: now,
      ),
      MediaDownload(
        episodeId: 'second',
        taskId: 'task-2',
        status: 1,
        bytesDownloaded: 42,
        keep: false,
        updatedAt: now,
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        downloadsProvider.overrideWith((_) => Stream.value(downloads)),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(downloadsProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(downloadsProvider.future);

    expect(
      container.read(downloadForEpisodeProvider('second'))?.taskId,
      'task-2',
    );
    expect(container.read(downloadForEpisodeProvider('missing')), isNull);
  });

  test('subscription cleanup starts only after deletion commits', () async {
    final events = <String>[];

    await deleteSubscriptionThenCleanup(
      deleteSubscription: () async => events.add('commit'),
      cleanupOperations: [
        () async {
          events.add('playback cleanup');
          throw StateError('cleanup failed');
        },
        () async => events.add('download cleanup'),
      ],
    );

    expect(events, ['commit', 'playback cleanup', 'download cleanup']);
  });

  test('failed subscription deletion preserves external state', () async {
    var cleaned = false;

    await expectLater(
      deleteSubscriptionThenCleanup(
        deleteSubscription: () => Future<void>.error(StateError('rejected')),
        cleanupOperations: [() async => cleaned = true],
      ),
      throwsStateError,
    );

    expect(cleaned, isFalse);
  });

  testWidgets('whitespace artwork URL remains a local placeholder', (
    tester,
  ) async {
    var imageRequests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remoteImagesProvider.overrideWith((_) => Stream.value(true)),
          safeImageFileProvider.overrideWith((_, _) async {
            imageRequests++;
            return null;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: Artwork(url: '   ')),
        ),
      ),
    );
    await tester.pump();

    expect(imageRequests, 0);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact home controls reflow at large text on a narrow phone', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(3.2),
          ),
          child: const Scaffold(
            body: Column(
              children: [
                SectionHeader('Podcasts', action: 'See all', onAction: _noop),
                SizedBox(
                  width: 320,
                  child: LibraryShortcut(
                    icon: Icons.queue_music_rounded,
                    label: 'Up Next',
                    badge: 12,
                    onTap: _noop,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Up Next'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('See all')).dy,
      greaterThan(tester.getBottomLeft(find.text('Podcasts')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('content stays readable instead of stretching across a tablet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const contentKey = ValueKey('content');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppBackdrop(
            child: ColoredBox(key: contentKey, color: Colors.transparent),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(contentKey)).width, 840);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app bar chrome grows with large accessibility text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(3.2),
          ),
          child: AdaptiveAppChrome(
            child: Scaffold(appBar: AppBar(title: const Text('Settings'))),
          ),
        ),
      ),
    );

    final appBarContext = tester.element(find.byType(AppBar));
    final toolbarHeight = Theme.of(appBarContext).appBarTheme.toolbarHeight!;
    expect(toolbarHeight, greaterThan(kToolbarHeight));
    expect(
      tester.getSize(find.text('Settings')).height,
      lessThan(toolbarHeight),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('adaptive tabs keep stable labels at large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(3.2),
          ),
          child: DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: AppBar(
                bottom: const AdaptiveTabBar(
                  tabs: [
                    Tab(text: 'Articles'),
                    Tab(text: 'Feeds'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final initialArticles = tester.getSize(find.text('Articles'));
    final initialFeeds = tester.getSize(find.text('Feeds'));
    expect(initialArticles.height, initialFeeds.height);

    DefaultTabController.of(
      tester.element(find.byType(AdaptiveTabBar)),
    ).animateTo(1);
    await tester.pumpAndSettle();

    expect(tester.getSize(find.text('Articles')), initialArticles);
    expect(tester.getSize(find.text('Feeds')), initialFeeds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty states scroll instead of overflowing at large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 400),
            textScaler: TextScaler.linear(3.2),
          ),
          child: const Scaffold(
            body: EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Enter at least two characters',
              message:
                  'Local search stays on your device. Podcast discovery queries Apple.',
              action: 'Try again',
              onAction: _noop,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Enter at least two characters'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('subscribed button confirms podcast and feed removal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.utc(2026, 7, 17);
    for (final entry in const [
      (id: 'podcast', title: 'Signal Podcast', kind: FeedKind.podcast),
      (id: 'reader', title: 'Signal Feed', kind: FeedKind.reader),
    ]) {
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: entry.id,
              title: entry.title,
              feedUrl: 'https://example.test/${entry.id}.xml',
              kind: Value(entry.kind.index),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    for (final entry in const [
      (id: 'podcast', noun: 'podcast'),
      (id: 'reader', noun: 'feed'),
    ]) {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(entry.id),
          overrides: [
            databaseProvider.overrideWithValue(database),
            remoteImagesProvider.overrideWith((_) => Stream.value(false)),
          ],
          child: MaterialApp(
            theme: TrickleTheme.dark,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(393, 852),
                textScaler: TextScaler.linear(1.8),
              ),
              child: FeedDetailPage(feedId: entry.id),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final label = find.text('Subscribed');
      final tapTarget = find.ancestor(
        of: label,
        matching: find.byType(InkWell),
      );
      expect(label, findsOneWidget);
      expect(
        find.ancestor(of: label, matching: find.byType(AppBar)),
        findsOneWidget,
      );
      expect(tester.getSize(tapTarget).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.byKey(const ValueKey('subscription-pill'))).height,
        28,
      );
      expect(find.textContaining('· SUBSCRIBED'), findsNothing);

      await tester.tap(label);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Unsubscribe from this ${entry.noun}?'), findsOneWidget);
      expect(find.text('Unsubscribe'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(await database.feedById(entry.id), isNotNull);
    }

    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('large-subscription-control'),
        overrides: [
          databaseProvider.overrideWithValue(database),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(393, 852),
              textScaler: TextScaler.linear(3.2),
            ),
            child: const FeedDetailPage(feedId: 'podcast'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final largeLabel = find.text('Subscribed');
    expect(largeLabel, findsOneWidget);
    expect(
      find.ancestor(of: largeLabel, matching: find.byType(AppBar)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('speed selector shows only exact product speeds', (tester) async {
    int? selected;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: PlaybackSpeedSelector(
              selected: 100,
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      ),
    );

    for (final label in ['1x', '1.25x', '1.5x', '1.75x', '2x']) {
      expect(find.text(label), findsOneWidget);
    }
    final oneXSemantics = tester.getSemantics(find.text('1x'));
    expect(oneXSemantics.label, '1x playback speed');
    final target = tester.getSemantics(find.text('1.75x'));
    expect(target.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.tap(find.semantics.byLabel('1.75x playback speed'));
    await tester.pump();
    expect(selected, 175);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('speed selector keeps 48 point targets at large text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(3.2),
          ),
          child: Scaffold(
            body: SizedBox(
              width: 280,
              child: PlaybackSpeedSelector(selected: 100, onSelected: (_) {}),
            ),
          ),
        ),
      ),
    );

    final cells = find.byType(InkWell);
    for (var index = 0; index < cells.evaluate().length; index++) {
      expect(tester.getSize(cells.at(index)).height, greaterThanOrEqualTo(48));
    }
    expect(
      tester.getTopLeft(find.text('2x')).dy,
      greaterThan(tester.getTopLeft(find.text('1x')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dropdown labels separate from values at large text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(3.2),
          ),
          child: Scaffold(
            body: SizedBox(
              width: 280,
              child: AdaptiveDropdownFormField<int>(
                label: 'Remove played downloads',
                initialValue: 24,
                items: const [
                  DropdownMenuItem(value: 24, child: Text('24 hours')),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.text('24 hours')).dy,
      greaterThan(
        tester.getBottomLeft(find.text('Remove played downloads')).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit badge stays visible when a long title is truncated', (
    tester,
  ) async {
    const title =
        'A deliberately long episode title that cannot fit on one narrow line';
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 180,
              child: EpisodeTitle(title: title, explicit: true, maxLines: 1),
            ),
          ),
        ),
      ),
    );

    expect(find.text('E'), findsOneWidget);
    expect(
      tester.getTopRight(find.text(title)).dx,
      lessThan(tester.getTopLeft(find.text('E')).dx),
    );
    expect(find.bySemanticsLabel('$title, explicit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unbounded episode title wraps to show the complete title', (
    tester,
  ) async {
    const title =
        'A deliberately long episode title that should remain completely visible';
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 180,
              child: EpisodeTitle(title: title, explicit: true, maxLines: null),
            ),
          ),
        ),
      ),
    );

    final titleText = tester.widget<Text>(find.text(title));
    expect(titleText.maxLines, isNull);
    expect(titleText.overflow, TextOverflow.visible);
    expect(tester.getSize(find.text(title)).height, greaterThan(30));
    expect(find.text('E'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact controls expose useful semantics', (tester) async {
    var pressed = false;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: Scaffold(
          body: Column(
            children: [
              GlassIconButton(
                icon: Icons.search_rounded,
                tooltip: 'Search',
                onPressed: () => pressed = true,
              ),
              const LibraryShortcut(
                icon: Icons.download_rounded,
                label: 'Downloads',
                badge: 1,
                onTap: _noop,
              ),
              const LoadingView(),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(GlassIconButton)), const Size(48, 48));
    expect(find.bySemanticsLabel('Search'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Search')).label,
      'Search',
    );
    expect(find.bySemanticsLabel('Downloads, 1 item'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    final shortcut = tester.getSemantics(
      find.bySemanticsLabel('Downloads, 1 item'),
    );
    expect(shortcut.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(find.byType(GlassIconButton));
    expect(pressed, isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('new markers share the metadata baseline', (tester) async {
    final semantics = tester.ensureSemantics();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.utc(2026, 7, 17);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Signal',
            feedUrl: 'https://example.test/feed.xml',
            kind: Value(FeedKind.hybrid.index),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.episodes)
        .insert(
          EpisodesCompanion.insert(
            id: 'episode',
            feedId: 'feed',
            title: 'Episode title',
            enclosureUrl: 'https://example.test/audio.mp3',
            discoveredAt: now,
            durationMs: const Value(3600000),
            explicit: const Value(true),
          ),
        );
    await database
        .into(database.articles)
        .insert(
          ArticlesCompanion.insert(
            id: 'article',
            feedId: 'feed',
            title: 'Article title',
            author: const Value('Publisher'),
            discoveredAt: now,
          ),
        );
    final episode = (await database.episodeById('episode'))!;
    final article = (await database.articleById('article'))!;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
          currentMediaProvider.overrideWith((_) => Stream.value(null)),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(
              PlaybackState(processingState: AudioProcessingState.ready),
            ),
          ),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: Scaffold(
            body: Column(
              children: [EpisodeTile(episode), ArticleTile(article)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      tester.getCenter(_dotWithColor(AppConstants.magenta)).dy,
      closeTo(tester.getCenter(find.textContaining('1h')).dy, 1),
    );
    expect(
      tester.getCenter(_dotWithColor(AppConstants.cyan)).dy,
      closeTo(tester.getCenter(find.textContaining('Publisher')).dy, 1),
    );
    expect(find.text('Explicit'), findsNothing);
    expect(find.text('E'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'Explicit')), findsOneWidget);
    for (final label in [
      RegExp(r'Unplayed episode Episode title'),
      RegExp(r'Unread article Article title'),
    ]) {
      final node = tester.getSemantics(find.bySemanticsLabel(label));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    }
    expect(
      find.bySemanticsLabel('Play Episode title'),
      findsOneWidget,
      reason: 'opening details and starting playback must be separate actions',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    await tester.pump(const Duration(milliseconds: 1));
    semantics.dispose();
  });

  testWidgets('episode row opens details without starting playback', (
    tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.utc(2026, 7, 17);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'podcast',
            title: 'Signal Podcast',
            feedUrl: 'https://example.test/podcast.xml',
            kind: Value(FeedKind.podcast.index),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.episodes)
        .insert(
          EpisodesCompanion.insert(
            id: 'episode',
            feedId: 'podcast',
            title: 'Browse before playing',
            enclosureUrl: 'https://example.test/audio.mp3',
            discoveredAt: now,
          ),
        );
    final episode = (await database.episodeById('episode'))!;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: EpisodeTile(episode)),
        ),
        GoRoute(
          path: '/episode/:id',
          builder: (_, state) =>
              Scaffold(body: Text('Details ${state.pathParameters['id']}')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
          currentMediaProvider.overrideWith((_) => Stream.value(null)),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(
              PlaybackState(processingState: AudioProcessingState.ready),
            ),
          ),
        ],
        child: MaterialApp.router(
          theme: TrickleTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Browse before playing'));
    await tester.pumpAndSettle();

    expect(find.text('Details episode'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    router.dispose();
    await database.close();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('episode details render playback entry and readable show notes', (
    tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.utc(2026, 7, 17);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'podcast',
            title: 'Signal Podcast',
            feedUrl: 'https://example.test/podcast.xml',
            kind: Value(FeedKind.podcast.index),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.episodes)
        .insert(
          EpisodesCompanion.insert(
            id: 'episode',
            feedId: 'podcast',
            title: 'A complete episode title',
            description: const Value('<p>Readable show notes.</p>'),
            enclosureUrl: 'https://example.test/audio.mp3',
            discoveredAt: now,
            durationMs: const Value(3600000),
          ),
        );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
          currentMediaProvider.overrideWith((_) => Stream.value(null)),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(
              PlaybackState(processingState: AudioProcessingState.ready),
            ),
          ),
          episodeShowNotesProvider.overrideWith(
            (_, _) async => const ExtractedArticle(
              html: '<p>Readable show notes.</p>',
              text: 'Readable show notes.',
            ),
          ),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(390, 844),
              textScaler: TextScaler.linear(1.8),
            ),
            child: EpisodePage(episodeId: 'episode'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A complete episode title'), findsOneWidget);
    expect(find.text('Signal Podcast'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Show notes'), findsOneWidget);
    expect(find.text('Readable show notes.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('episode details handle a deleted episode', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: const EpisodePage(episodeId: 'missing'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Episode unavailable'), findsOneWidget);
    expect(
      find.text('This episode is no longer on this device.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await database.close();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('podcast tile exposes one actionable semantic node', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final now = DateTime.utc(2026, 7, 17);
    final feed = Feed(
      id: 'podcast',
      title: 'Signal',
      feedUrl: 'https://example.test/podcast.xml',
      author: 'Publisher',
      kind: FeedKind.podcast.index,
      isPrivate: false,
      autoDownload: false,
      autoDownloadLimit: 3,
      notifications: false,
      introSkipMs: 0,
      outroSkipMs: 0,
      autoQueue: false,
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: Scaffold(body: PodcastTile(feed)),
        ),
      ),
    );
    await tester.pump();

    final finder = find.semantics.byLabel('Podcast Signal. Publisher');
    expect(finder, findsOne);
    final node = finder.evaluate().single;
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('busy feed settings cannot be dismissed', (tester) async {
    final secret = Completer<PrivateFeedSecret?>();
    final feed = _privateFeed();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          privateFeedSecretProvider.overrideWith((_, _) => secret.future),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => FeedSettingsSheet(feed: feed),
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update private access'));
    await tester.pump();

    expect(find.text('Updating access…'), findsOneWidget);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FeedSettingsSheet), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(FeedSettingsSheet), findsOneWidget);
    await tester.drag(find.byType(FeedSettingsSheet), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(find.byType(FeedSettingsSheet), findsOneWidget);

    secret.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Update private access'), findsOneWidget);
    expect(find.text('Updating access…'), findsOneWidget);
    final privateUrlField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Private feed URL',
      ),
    );
    expect(privateUrlField.controller?.text, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Update private access'), findsOneWidget);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isTrue);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(FeedSettingsSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('private access read failures return the sheet to idle', (
    tester,
  ) async {
    final feed = _privateFeed();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          privateFeedSecretProvider.overrideWith(
            (_, _) => Future<PrivateFeedSecret?>.error(
              StateError('Secure storage unavailable'),
            ),
          ),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: Scaffold(body: FeedSettingsSheet(feed: feed)),
        ),
      ),
    );

    await tester.tap(find.text('Update private access'));
    await tester.pumpAndSettle();

    expect(find.text('Update private access'), findsOneWidget);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isTrue);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}

Feed _privateFeed() {
  final now = DateTime.utc(2026, 7, 17);
  return Feed(
    id: 'private-feed',
    title: 'Private signal',
    feedUrl: 'private://credential',
    kind: FeedKind.podcast.index,
    isPrivate: true,
    credentialRef: 'credential',
    autoDownload: false,
    autoDownloadLimit: 3,
    notifications: false,
    introSkipMs: 0,
    outroSkipMs: 0,
    autoQueue: false,
    createdAt: now,
    updatedAt: now,
  );
}

Finder _dotWithColor(Color color) {
  return find.byWidgetPredicate((widget) {
    if (widget is! DecoratedBox) return false;
    final decoration = widget.decoration;
    return decoration is BoxDecoration &&
        decoration.shape == BoxShape.circle &&
        decoration.color == color;
  });
}
