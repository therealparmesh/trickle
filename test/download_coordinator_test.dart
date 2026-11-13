import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/core/errors.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/playback_source_resolver.dart';
import 'package:trickle/data/repositories/settings_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/features/downloads/download_coordinator.dart';
import 'package:trickle/services/sync_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'startup recovery respects failed, finished and removed downloads',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const connectivityEvents = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
      messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final network = SafeNetworkClient.forTesting(
        Dio(),
        addressValidator: (_) async {},
      );
      final downloader = _FakeDownloader();
      final now = DateTime.utc(2026, 9, 20);
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'feed',
              title: 'Feed',
              feedUrl: 'https://example.test/feed',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final tasks = [
        for (final id in ['refused', 'restarted', 'finished', 'removed'])
          DownloadTask(
            taskId: id,
            url: 'https://example.test/$id.mp3',
            group: 'media',
            metaData: id,
          ),
      ];
      for (final task in tasks) {
        await database
            .into(database.episodes)
            .insert(
              EpisodesCompanion.insert(
                id: task.metaData,
                feedId: 'feed',
                title: task.metaData,
                enclosureUrl: task.url,
                discoveredAt: now,
              ),
            );
        await database
            .into(database.mediaDownloads)
            .insert(
              MediaDownloadsCompanion.insert(
                episodeId: task.metaData,
                taskId: task.taskId,
                status: Value(DownloadState.running.index),
                bytesDownloaded: const Value(512),
                totalBytes: const Value(1024),
                updatedAt: now,
              ),
            );
        downloader.records.saved.add(
          TaskRecord(task, TaskStatus.running, 0.5, 1024),
        );
      }
      final recovering = Completer<void>();
      final finishRecovery = Completer<void>();
      downloader.recover = () async {
        recovering.complete();
        await finishRecovery.future;
        return ([tasks[1], tasks[3]], [tasks[0], tasks[2]]);
      };
      final starting = Completer<void>();
      final finishStartup = Completer<void>();
      downloader.beforeStart = () {
        starting.complete();
        return finishStartup.future;
      };
      final coordinator = DownloadCoordinator(
        database: database,
        sources: PlaybackSourceResolver(database, PrivateFeedStore(), network),
        settings: SettingsRepository(database),
        downloader: downloader,
      );
      addTearDown(() async {
        await coordinator.dispose();
        messenger.setMockMethodCallHandler(connectivity, null);
        messenger.setMockMethodCallHandler(connectivityEvents, null);
        await downloader.dispose();
        await database.close();
        network.close();
      });
      final initialize = runZoned(
        coordinator.initialize,
        zoneSpecification: ZoneSpecification(
          createTimer: (_, parent, zone, duration, callback) =>
              parent.createTimer(
                zone,
                duration == interruptedDownloadRecoveryDelay
                    ? Duration.zero
                    : duration,
                callback,
              ),
        ),
      );
      await starting.future;
      final cleanup = coordinator.cleanupPlayed();
      finishStartup.complete();
      await Future.wait([
        initialize,
        cleanup,
      ]).timeout(const Duration(seconds: 5));
      expect(downloader.implicitRecovery, isFalse);
      try {
        await recovering.future.timeout(const Duration(seconds: 3));
        // A newer terminal update must win over the failed recovery snapshot.
        await (database.update(
          database.mediaDownloads,
        )..where((row) => row.taskId.equals('finished'))).write(
          MediaDownloadsCompanion(status: Value(DownloadState.complete.index)),
        );
        await coordinator.delete('removed');
      } finally {
        finishRecovery.complete();
      }
      await coordinator.dispose();
      final downloads = {
        for (final row in await database.select(database.mediaDownloads).get())
          row.taskId: row,
      };
      expect(downloads.map((id, row) => MapEntry(id, row.status)), {
        'refused': DownloadState.failed.index,
        'restarted': DownloadState.running.index,
        'finished': DownloadState.complete.index,
      });
      expect(downloads['refused']?.bytesDownloaded, 0);
      expect(downloads['refused']?.totalBytes, isNull);
      expect(downloads['restarted']?.bytesDownloaded, 512);
      expect(downloader.cancellations, ['removed', 'removed']);
    },
  );

  test('download actions follow confirmed task status', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const connectivity = MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const connectivityEvents = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    const diskSpace = MethodChannel('disk_space_plus');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final directory = await Directory.systemTemp.createTemp('trickle-pause-');
    messenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final network = SafeNetworkClient.forTesting(
      Dio(),
      addressValidator: (_) async =>
          throw StateError('Unexpected network request'),
    );
    final downloader = _FakeDownloader();
    final coordinator = DownloadCoordinator(
      database: database,
      sources: PlaybackSourceResolver(database, PrivateFeedStore(), network),
      settings: SettingsRepository(database),
      downloader: downloader,
    );
    addTearDown(() async {
      await coordinator.dispose();
      await downloader.dispose();
      await database.close();
      network.close();
      messenger.setMockMethodCallHandler(connectivity, null);
      messenger.setMockMethodCallHandler(connectivityEvents, null);
      messenger.setMockMethodCallHandler(diskSpace, null);
      messenger.setMockMethodCallHandler(pathProvider, null);
      await directory.delete(recursive: true);
    });
    await coordinator.initialize();
    final now = DateTime.utc(2026, 9, 20);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.test/feed',
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
            title: 'Episode',
            enclosureUrl: 'https://example.test/audio.mp3',
            discoveredAt: now,
          ),
        );

    for (final delete in [false, true]) {
      await database
          .into(database.mediaDownloads)
          .insertOnConflictUpdate(
            MediaDownloadsCompanion.insert(
              episodeId: 'episode',
              taskId: 'old',
              status: Value(DownloadState.running.index),
              updatedAt: now,
            ),
          );
      final started = Completer<void>();
      final resume = Completer<void>();
      downloader.beforeMutation = (_) async {
        started.complete();
        await resume.future;
      };
      final pending = delete
          ? coordinator.delete('episode')
          : coordinator.pause('episode');
      await started.future;
      await database
          .update(database.mediaDownloads)
          .write(const MediaDownloadsCompanion(taskId: Value('new')));
      resume.complete();
      await pending;
      final current = await database
          .select(database.mediaDownloads)
          .getSingle();
      expect(current.taskId, 'new');
      expect(current.status, DownloadState.running.index);

      downloader.beforeMutation = null;
      if (delete) {
        await coordinator.delete('episode');
        expect(await database.select(database.mediaDownloads).get(), isEmpty);
      } else {
        final task = await downloader.taskForId('new') as DownloadTask;
        await coordinator.pause('episode');
        expect(
          (await database.select(database.mediaDownloads).getSingle()).status,
          DownloadState.running.index,
        );
        // Android has accepted the pause request but has not yet saved
        // resume data. A premature Resume must leave the original task alone.
        await coordinator.resume('episode');
        expect(downloader.resumeRequests, isEmpty);
        final paused = database
            .select(database.mediaDownloads)
            .watchSingle()
            .firstWhere((row) => row.status == DownloadState.paused.index);
        downloader.events.add(TaskStatusUpdate(task, TaskStatus.paused));
        expect((await paused).status, DownloadState.paused.index);

        final resuming = Completer<void>();
        final finishResume = Completer<void>();
        downloader.beforeMutation = (_) async {
          resuming.complete();
          await finishResume.future;
        };
        final resume = coordinator.resume('episode');
        await resuming.future;
        // The task can finish before its native Resume call returns.
        final file = File('${directory.path}/media/finished.mp3');
        await file.parent.create();
        await file.writeAsBytes([0x49, 0x44, 0x33]);
        final completed = database
            .select(database.mediaDownloads)
            .watchSingle()
            .firstWhere((row) => row.status == DownloadState.complete.index);
        final finishedTask = DownloadTask(
          taskId: task.taskId,
          url: task.url,
          metaData: task.metaData,
          filename: 'finished.mp3',
          directory: file.parent.path,
          baseDirectory: BaseDirectory.root,
          group: 'media',
        );
        downloader.events.add(
          TaskStatusUpdate(finishedTask, TaskStatus.complete),
        );
        try {
          await completed.timeout(const Duration(seconds: 3));
        } finally {
          finishResume.complete();
          await resume;
        }
        downloader.events.add(TaskProgressUpdate(finishedTask, 0.5, 1024));
        final processed = Completer<void>();
        downloader.records.beforeDelete = (id) async {
          if (id == finishedTask.taskId && !processed.isCompleted) {
            processed.complete();
          }
        };
        // Retire the first completion record before using the late failure as
        // a barrier for the progress event in the task-update stream.
        downloader.records.events.add(
          TaskRecord(finishedTask, TaskStatus.complete, 1, 3),
        );
        await processed.future.timeout(const Duration(seconds: 3));
        final lateFailure = Completer<void>();
        downloader.records.beforeDelete = (id) async {
          if (id == finishedTask.taskId && !lateFailure.isCompleted) {
            lateFailure.complete();
          }
        };
        downloader.records.events.add(
          TaskRecord(finishedTask, TaskStatus.failed, 0, -1),
        );
        downloader.events.add(
          TaskStatusUpdate(finishedTask, TaskStatus.failed),
        );
        await lateFailure.future.timeout(const Duration(seconds: 3));
        downloader.records.beforeDelete = null;
        final row = await database.select(database.mediaDownloads).getSingle();
        expect(row.status, DownloadState.complete.index);
        expect(row.bytesDownloaded, 3);
        expect(row.totalBytes, 3);
        expect(await file.exists(), isTrue);
      }
    }

    await database
        .into(database.mediaDownloads)
        .insert(
          MediaDownloadsCompanion.insert(
            episodeId: 'episode',
            taskId: 'old',
            status: Value(DownloadState.running.index),
            updatedAt: now,
          ),
        );
    final checkingDisk = Completer<void>();
    final resumeDiskCheck = Completer<void>();
    messenger.setMockMethodCallHandler(diskSpace, (call) async {
      if (call.method == 'getFreeDiskSpace') {
        checkingDisk.complete();
        await resumeDiskCheck.future;
        return 0.0;
      }
      return 100000.0;
    });
    downloader.events.add(
      TaskProgressUpdate(
        DownloadTask(
          taskId: 'old',
          url: 'https://example.test/audio.mp3',
          metaData: 'episode',
        ),
        0.5,
        1024,
      ),
    );
    await checkingDisk.future;
    downloader.cancellations.clear();
    await database
        .update(database.mediaDownloads)
        .write(const MediaDownloadsCompanion(taskId: Value('new')));
    final settled = database
        .select(database.mediaDownloads)
        .watchSingle()
        .firstWhere(
          (row) =>
              row.taskId == 'new' && row.status == DownloadState.paused.index,
        );
    downloader.events.add(
      TaskStatusUpdate(
        DownloadTask(
          taskId: 'new',
          url: 'https://example.test/audio.mp3',
          metaData: 'episode',
        ),
        TaskStatus.paused,
      ),
    );
    resumeDiskCheck.complete();
    final current = await settled;
    expect(current.bytesDownloaded, 0);
    expect(current.totalBytes, isNull);
    expect(downloader.cancellations, isEmpty);

    final resuming = Completer<void>();
    final finishResume = Completer<void>();
    downloader.cancellations.clear();
    downloader.beforeMutation = (_) async {
      resuming.complete();
      await finishResume.future;
    };
    final resume = coordinator.resume('episode');
    await resuming.future;
    try {
      downloader.beforeMutation = null;
      await coordinator.delete('episode');
    } finally {
      finishResume.complete();
      await resume;
    }
    expect(await database.select(database.mediaDownloads).get(), isEmpty);
    // Delete may cancel before the native Resume has finished enqueueing.
    expect(downloader.cancellations, ['new', 'new']);
  });

  test('automatic downloads retry temporary storage failures', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var freeMiB = 0.0;
    final channels = <MethodChannel, Future<Object?> Function(MethodCall)>{
      const MethodChannel('dev.fluttercommunity.plus/connectivity'):
          (_) async => ['wifi'],
      const MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      ): (_) async =>
          null,
      const MethodChannel('disk_space_plus'): (_) async => freeMiB,
    };
    for (final entry in channels.entries) {
      messenger.setMockMethodCallHandler(entry.key, entry.value);
    }
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _MediaAdapter(),
      addressValidator: (_) async {},
    );
    final downloader = _FakeDownloader();
    final coordinator = DownloadCoordinator(
      database: database,
      sources: PlaybackSourceResolver(database, PrivateFeedStore(), network),
      settings: SettingsRepository(database),
      downloader: downloader,
    );
    addTearDown(() async {
      await coordinator.dispose();
      await downloader.dispose();
      await database.close();
      network.close();
      for (final channel in channels.keys) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    final now = DateTime.utc(2026, 9, 20);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.test/feed',
            autoDownload: const Value(true),
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final (id, extension) in [('audio', 'mp3'), ('stream', 'm3u8')]) {
      await database
          .into(database.episodes)
          .insert(
            EpisodesCompanion.insert(
              id: id,
              feedId: 'feed',
              title: id,
              enclosureUrl: 'https://example.test/$id.$extension',
              discoveredAt: now,
            ),
          );
    }
    Future<void> refresh() => applyPodcastAutomation(
      database: database,
      downloadEpisode: (id) => coordinator.startDownload(id, automatic: true),
    );

    await refresh();
    expect(downloader.enqueued, isEmpty);
    expect((await database.episodeById('audio'))?.automationApplied, isFalse);
    expect((await database.episodeById('stream'))?.automationApplied, isTrue);

    freeMiB = 100000;
    await refresh();
    expect(downloader.enqueued.single.metaData, 'audio');
    expect((await database.episodeById('audio'))?.automationApplied, isTrue);
  });

  test('foreground and background workers only enqueue one download', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channels = <MethodChannel, Object?>{
      MethodChannel('dev.fluttercommunity.plus/connectivity'): ['wifi'],
      MethodChannel('dev.fluttercommunity.plus/connectivity_status'): null,
      MethodChannel('disk_space_plus'): 100000.0,
    };
    for (final entry in channels.entries) {
      messenger.setMockMethodCallHandler(entry.key, (_) async => entry.value);
    }
    final directory = await Directory.systemTemp.createTemp(
      'trickle-download-',
    );
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => directory.path,
    );
    final file = File('${directory.path}/library.sqlite');
    AppDatabase openDatabase() => AppDatabase.forTesting(NativeDatabase(file));
    final database = openDatabase();
    final backgroundDatabase = openDatabase();
    final bothResolving = Completer<void>();
    final finishResolving = Completer<void>();
    var requests = 0;
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = _MediaAdapter(),
      addressValidator: (_) async {
        if (++requests == 2) bothResolving.complete();
        await finishResolving.future;
      },
    );
    final foreground = _FakeDownloader();
    final background = _FakeDownloader();
    DownloadCoordinator coordinatorFor(
      AppDatabase database,
      _FakeDownloader downloader,
    ) => DownloadCoordinator(
      database: database,
      sources: PlaybackSourceResolver(database, PrivateFeedStore(), network),
      settings: SettingsRepository(database),
      downloader: downloader,
    );
    final manual = coordinatorFor(database, foreground);
    final automatic = coordinatorFor(backgroundDatabase, background);
    addTearDown(() async {
      await manual.dispose();
      await automatic.dispose();
      await foreground.dispose();
      await background.dispose();
      network.close();
      await backgroundDatabase.close();
      await database.close();
      await directory.delete(recursive: true);
      for (final channel in channels.keys) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      messenger.setMockMethodCallHandler(pathProvider, null);
    });
    final now = DateTime.utc(2026, 9, 20);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'feed',
            title: 'Feed',
            feedUrl: 'https://example.test/feed',
            autoDownload: const Value(true),
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
            title: 'Episode',
            enclosureUrl: 'https://example.test/audio.mp3',
            discoveredAt: now,
          ),
        );
    await Future.wait([manual.initialize(), automatic.initialize()]);
    await expectLater(
      automatic.startDownload(
        'episode',
        automatic: true,
        remainingNetworkTime: () => Duration.zero,
      ),
      throwsA(isA<NetworkException>()),
    );
    expect(requests, 0);
    expect(await database.select(database.mediaDownloads).get(), isEmpty);

    final startManual = manual.startDownload('episode');
    final startAutomatic = automatic.startDownload('episode', automatic: true);
    await bothResolving.future;
    finishResolving.complete();
    await Future.wait([startManual, startAutomatic]);

    final task = [...foreground.enqueued, ...background.enqueued].single;
    expect(
      (await database.select(database.mediaDownloads).getSingle()).taskId,
      task.taskId,
    );
    await manual.startDownload('episode');
    expect(requests, 2);

    // Playback can discover an invalid local file after startup. Retrying
    // must retain the task identity until it claims the replacement.
    final unusable = File('${directory.path}/media/invalid.mp3');
    await unusable.create(recursive: true);
    await database
        .update(database.mediaDownloads)
        .write(
          MediaDownloadsCompanion(
            status: Value(DownloadState.complete.index),
            filePath: const Value('media/invalid.mp3'),
          ),
        );
    final resolver = PlaybackSourceResolver(
      database,
      PrivateFeedStore(),
      network,
    );
    expect(
      (await resolver.resolve(
        (await database.episodeById('episode'))!,
      )).isLocal,
      isFalse,
    );
    final settings = SettingsRepository(database);
    await settings.setAutoDelete(AutoDeletePolicy.immediately);
    await database
        .into(database.playbackProgresses)
        .insert(
          PlaybackProgressesCompanion.insert(
            episodeId: 'episode',
            completed: const Value(true),
            completedAt: Value(now),
            updatedAt: now,
          ),
        );
    await manual.resume('episode');
    final retried = await database.select(database.mediaDownloads).getSingle();
    expect(retried.taskId, isNot(task.taskId));
    expect(retried.status, DownloadState.queued.index);
    expect(retried.filePath, isNull);
    expect(await unusable.exists(), isFalse);

    final retryTask = foreground.enqueued.last as DownloadTask;
    final downloaded = File('${directory.path}/media/${retryTask.filename}');
    await downloaded.writeAsBytes([0x49, 0x44, 0x33]);
    final complete = database
        .select(database.mediaDownloads)
        .watchSingle()
        .firstWhere((row) => row.status == DownloadState.complete.index);
    foreground.events.add(TaskStatusUpdate(retryTask, TaskStatus.complete));
    expect((await complete.timeout(const Duration(seconds: 3))).keep, isTrue);
    await manual.cleanupPlayed();
    expect(await downloaded.exists(), isTrue);
    await manual.setKeep('episode', false);
    expect(await database.select(database.mediaDownloads).get(), isEmpty);
    expect(await downloaded.exists(), isFalse);
  });

  test(
    'played-download cleanup rechecks retention and handles late arrivals',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const connectivityEvents = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
      messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final network = SafeNetworkClient.forTesting(
        Dio(),
        addressValidator: (_) async {},
      );
      final downloader = _FakeDownloader();
      final settings = SettingsRepository(database);
      final coordinator = DownloadCoordinator(
        database: database,
        sources: PlaybackSourceResolver(database, PrivateFeedStore(), network),
        settings: settings,
        downloader: downloader,
      );
      addTearDown(() async {
        await coordinator.dispose();
        await downloader.dispose();
        network.close();
        await database.close();
        messenger.setMockMethodCallHandler(connectivity, null);
        messenger.setMockMethodCallHandler(connectivityEvents, null);
      });
      await coordinator.initialize();
      final now = DateTime.now().toUtc().subtract(const Duration(days: 2));
      await database
          .into(database.feeds)
          .insert(
            FeedsCompanion.insert(
              id: 'feed',
              title: 'Feed',
              feedUrl: 'https://example.test/feed',
              createdAt: now,
              updatedAt: now,
            ),
          );
      Future<void> addCompletedDownload(String id, DateTime completedAt) async {
        await database
            .into(database.episodes)
            .insert(
              EpisodesCompanion.insert(
                id: id,
                feedId: 'feed',
                title: id,
                enclosureUrl: 'https://example.test/$id.mp3',
                discoveredAt: now,
              ),
            );
        await database
            .into(database.playbackProgresses)
            .insert(
              PlaybackProgressesCompanion.insert(
                episodeId: id,
                completed: const Value(true),
                completedAt: Value(completedAt),
                updatedAt: completedAt,
              ),
            );
        await database
            .into(database.mediaDownloads)
            .insert(
              MediaDownloadsCompanion.insert(
                episodeId: id,
                taskId: id,
                status: Value(DownloadState.complete.index),
                updatedAt: now,
              ),
            );
      }

      const initial = ['first', 'second', 'third'];
      for (final id in initial) {
        await addCompletedDownload(id, now);
      }
      final cleaning = Completer<String>();
      final continueCleanup = Completer<void>();
      Future<void> waitForKeepChange(String taskId) async {
        if (!cleaning.isCompleted) cleaning.complete(taskId);
        await continueCleanup.future;
      }

      downloader.beforeMutation = waitForKeepChange;
      downloader.records.beforeDelete = waitForKeepChange;
      final cleanup = coordinator.cleanupPlayed();
      final first = await cleaning.future;
      final remaining = initial.where((id) => id != first).toList();
      final keep = remaining.first;
      try {
        await coordinator.setKeep(keep, true);
        await settings.setAutoDelete(AutoDeletePolicy.after1Week);
        // This download finishes after the first pass reads its candidates.
        await addCompletedDownload(
          'late',
          now.subtract(const Duration(days: 6)),
        );
      } finally {
        continueCleanup.complete();
      }
      await Future.wait([cleanup, coordinator.cleanupPlayed()]);

      final retained = await database.select(database.mediaDownloads).get();
      expect(
        {for (final row in retained) row.episodeId: row.keep},
        {keep: true, remaining.last: false},
      );
      expect(await coordinator.removePlayedDownloads(), 1);
      await settings.setAutoDelete(AutoDeletePolicy.immediately);
      await coordinator.setKeep(keep, false);
      expect(await database.select(database.mediaDownloads).get(), isEmpty);
    },
  );

  test('every durable downloader status maps to local state', () {
    expect(
      {
        for (final status in TaskStatus.values)
          status: downloadStateForTaskStatus(status),
      },
      {
        TaskStatus.enqueued: DownloadState.queued,
        TaskStatus.running: DownloadState.running,
        TaskStatus.complete: DownloadState.complete,
        TaskStatus.notFound: DownloadState.failed,
        TaskStatus.failed: DownloadState.failed,
        TaskStatus.canceled: DownloadState.canceled,
        TaskStatus.waitingToRetry: DownloadState.running,
        TaskStatus.paused: DownloadState.paused,
      },
    );
  });

  test('terminal failure clears only a stored local file path', () {
    expect(
      shouldClearStoredDownloadPath(
        filePath: '/tmp/stale.mp3',
        state: DownloadState.failed,
      ),
      isTrue,
    );
    expect(
      shouldClearStoredDownloadPath(
        filePath: '/tmp/stale.mp3',
        state: DownloadState.canceled,
      ),
      isTrue,
    );
    expect(
      shouldClearStoredDownloadPath(
        filePath: '/tmp/active.mp3',
        state: DownloadState.running,
      ),
      isFalse,
    );
    expect(
      shouldClearStoredDownloadPath(
        filePath: null,
        state: DownloadState.failed,
      ),
      isFalse,
    );
  });
}

