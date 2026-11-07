import 'dart:async';

import 'package:flutter/material.dart';
import 'package:positioned_sliver_list/positioned_sliver_list.dart';

/// Keeps visible rows in place as refreshed items arrive above them.
final class StableSliverList<T> extends StatefulWidget {
  const StableSliverList({
    required this.items,
    required this.itemId,
    required this.itemBuilder,
    super.key,
  });

  final List<T> items;
  final String Function(T) itemId;
  final Widget Function(BuildContext, T) itemBuilder;

  @override
  State<StableSliverList<T>> createState() => _StableSliverListState<T>();
}

class _StableSliverListState<T> extends State<StableSliverList<T>> {
  final _controller = ListController();
  late List<T> _items = widget.items;

  void _preservePosition() {
    final position = _controller.scrollPosition;
    final visible = _controller.computeItemPositions();
    if (position == null ||
        position.pixels <= position.minScrollExtent ||
        visible == null ||
        visible.isEmpty ||
        visible.first.itemLeadingEdge > 0) {
      return;
    }
    final indices = {
      for (var i = 0; i < widget.items.length; i++)
        widget.itemId(widget.items[i]): i,
    };
    // If the first visible row was removed, preserve the next surviving row.
    for (final row in visible) {
      if (row.index >= _items.length) continue;
      final index = indices[widget.itemId(_items[row.index])];
      if (index == null) continue;
      unawaited(
        _controller.jumpToIndex(
          index,
          offset: row.itemLeadingEdge * position.viewportDimension,
        ),
      );
      break;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Scrollable.of(context).position.isScrollingNotifier,
      builder: (context, scrolling, _) {
        // Never interrupt a drag or fling to reposition refreshed rows.
        if (!scrolling) {
          _preservePosition();
          _items = widget.items;
        }
        final items = _items;
        final indices = {
          for (var i = 0; i < items.length; i++)
            ValueKey(widget.itemId(items[i])): i,
        };
        return SuperSliverList(
          listController: _controller,
          delegate: SliverChildBuilderDelegate(
            (context, index) => KeyedSubtree(
              key: ValueKey(widget.itemId(items[index])),
              child: widget.itemBuilder(context, items[index]),
            ),
            childCount: items.length,
            findChildIndexCallback: (key) => indices[key],
          ),
        );
      },
    );
  }
}
