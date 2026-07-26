import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/presentation/widgets/cyber_glitch.dart';

void main() {
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
