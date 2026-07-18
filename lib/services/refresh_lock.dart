import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Serializes feed refreshes across the foreground and Workmanager isolates.
final class RefreshLock {
  const RefreshLock._();

  static Future<T> run<T>(Future<T> Function() operation) async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/trickle-refresh.lock');
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return await operation();
    } finally {
      try {
        await handle.unlock();
      } finally {
        await handle.close();
      }
    }
  }
}