class _FakeDownloader extends Fake implements FileDownloader {
  Future<void> Function()? beforeStart;
  Future<void> Function(String)? beforeMutation;
  Future<(List<Task>, List<Task>)> Function()? recover;
  bool? implicitRecovery;
  final events = StreamController<TaskUpdate>();
  final enqueued = <Task>[];
  final resumeRequests = <String>[];
  final cancellations = <String>[];

  Future<void> dispose() async {
    await events.close();
    await records.dispose();
  }

  @override
  Future<bool> enqueue(Task task) async {
    enqueued.add(task);
    return true;
  }

  final records = _FakeDownloadDatabase();

  @override
  Database get database => records;

  @override
  Stream<TaskUpdate> get updates => events.stream;

  @override
  Future<List<(String, String)>> configure({
    dynamic globalConfig,
    dynamic androidConfig,
    dynamic iOSConfig,
    dynamic desktopConfig,
  }) async => [];

  @override
  Future<void> start({
    bool doTrackTasks = true,
    bool markDownloadedComplete = true,
    bool doRescheduleKilledTasks = true,
    bool autoCleanDatabase = false,
  }) async {
    implicitRecovery = doRescheduleKilledTasks;
    await beforeStart?.call();
  }

  @override
  Future<(List<Task>, List<Task>)> rescheduleKilledTasks() async =>
      await recover?.call() ?? (<Task>[], <Task>[]);

