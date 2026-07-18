import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'url_identity.dart';

String stableContentId(String scope, String identity) {
  return sha256.convert(utf8.encode('$scope|$identity')).toString();
}

String publicEpisodeIdentity({
  required String? guid,
  required Uri enclosureUrl,
  required DateTime? publishedAt,
  required String title,
}) {
  final normalizedGuid = guid?.trim();
  if (normalizedGuid?.isNotEmpty == true) return normalizedGuid!;
  final published = publishedAt?.toUtc().millisecondsSinceEpoch;
  return [
    credentialAgnosticUrl(enclosureUrl),
    published ?? title.trim().toLowerCase(),
  ].join('|');
}

String publicArticleIdentity({
  required String? guid,
  required Uri? canonicalUrl,
  required DateTime? publishedAt,
  required String title,
}) {
  final normalizedGuid = guid?.trim();
  if (normalizedGuid?.isNotEmpty == true) return normalizedGuid!;
  final published = publishedAt?.toUtc().millisecondsSinceEpoch;
  final normalizedTitle = title.trim().toLowerCase();
  if (canonicalUrl == null) return '$normalizedTitle|${published ?? 0}';
  return [
    credentialAgnosticUrl(canonicalUrl),
    published ?? normalizedTitle,
  ].join('|');
}
