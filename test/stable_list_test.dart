import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/presentation/widgets/stable_sliver_list.dart';

void main() {
  testWidgets('refresh batches preserve the visible row and its state', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var items = List.generate(100, (index) => index);
    var headerHeight = 120.0;
    Future<void> render() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: headerHeight)),
                StableSliverList<int>(
                  items: items,
                  itemId: (item) => '$item',
                  itemBuilder: (_, item) => _Row(item: item),
                ),
              ],
            ),
          ),
        ),
      );
    }

    await render();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final anchor = find.byWidget(
      tester
          .widgetList<_Row>(find.byType(_Row))
          .firstWhere((row) => tester.getTopLeft(find.byWidget(row)).dy >= 0),
    );
    final id = tester.widget<_Row>(anchor).item;
    final row = find.byWidgetPredicate(
      (widget) => widget is _Row && widget.item == id,
    );
    final state = tester.state(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Item $id: 1'), findsOneWidget);
    final before = tester.getTopLeft(row);
    headerHeight = 200;
    await render();
    expect(tester.getTopLeft(row), before);
    for (var batch = 0; batch < 4; batch++) {
      items = [-batch * 2 - 1, -batch * 2 - 2, ...items];
      await render();
      expect(tester.getTopLeft(row), before);
      expect(tester.state(row), same(state));
      expect(find.text('Item $id: 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    items = [for (var i = 100; i < 200; i++) i, ...items];
    await render();
    expect(tester.getTopLeft(row), before);
    expect(tester.state(row), same(state));

    items = items.where((item) => item >= 0 && item < 100).toList();
    await render();
    expect(tester.getTopLeft(row), before);
    final leading = tester
        .widgetList<_Row>(find.byType(_Row))
        .firstWhere(
          (item) =>
              tester.getTopLeft(find.byWidget(item)).dy <= 0 &&
              tester.getBottomLeft(find.byWidget(item)).dy > 0,
        )
        .item;
    items = items.where((item) => item != leading).toList();
    await render();
    expect(tester.getTopLeft(row), before);
    items = items.where((item) => item != id).toList();
    await render();
    expect(row, findsNothing);

    final gesture = await tester.startGesture(const Offset(300, 400));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(controller.position.isScrollingNotifier.value, isTrue);
    final duringDrag = controller.offset;
    items = [for (var i = 200; i < 300; i++) i, ...items];
    await render();
    expect(controller.position.isScrollingNotifier.value, isTrue);
    expect(controller.offset, duringDrag);
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(controller.offset, greaterThan(duringDrag));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -300),
      1000,
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.position.isScrollingNotifier.value, isTrue);
    final duringFling = controller.offset;
    items = [400, 401, ...items];
    await render();
    expect(controller.position.isScrollingNotifier.value, isTrue);
    expect(controller.offset, duringFling);
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.offset, greaterThan(duringFling));
    await tester.pumpAndSettle();

    controller.jumpTo(0);
    await tester.pumpAndSettle();
    items = [-1, ...items];
    await render();
    expect(controller.offset, 0);
    expect(find.text('Item -1: 0'), findsOneWidget);

    items = [];
    await render();
    await tester.pumpAndSettle();
    expect(find.byType(_Row), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Row extends StatefulWidget {
  const _Row({required this.item});
  final int item;
  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> with AutomaticKeepAliveClientMixin {
  int count = 0;
  @override
  bool get wantKeepAlive => count > 0;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SizedBox(
      height: widget.item.isEven ? 80 : 120,
      child: TextButton(
        onPressed: () {
          setState(() => count++);
          updateKeepAlive();
        },
        child: Text('Item ${widget.item}: $count'),
      ),
    );
  }
}