  @override
  FileDownloader configureNotificationForGroup(
    String group, {
    TaskNotification? running,
    TaskNotification? complete,
    TaskNotification? error,
    TaskNotification? paused,
    TaskNotification? canceled,
    bool progressBar = false,
    bool tapOpensFile = false,
    String groupNotificationId = '',
  }) => this;

  @override
  Future<Task?> taskForId(String taskId) async => DownloadTask(
    taskId: taskId,
    url: 'https://example.test/audio.mp3',
    metaData: 'episode',
  );

  @override
  Future<bool> pause(DownloadTask task) async {
    await beforeMutation?.call(task.taskId);
    return true;
  }

  @override
  Future<bool> resume(DownloadTask task) async {
    resumeRequests.add(task.taskId);
    await beforeMutation?.call(task.taskId);
    return true;
  }

  @override
  Future<bool> cancelTaskWithId(String taskId) async {
    cancellations.add(taskId);
    await beforeMutation?.call(taskId);
    return true;
  }
}

class _FakeDownloadDatabase extends Fake implements Database {
  Future<void> Function(String)? beforeDelete;
  final events = StreamController<TaskRecord>();
  final saved = <TaskRecord>[];
  Future<void> dispose() => events.close();
  @override
  Stream<TaskRecord> get updates => events.stream;

  @override
  Future<List<TaskRecord>> allRecords({String? group}) async => List.of(saved);

  @override
  Future<void> deleteRecordWithId(String taskId) async =>
      beforeDelete?.call(taskId);
}

class _MediaAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString('', 206);

  @override
  void close({bool force = false}) {}
}
