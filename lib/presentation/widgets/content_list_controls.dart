import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/content_filters.dart';
import 'common.dart';

final class ContentListControls<T extends Object> extends StatelessWidget {
  const ContentListControls({
    required this.searchController,
    required this.searchHint,
    required this.onSearchChanged,
    required this.filter,
    required this.filterOptions,
    required this.onFilterChanged,
    required this.sort,
    required this.onSortChanged,
    this.accent = AppConstants.cyan,
    super.key,
  });

  final TextEditingController searchController;
  final String searchHint;
  final ValueChanged<String> onSearchChanged;
  final T filter;
  final List<AdaptiveFilterOption<T>> filterOptions;
  final ValueChanged<T> onFilterChanged;
  final ContentSort sort;
  final ValueChanged<ContentSort> onSortChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final filters = AdaptiveFilterControl<T>(
      value: filter,
      options: filterOptions,
      onChanged: onFilterChanged,
    );
    final sortButton = PopupMenuButton<ContentSort>(
      tooltip: 'Sort items',
      initialValue: sort,
      onSelected: onSortChanged,
      itemBuilder: (_) => const [
        PopupMenuItem(value: ContentSort.newest, child: Text('Newest first')),
        PopupMenuItem(value: ContentSort.oldest, child: Text('Oldest first')),
      ],
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: OutlinedButton.icon(
            onPressed: () {},
            style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              side: BorderSide(color: accent.withValues(alpha: 0.45)),
            ),
            icon: const Icon(Icons.swap_vert_rounded),
            label: Text(
              sort == ContentSort.newest ? 'Newest' : 'Oldest',
              maxLines: 1,
            ),
          ),
        ),
      ),
    );
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SearchBar(
            controller: searchController,
            hintText: searchHint,
            leading: const Icon(Icons.search_rounded),
            trailing: [
              if (searchController.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    searchController.clear();
                    onSearchChanged('');
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
            textCapitalization: TextCapitalization.none,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            onChanged: onSearchChanged,
          ),
          const SizedBox(height: 10),
          if (largeText) ...[
            filters,
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft, child: sortButton),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: filters),
                const SizedBox(width: 10),
                sortButton,
              ],
            ),
        ],
      ),
    );
  }
}
