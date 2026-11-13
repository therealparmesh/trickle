import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../presentation/widgets/add_feed_dialog.dart';
import '../services/incoming_share_service.dart';
import '../services/sync_coordinator.dart';
import 'app_providers.dart';
import 'router.dart';
import 'startup.dart';
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
  late final IncomingShareService _incomingShares;
  late final GoRouter _router = createRouter(navigatorKey: _navigatorKey);
  DateTime? _lastForegroundRefresh;
  bool _checkShareAgain = false;
  bool _checkingShare = false;

  @override
  void initState() {
    super.initState();
    _incomingShares = IncomingShareService(
      onAvailable: () => unawaited(_openPendingShare()),
    );
    WidgetsBinding.instance.addObserver(this);
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
      builder: (context, child) => AdaptiveAppChrome(
        child: StartupGate(
          onReady: () {
            unawaited(_refreshIfNeeded());
            unawaited(_openPendingShare());
          },
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }

  Future<void> _openPendingShare() async {
    if (!mounted || _navigatorKey.currentContext == null) return;
    if (_checkingShare) {
      _checkShareAgain = true;
      return;
    }
    _checkingShare = true;
    try {
      do {
        _checkShareAgain = false;
        final input = feedInputFromSharedText(
          await _incomingShares.takePendingText(),
        );
        final context = _navigatorKey.currentContext;
        if (input != null && mounted && context != null && context.mounted) {
          await showDialog<void>(
            context: context,
            builder: (_) => AddFeedDialog(initialInput: input),
          );
          _checkShareAgain = true;
        }
      } while (mounted && _checkShareAgain);
    } on MissingPluginException {
      // No native share handoff is installed on this platform.
    } on PlatformException {
      // The next resume or share notification can retry the handoff.
    } finally {
      _checkingShare = false;
    }
  }
}
