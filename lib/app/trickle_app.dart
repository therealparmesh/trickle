import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/sync_coordinator.dart';
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
  late final GoRouter _router = createRouter();
  DateTime? _lastForegroundRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshIfNeeded());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.sync.resumeMaintenance().catchError((Object _) {}));
      _refreshIfNeeded(notify: true);
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
}
