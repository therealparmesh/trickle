import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:trickle/app/router.dart';
import 'package:trickle/presentation/widgets/cyber_glitch.dart';

void main() {
  test('primary push destinations use the signal transition', () {
    final router = createRouter();
    addTearDown(router.dispose);
    final shell =
        router.configuration.routes.singleWhere((route) => route is ShellRoute)
            as ShellRoute;
    final routes = {
      for (final route in shell.routes.whereType<GoRoute>()) route.path: route,
    };

    for (final path in [
      '/podcasts',
      '/reader',
      '/library',
      '/search',
      '/podcast/:id',
      '/podcast-preview',
      '/feed/:id',
      '/episode/:id',
      '/queue',
      '/downloads',
      '/saved',
      '/settings',
    ]) {
      expect(routes[path]?.pageBuilder, isNotNull, reason: path);
    }
  });

  testWidgets('glitch reveal keeps one usable interaction target', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CyberGlitchReveal(
            child: FilledButton(
              onPressed: () => taps++,
              child: const Text('Open signal'),
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 70));
    expect(find.text('Open signal'), findsOneWidget);
    await tester.tap(find.text('Open signal'));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('route signal remains visible midway through its motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => CyberGlitchMotion.routeTransition(
            context,
            const AlwaysStoppedAnimation(0.4),
            const AlwaysStoppedAnimation(0),
            const Text('Incoming signal'),
          ),
        ),
      ),
    );

    final transforms = tester.widgetList<Transform>(find.byType(Transform));
    expect(
      transforms.any(
        (transform) => transform.transform.getTranslation().x.abs() >= 4,
      ),
      isTrue,
    );
    expect(find.byType(CustomPaint), findsWidgets);
    expect(
      CyberGlitchMotion.routeDuration.inMilliseconds,
      greaterThanOrEqualTo(250),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('glitch reveal honors reduced motion', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: CyberGlitchReveal(child: Text('Stable signal')),
        ),
      ),
    );

    expect(find.text('Stable signal'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is TweenAnimationBuilder),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
