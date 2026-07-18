import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final class NotificationService {
  NotificationService() : _plugin = FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _initialization;

  Future<void> initialize() async {
    final active = _initialization;
    if (active != null) return active;
    final future = _initialize();
    _initialization = future;
    try {
      await future;
    } on Object {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_trickle'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
  }

  Future<bool> requestPermission() async {
    await initialize();
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    return false;
  }

  Future<void> showNewItems({
    required int episodes,
    required int articles,
  }) async {
    await initialize();
    if (episodes + articles == 0) return;
    final parts = <String>[
      if (episodes > 0) '$episodes new episode${episodes == 1 ? '' : 's'}',
      if (articles > 0) '$articles new article${articles == 1 ? '' : 's'}',
    ];
    await _plugin.show(
      id: 1001,
      title: 'New in trickle',
      body: parts.join(' · '),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'feed_updates',
          'Feed updates',
          channelDescription: 'New episodes and articles found during refresh.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: 'home',
    );
  }
}
