import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/repositories/nostr_repository.dart';
import 'package:trickle/features/video/video_session.dart';
import 'package:trickle/presentation/widgets/article_attachments.dart';
import 'package:trickle/presentation/widgets/video_player_host.dart';

import 'support/playback_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('late or broken feed media leaves the newer video active', (
    tester,
  ) async {
    final release = Completer<void>();
    var resolving = false;
    final harness = createPlaybackHarness(
      adapter: MockMediaAdapter(),
      addressValidator: (url) async {
        if (url.path == '/attachment.mp3' && !release.isCompleted) {
          resolving = true;
          await release.future;
        }
        if (url.path == '/broken.mp4') throw StateError('Video unavailable');
      },
    );
    final database = harness.database;
    final (current, _, _) = await seedPlaybackQueue(harness);
    final article = await database
        .into(database.articles)
        .insertReturning(
          ArticlesCompanion.insert(
            id: 'post',
            feedId: 'feed',
            title: 'Audio post',
            discoveredAt: DateTime.utc(2026, 9, 21),
          ),
        );
    await database
        .into(database.articleAttachments)
        .insert(
          ArticleAttachmentsCompanion.insert(
            id: 'broken',
            articleId: article.id,
            position: 1,
            url: 'https://example.test/broken.mp4',
          ),
        );
    await database
        .into(database.articleAttachments)
        .insert(
          ArticleAttachmentsCompanion.insert(
            id: 'audio',
            articleId: article.id,
            position: 0,
            url: 'https://example.test/attachment.mp3',
          ),
        );
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            audioHandlerProvider.overrideWithValue(harness.handler),
            networkProvider.overrideWithValue(harness.network),
            nostrRepositoryProvider.overrideWithValue(
              NostrRepository(database: database, network: harness.network),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: VideoPlayerHost(
                child: ArticleAttachmentsView(article: article),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play audio'));
      await tester.pump();
      expect(resolving, isTrue);
      final video = harness.handler.beginWebVideoPlayback();
      release.complete();
      await tester.pumpAndSettle();
      expect(find.text('Play audio'), findsOneWidget);
      expect(harness.handler.isWebVideoPlaybackCurrent(video), isTrue);
      expect(harness.handler.mediaItem.value?.id, current.id);
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(ArticleAttachmentsView)),
      );
      final source = Uri.parse('https://example.test/playing.mp4');
      scope.read(videoSessionProvider.notifier)
        ..open(
          intentRevision: video,
          articleId: article.id,
          title: 'Playing',
          sourceUri: source,
          playbackUri: source,
        )
        ..minimize();
      await tester.pump();
      await tester.tap(find.text('Play video'));
      await tester.pumpAndSettle();
      expect(harness.handler.isWebVideoPlaybackCurrent(video), isTrue);
      expect(
        scope.read(videoSessionProvider)?.presentation,
        VideoPresentation.minimized,
      );
      final replacement = Completer<Uri?>();
      final switching = harness.handler.playVideoAfterResolving(
        () => replacement.future,
        (_, _) => throw StateError('Dismissed player must not reopen'),
      );
      await tester.tap(find.byTooltip('Close video'));
      await tester.pump();
      replacement.complete(Uri.parse('https://example.test/late.mp4'));
      await switching;
      await tester.pumpAndSettle();
      expect(scope.read(videoSessionProvider), isNull);
      expect(harness.handler.isWebVideoPlaybackCurrent(video), isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      final dispose = disposePlaybackHarness(harness);
      await tester.pump(const Duration(milliseconds: 1));
      await dispose;
    }
  });

  test('late previews cannot override newer playback controls', () async {
    final directory = await Directory.systemTemp.createTemp('trickle-preview-');
    addTearDown(() => directory.delete(recursive: true));
    final native = MockNativeAudio(directory.path);
    final cache = CacheManager(
      Config('test-preview', repo: NonStoringObjectProvider()),
    );
    addTearDown(cache.dispose);
    final harness = createPlaybackHarness(
      adapter: MockMediaAdapter(),
      artworkCache: cache,
    );
    addTearDown(() => disposePlaybackHarness(harness));
    final handler = harness.handler;
    final (_, selected, other) = await seedPlaybackQueue(harness);

    final first = Completer<String>();
    final pending = handler.playPreviewEpisode(() => first.future);
    await handler.playPreviewEpisode(() async => selected.id);
    first.complete(other.id);
    await pending;
    expect(handler.mediaItem.value?.id, selected.id);
    expect(native.loaded, ['/selected.mp3']);

    final resume = Completer<String>();
    final resumed = handler.playPreviewEpisode(() => resume.future);
    await handler.play();
    resume.complete(other.id);
    await resumed;
    expect(handler.mediaItem.value?.id, selected.id);

    final second = Completer<String>();
    final paused = handler.playPreviewEpisode(() => second.future);
    await handler.pause();
    second.complete(other.id);
    await paused;
    expect(handler.playbackState.value.playing, isFalse);

    final third = Completer<String>();
    final video = handler.playPreviewEpisode(() => third.future);
    final videoIntent = handler.beginWebVideoPlayback();
    third.complete(other.id);
    await video;
    expect(handler.isWebVideoPlaybackCurrent(videoIntent), isTrue);
    expect(handler.mediaItem.value?.id, selected.id);
    expect(native.loaded, ['/selected.mp3']);

    final before = handler.queue.value.map((item) => item.id).toList();
    await handler.playPreviewEpisode(() async => other.id, standalone: true);
    expect(handler.mediaItem.value?.id, other.id);
    expect(native.loaded, ['/selected.mp3', '/other.mp3']);
    expect(handler.queue.value.map((item) => item.id), before);
  });
}
