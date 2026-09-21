import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';

/// Mount the first route only after its local data and player inset are known.
final class StartupGate extends ConsumerStatefulWidget {
  const StartupGate({required this.child, this.onReady, super.key});

  final Widget child;
  final VoidCallback? onReady;

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    if (!_opened) {
      final initialData = <AsyncValue<Object?>>[
        ref.watch(recentEpisodesProvider),
        ref.watch(podcastFeedsProvider),
        ref.watch(recentArticlesProvider),
        ref.watch(unreadArticleCountProvider),
        ref.watch(currentMediaProvider),
      ];
      _opened = initialData.every((value) => value.hasValue || value.hasError);
      if (_opened) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onReady?.call();
        });
      }
    }
    return _opened ? widget.child : const LaunchView();
  }
}

final class LaunchView extends StatelessWidget {
  const LaunchView({this.onRetry, super.key});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: onRetry == null
          ? Center(
              child: Image.asset(
                'assets/brand/trickle-launch.png',
                width: 96,
                height: 96,
                semanticLabel: 'trickle',
              ),
            )
          : SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Initialization failed. Your local data was not changed.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: onRetry,
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
