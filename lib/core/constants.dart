import 'package:flutter/material.dart';

abstract final class AppConstants {
  // Time-bounded work uses one short auxiliary tier plus three network tiers.
  // Callers select the smallest tier that can finish the whole operation,
  // including redirects.
  static const shortOperationTimeout = Duration(seconds: 3);
  static const networkConnectionTimeout = Duration(seconds: 10);
  static const interactiveRequestTimeout = Duration(seconds: 15);
  static const contentRequestTimeout = Duration(seconds: 30);
  static const videoSourceLoadTimeout = networkConnectionTimeout;
  static const backgroundRefreshBudget = interactiveRequestTimeout;
  static const feedRefreshTimeout = contentRequestTimeout;
  static const opmlImportFeedTimeout = contentRequestTimeout;

  static const allowedSpeeds = <int>[100, 125, 150, 175, 200];
  static const defaultSpeed = 100;
  static const rewind = Duration(seconds: 15);
  static const forward = Duration(seconds: 30);
  static const progressCheckpoint = Duration(seconds: 15);
  static const playbackPositionThreshold = Duration(seconds: 10);
  static const playbackCompletionWindow = Duration(minutes: 1);
  static const sleepFadeSteps = 4;
  static const sleepFadeStepInterval = Duration(seconds: 1);
  static const sleepFade = Duration(seconds: sleepFadeSteps);
  static const sleepStatusUpdate = Duration(seconds: 30);
  static const downloadProgressWriteInterval = Duration(seconds: 2);
  static const databaseLockTimeout = Duration(seconds: 5);

  static const feedLimitBytes = 32 * 1024 * 1024;
  static const discoveryLimitBytes = 2 * 1024 * 1024;
  static const articleLimitBytes = 5 * 1024 * 1024;
  static const imageLimitBytes = 10 * 1024 * 1024;
  static const transcriptLimitBytes = 20 * 1024 * 1024;
  static const cyan = Color(0xFF36E4F1);
  static const magenta = Color(0xFFFF3D9A);
  static const acid = Color(0xFFD2FA72);
  static const background = Color(0xFF05070B);
  static const surface = Color(0xFF0E131A);
  static const elevated = Color(0xFF161D26);
  static const primaryText = Color(0xFFF4F7F9);
  static const secondaryText = Color(0xFFA1A9B5);
  static const danger = Color(0xFFFF6574);
  static const hairline = Color(0xFF27323D);
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
