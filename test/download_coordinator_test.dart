import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/playback_source_resolver.dart';
import 'package:trickle/data/repositories/settings_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';
import 'package:trickle/features/downloads/download_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pending download actions cannot change a replacement task', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const connectivity = MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const connectivityEvents = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    const diskSpace = MethodChannel('disk_space_plus');
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
      downloader.beforeMutation = () async {
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
        await coordinator.pause('episode');
        expect(
          (await database.select(database.mediaDownloads).getSingle()).status,
          DownloadState.paused.index,
        );
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
  });

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

  test('stale durable state cannot downgrade a usable completed file', () {
    expect(
      shouldKeepUsableCompletedDownload(
        localState: DownloadState.complete,
        incomingStatus: TaskStatus.paused,
        fileUsable: true,
      ),
      isTrue,
    );
    expect(
      shouldKeepUsableCompletedDownload(
        localState: DownloadState.complete,
        incomingStatus: TaskStatus.running,
        fileUsable: false,
      ),
      isFalse,
    );
    expect(
      shouldKeepUsableCompletedDownload(
        localState: DownloadState.running,
        incomingStatus: TaskStatus.paused,
        fileUsable: true,
      ),
      isFalse,
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
  Future<void> Function()? beforeMutation;
  final events = StreamController<TaskUpdate>();

  Future<void> dispose() => events.close();

  @override
  final Database database = _FakeDownloadDatabase();

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
  }) async {}

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
    await beforeMutation?.call();
    return true;
  }

  @override
  Future<bool> cancelTaskWithId(String taskId) async {
    await beforeMutation?.call();
    return true;
  }
}

class _FakeDownloadDatabase extends Fake implements Database {
  @override
  Stream<TaskRecord> get updates => const Stream.empty();

  @override
  Future<List<TaskRecord>> allRecords({String? group}) async => [];

  @override
  Future<void> deleteRecordWithId(String taskId) async {}
}
