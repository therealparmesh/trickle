import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';
import '../../core/feed_category.dart';
import 'design_system.dart';

final class FeedCategoryField extends StatelessWidget {
  const FeedCategoryField({
    required this.controller,
    required this.focusNode,
    required this.options,
    this.enabled = true,
    this.initialCategory,
    this.helperText = 'Optional. Choose a category or enter a new one.',
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> options;
  final bool enabled;
  final String? initialCategory;
  final String helperText;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    final initialIdentity = feedCategoryIdentity(initialCategory);
    final field = LayoutBuilder(
      builder: (context, constraints) => RawAutocomplete<String>(
        textEditingController: controller,
        focusNode: focusNode,
        optionsBuilder: (value) {
          if (!enabled) return const Iterable<String>.empty();
          final query = feedCategoryIdentity(value.text) ?? '';
          if (query.isEmpty ||
              (initialIdentity != null && query == initialIdentity)) {
            return options;
          }
          return options.where(
            (category) => feedCategoryIdentity(category)!.contains(query),
          );
        },
        onSelected: (category) {
          controller.value = TextEditingValue(
            text: category,
            selection: TextSelection.collapsed(offset: category.length),
          );
        },
        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) =>
            TextField(
              enabled: enabled,
              controller: controller,
              focusNode: focusNode,
              inputFormatters: [
                LengthLimitingTextInputFormatter(maxFeedCategoryLength),
              ],
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: largeText ? null : 'Category',
                helperText: largeText ? null : helperText,
                suffixIcon: options.isEmpty
                    ? null
                    : const Icon(Icons.arrow_drop_down_rounded),
              ),
              onSubmitted: (_) => onFieldSubmitted(),
            ),
        optionsViewBuilder: (context, onSelected, matches) {
          final categories = matches.toList(growable: false);
          final highlighted = AutocompleteHighlightedOption.of(context);
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              color: AppConstants.elevated,
              elevation: 8,
              shape: const CutCornerBorder(
                cut: 10,
                side: BorderSide(color: AppConstants.hairline),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth,
                  maxHeight: 240,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    return InkWell(
                      onTap: () => onSelected(category),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: ColoredBox(
                          color: index == highlighted
                              ? AppConstants.magenta.withValues(alpha: 0.1)
                              : Colors.transparent,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(category),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
    if (!largeText) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Category'),
        const SizedBox(height: 8),
        field,
        const SizedBox(height: 6),
        Text(
          helperText,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppConstants.secondaryText),
        ),
      ],
    );
  }
}
