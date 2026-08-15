const maxFeedCategoryLength = 40;

final RegExp _categoryWhitespace = RegExp(r'\s+');

String? normalizeFeedCategory(String? value) {
  final normalized = value?.trim().replaceAll(_categoryWhitespace, ' ');
  if (normalized == null || normalized.isEmpty) return null;
  return String.fromCharCodes(normalized.runes.take(maxFeedCategoryLength));
}

String? feedCategoryIdentity(String? value) =>
    normalizeFeedCategory(value)?.toLowerCase();

List<String> feedCategoryOptions(Iterable<String?> values) {
  final categories = <String, String>{};
  for (final value in values) {
    final category = normalizeFeedCategory(value);
    final identity = feedCategoryIdentity(category);
    if (category != null && identity != null) {
      categories.putIfAbsent(identity, () => category);
    }
  }
  final result = categories.values.toList(growable: false)
    ..sort((left, right) {
      final folded = left.toLowerCase().compareTo(right.toLowerCase());
      return folded != 0 ? folded : left.compareTo(right);
    });
  return List.unmodifiable(result);
}
