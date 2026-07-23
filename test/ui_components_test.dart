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
import 'package:trickle/features/player/trickle_audio_handler.dart';
import 'package:trickle/presentation/app_shell.dart';
import 'package:trickle/presentation/pages/episode_page.dart';
import 'package:trickle/presentation/pages/feed_detail_page.dart';
import 'package:trickle/presentation/pages/home_page.dart';
import 'package:trickle/presentation/pages/player_page.dart';
import 'package:trickle/presentation/subscription_actions.dart';
import 'package:trickle/presentation/pages/queue_page.dart';
import 'package:trickle/presentation/widgets/common.dart';
import 'package:trickle/presentation/widgets/content_tiles.dart';
import 'package:trickle/presentation/widgets/episode_playback_button.dart';

void main() {
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

  testWidgets('buffering playback keeps Pause available', (tester) async {
    final episode = Episode(
      id: 'episode',
      feedId: 'feed',
      title: 'Buffering episode',
      enclosureUrl: 'https://example.test/audio.mp3',
      discoveredAt: DateTime.utc(2026, 7, 22),
      explicit: false,
      played: false,
      starred: false,
      automationApplied: false,
    );
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaProvider.overrideWith(
            (_) => Stream.value(
              const MediaItem(id: 'episode', title: 'Buffering episode'),
            ),
          ),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(
              PlaybackState(
                processingState: AudioProcessingState.buffering,
                playing: true,
              ),
            ),
          ),
          episodeProgressProvider.overrideWith((_, _) => Stream.value(null)),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: Scaffold(body: EpisodePlaybackButton(episode: episode)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    final pause = tester.getSemantics(
      find.bySemanticsLabel('Pause Buffering episode'),
    );
    expect(pause.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaProvider.overrideWith(
            (_) => Stream.value(
              const MediaItem(id: 'episode', title: 'Buffering episode'),
            ),
          ),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(
              PlaybackState(processingState: AudioProcessingState.buffering),
            ),
          ),
          episodeProgressProvider.overrideWith((_, _) => Stream.value(null)),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: Scaffold(
            body: EpisodePlaybackButton(episode: episode, expanded: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.color, AppConstants.background);
    expect(find.text('Buffering audio'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('player error and progress remain clear at large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaProvider.overrideWith(
            (_) => Stream.value(
              const MediaItem(
                id: 'episode',
                title: 'A complete playback title at accessibility sizes',
                album: 'Signal Podcast',
                duration: Duration(minutes: 10),
              ),
            ),
          ),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(
              PlaybackState(processingState: AudioProcessingState.error),
            ),
          ),
          playbackPositionProvider.overrideWith(
            (_) => Stream.value(const Duration(minutes: 5)),
          ),
          playbackDurationProvider.overrideWith(
            (_) => Stream.value(const Duration(minutes: 10)),
          ),
          speedProvider.overrideWith((_) => Stream.value(100)),
          sleepTimerStatusProvider.overrideWith(
            (_) => Stream.value(const SleepTimerStatus.off()),
          ),
          episodeProvider.overrideWith((_, _) => Stream.value(null)),
          bookmarksProvider.overrideWith((_, _) => Stream.value(const [])),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(3.2)),
            child: PlayerPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(TrickleAudioHandler.playbackErrorMessage), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.semanticFormatterCallback?.call(0), '5:00 of 10:00');
    expect(tester.takeException(), isNull);
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

  testWidgets('wide artwork keeps its source ratio while decoding', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remoteImagesProvider.overrideWith((_) => Stream.value(true)),
          safeImageFileProvider.overrideWith(
            (_, _) async =>
                'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png',
          ),
        ],
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(devicePixelRatio: 3),
            child: Scaffold(
              body: Artwork(
                url: 'https://example.test/wide.jpg',
                size: 120,
                aspectRatio: 16 / 9,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    expect(provider.width, 360);
    expect(provider.height, 360);
    expect(provider.policy, ResizeImagePolicy.fit);
    expect(image.fit, BoxFit.cover);
  });

  testWidgets('home command flow stacks at accessibility text sizes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentEpisodesProvider.overrideWith((_) => Stream.value(const [])),
          podcastFeedsProvider.overrideWith((_) => Stream.value(const [])),
          readerUnreadArticlesProvider(
            5,
          ).overrideWith((_) => Stream.value(const [])),
          queueProvider.overrideWith((_) => Stream.value(const [])),
          unreadArticleCountProvider.overrideWith((_) => Stream.value(0)),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(393, 3000),
              textScaler: TextScaler.linear(3.2),
            ),
            child: const HomePage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Up Next'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Saved episodes'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    expect(find.text('Add YouTube feed'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Downloads')).dy,
      greaterThan(tester.getBottomLeft(find.text('Up Next')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Saved episodes')).dy,
      greaterThan(tester.getBottomLeft(find.text('Downloads')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Library')).dy,
      greaterThan(tester.getBottomLeft(find.text('Saved episodes')).dy),
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
    expect(initialArticles.height, lessThan(kTextTabBarHeight));

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
    final semantics = tester.ensureSemantics();
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
      expect(tapTarget, findsOneWidget);
      expect(
        find.ancestor(of: label, matching: find.byType(AppBar)),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('subscription-pill'))).dx,
        lessThan(80),
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
    semantics.dispose();
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
              child: AdaptiveDropdownField<int>(
                label: 'Remove played downloads',
                initialValue: 1,
                items: const [DropdownMenuItem(value: 1, child: Text('1 day'))],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.text('1 day')).dy,
      greaterThan(
        tester.getBottomLeft(find.text('Remove played downloads')).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dropdown selection stays controlled until persistence updates', (
    tester,
  ) async {
    var persistedValue = 1;
    int? requestedValue;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: TrickleTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return AdaptiveDropdownField<int>(
                label: 'Background refresh',
                initialValue: persistedValue,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1 hour')),
                  DropdownMenuItem(value: 2, child: Text('2 hours')),
                ],
                onChanged: (value) => requestedValue = value,
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 hours').last);
    await tester.pumpAndSettle();

    expect(requestedValue, 2);
    expect(
      tester
          .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
          .value,
      1,
    );

    rebuild(() => persistedValue = 2);
    await tester.pump();
    expect(
      tester
          .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
          .value,
      2,
    );
  });

  testWidgets('Up Next distinguishes loading and failure from an empty queue', (
    tester,
  ) async {
    final queue = StreamController<List<MediaItem>>();
    addTearDown(queue.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          queueProvider.overrideWith((_) => queue.stream),
          currentMediaProvider.overrideWith((_) => Stream.value(null)),
        ],
        child: MaterialApp(theme: TrickleTheme.dark, home: const QueuePage()),
      ),
    );

    expect(find.byType(LoadingView), findsOneWidget);
    expect(find.text('Nothing is Up Next'), findsNothing);

    queue.addError(StateError('unavailable'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Couldn’t load Up Next'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Nothing is Up Next'), findsNothing);
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
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(393, 852),
            textScaler: TextScaler.linear(3.2),
          ),
          child: Scaffold(
            body: Column(
              children: [
                GlassIconButton(
                  icon: Icons.search_rounded,
                  tooltip: 'Search',
                  onPressed: () => pressed = true,
                ),
                const HorizontalShortcutStrip(
                  children: [
                    LibraryShortcut(
                      icon: Icons.download_rounded,
                      label: 'Downloads',
                      onTap: _noop,
                    ),
                    LibraryShortcut(
                      icon: Icons.bookmark_outline_rounded,
                      label: 'Saved',
                      onTap: _noop,
                    ),
                  ],
                ),
                const LoadingView(),
              ],
            ),
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
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Search'))
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(find.bySemanticsLabel('Downloads'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Saved')).dy,
      greaterThan(tester.getBottomLeft(find.text('Downloads')).dy),
    );
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    final shortcut = tester.getSemantics(find.bySemanticsLabel('Downloads'));
    expect(shortcut.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(find.byType(GlassIconButton));
    expect(pressed, isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('mini player separates open and playback actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaProvider.overrideWith(
            (_) => Stream.value(
              const MediaItem(id: 'episode', title: 'Episode title'),
            ),
          ),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(
              PlaybackState(
                playing: true,
                processingState: AudioProcessingState.ready,
              ),
            ),
          ),
          playbackPositionProvider.overrideWith(
            (_) => Stream.value(const Duration(minutes: 2)),
          ),
          playbackDurationProvider.overrideWith(
            (_) => Stream.value(const Duration(minutes: 10)),
          ),
          episodeProvider.overrideWith((_, _) => Stream.value(null)),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(393, 852),
              textScaler: TextScaler.linear(3.2),
            ),
            child: Scaffold(body: MiniPlayer()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final open = find.bySemanticsLabel(
      RegExp(r'^Open Now Playing\. Episode title\.'),
    );
    final pause = find.bySemanticsLabel('Pause');
    expect(open, findsOneWidget);
    expect(pause, findsOneWidget);
    expect(
      tester
          .getSemantics(open)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(
      tester
          .getSemantics(pause)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'shared inline states remain usable at accessibility text sizes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var retried = false;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: TrickleTheme.dark,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(3.2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    const InlineLoadingView(label: 'Loading transcript'),
                    InlineErrorView(
                      'The publisher could not be reached.',
                      title: 'Couldn’t load transcript',
                      onRetry: () => retried = true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Loading transcript'), findsOneWidget);
      expect(find.text('Couldn’t load transcript'), findsOneWidget);
      expect(find.text('The publisher could not be reached.'), findsOneWidget);
      await tester.ensureVisible(find.text('Try again'));
      await tester.pump();
      await tester.tap(find.text('Try again'));
      expect(retried, isTrue);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

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

  testWidgets('video rows use landscape artwork and video-specific actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.utc(2026, 7, 21);
    final feed = Feed(
      id: 'videos',
      title: 'Signal Videos',
      feedUrl:
          'https://www.youtube.com/feeds/videos.xml?channel_id=UC_x5XG1OV2P6uZZ5FSM9Ttw',
      kind: FeedKind.reader.index,
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
    final article = Article(
      id: 'video',
      feedId: feed.id,
      title: 'A useful video',
      canonicalUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      discoveredAt: now,
      starred: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          feedProvider.overrideWith((_, _) => Stream.value(feed)),
          remoteImagesProvider.overrideWith((_) => Stream.value(false)),
        ],
        child: MaterialApp(
          theme: TrickleTheme.dark,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(3.2),
            ),
            child: Scaffold(body: ArticleTile(article)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(ArticleArtwork)), const Size(112, 63));
    expect(
      find.bySemanticsLabel(RegExp(r'Unwatched video A useful video')),
      findsOneWidget,
    );
    expect(find.byTooltip('Video actions'), findsOneWidget);
    await tester.tap(find.byTooltip('Video actions'));
    await tester.pumpAndSettle();
    expect(find.text('Mark watched'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
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

  testWidgets('busy feed settings remain dismissible', (tester) async {
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
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FeedSettingsSheet), findsNothing);

    secret.complete(null);
    await tester.pump();
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
