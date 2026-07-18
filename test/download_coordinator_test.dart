import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/features/downloads/download_coordinator.dart';

void main() {
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
