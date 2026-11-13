import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'url_identity.dart';
import 'youtube_support.dart';

bool feedUrlMayContainCredentials(Uri url) =>
    url.hasQuery && !isYouTubeAddress(url);

String stableContentId(String scope, String identity) {
  return sha256.convert(utf8.encode('$scope|$identity')).toString();
}

// Existing private podcasts used a query-free identity. Only use this to
// locate older rows, then verify the media URL before reusing them.
String legacyPrivateEpisodeIdentity({
  required Uri enclosureUrl,
  required DateTime? publishedAt,
  required String title,
}) {
  final published = publishedAt?.toUtc().millisecondsSinceEpoch;
  final url = enclosureUrl.replace(userInfo: '', query: '', fragment: '');
  return '$url|${published ?? title.trim().toLowerCase()}';
}

String episodeIdentity({
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

String articleIdentity({
  required String? guid,
  required Uri? canonicalUrl,
  required DateTime? publishedAt,
  required String title,
}) {
  final normalizedGuid = guid?.trim();
  if (normalizedGuid?.isNotEmpty == true) return normalizedGuid!;
  final published = publishedAt?.toUtc().millisecondsSinceEpoch;
  final normalizedTitle = title.trim().toLowerCase();
  if (canonicalUrl == null || canonicalUrl.host.isEmpty) {
    return '$normalizedTitle|${published ?? 0}';
  }
  return [
    credentialAgnosticUrl(canonicalUrl),
    published ?? normalizedTitle,
  ].join('|');
}
