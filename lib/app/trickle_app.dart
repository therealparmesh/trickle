import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../presentation/pages/podcasts_page.dart';
import '../services/incoming_share_service.dart';
import '../services/sync_coordinator.dart';
import 'app_providers.dart';
import 'router.dart';
import 'theme.dart';

final class TrickleApp extends ConsumerStatefulWidget {
  const TrickleApp({required this.sync, required this.onDispose, super.key});

  final SyncCoordinator sync;
  final Future<void> Function() onDispose;

  @override
  ConsumerState<TrickleApp> createState() => _TrickleAppState();
}

class _TrickleAppState extends ConsumerState<TrickleApp>
    with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _incomingShares = IncomingShareService();
  late final GoRouter _router = createRouter(navigatorKey: _navigatorKey);
  DateTime? _lastForegroundRefresh;
  String? _pendingShareInput;
  bool _shareDialogOpen = false;
  bool _checkingShare = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshIfNeeded());
      unawaited(_openPendingShare());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref
            .read(audioHandlerProvider)
            .recoverPlaybackIfNeeded()
            .catchError((Object _) {}),
      );
      unawaited(widget.sync.resumeMaintenance().catchError((Object _) {}));
      unawaited(_refreshIfNeeded(notify: true));
      unawaited(_openPendingShare());
    }
  }

  Future<void> _refreshIfNeeded({bool notify = false}) async {
    final now = DateTime.now();
    if (_lastForegroundRefresh != null &&
        now.difference(_lastForegroundRefresh!) < const Duration(minutes: 15)) {
      return;
    }
    _lastForegroundRefresh = now;
    try {
      await widget.sync.refresh(notify: notify);
    } on Object {
      // Individual feeds retain their refresh error for the UI.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingShares.dispose();
    _router.dispose();
    unawaited(widget.onDispose().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'trickle',
      debugShowCheckedModeBanner: false,
      theme: TrickleTheme.dark,
      routerConfig: _router,
      builder: (context, child) =>
          AdaptiveAppChrome(child: child ?? const SizedBox.shrink()),
    );
  }

  Future<void> _openPendingShare() async {
    if (_shareDialogOpen || _checkingShare || !mounted) return;
    _checkingShare = true;
    var shared = _pendingShareInput;
    if (shared == null) {
      try {
        shared = await _incomingShares.takePendingText();
      } on MissingPluginException {
        _checkingShare = false;
        return;
      } on PlatformException {
        _checkingShare = false;
        return;
      }
    }
    final input = feedInputFromSharedText(shared);
    final context = _navigatorKey.currentContext;
    if (input == null) {
      _checkingShare = false;
      return;
    }
    if (context == null || !mounted || !context.mounted) {
      _pendingShareInput = input;
      _checkingShare = false;
      return;
    }
    _pendingShareInput = null;
    _shareDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => AddFeedDialog(initialInput: input),
      );
    } finally {
      _shareDialogOpen = false;
      _checkingShare = false;
      unawaited(_openPendingShare());
    }
  }
}
