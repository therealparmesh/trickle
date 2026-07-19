import 'package:flutter/material.dart';

abstract final class AppConstants {
  static const allowedSpeeds = <int>[100, 125, 150, 175, 200];
  static const defaultSpeed = 100;
  static const rewind = Duration(seconds: 15);
  static const forward = Duration(seconds: 30);
  static const progressCheckpoint = Duration(seconds: 15);
  static const sleepFade = Duration(seconds: 4);
  static const feedRefreshTimeout = Duration(seconds: 30);
  static const opmlImportFeedTimeout = Duration(seconds: 30);

  static const feedLimitBytes = 32 * 1024 * 1024;
  static const discoveryLimitBytes = 2 * 1024 * 1024;
  static const articleLimitBytes = 5 * 1024 * 1024;
  static const imageLimitBytes = 10 * 1024 * 1024;
  static const transcriptLimitBytes = 20 * 1024 * 1024;
  static const cyan = Color(0xFF42E8F5);
  static const magenta = Color(0xFFFF4FA3);
  static const acid = Color(0xFFC6F36A);
  static const background = Color(0xFF080A0F);
  static const surface = Color(0xFF14171D);
  static const elevated = Color(0xFF1B1F27);
  static const primaryText = Color(0xFFF5F7FA);
  static const secondaryText = Color(0xFF9299A8);
  static const danger = Color(0xFFFF6574);
  static const hairline = Color(0xFF2A303A);
}

enum FeedKind { podcast, reader }

enum DownloadState { queued, running, paused, complete, failed, canceled }

enum AutoDeletePolicy { immediately, after1Day, after1Week }

enum RefreshInterval {
  hourly(Duration(hours: 1), '1 hour'),
  every2Hours(Duration(hours: 2), '2 hours'),
  every4Hours(Duration(hours: 4), '4 hours'),
  every8Hours(Duration(hours: 8), '8 hours'),
  every12Hours(Duration(hours: 12), '12 hours'),
  daily(Duration(days: 1), '1 day'),
  weekly(Duration(days: 7), '1 week');

  const RefreshInterval(this.duration, this.label);
  final Duration duration;
  final String label;
}
