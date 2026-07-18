import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/constants.dart';
import '../../domain/feed_models.dart';
import '../database/app_database.dart';
import '../network/safe_network_client.dart';

final class PodcastSearchRepository {
  PodcastSearchRepository(this._database, this._network);

  final AppDatabase _database;
  final SafeNetworkClient _network;
  final List<DateTime> _requestTimes = [];

  Future<List<PodcastSearchResult>> search(
    String rawQuery,
    String region,
  ) async {
    final query = rawQuery.trim();
    if (query.length < 2) return const [];
    final candidateRegion = region.trim().toUpperCase();
    final normalizedRegion = RegExp(r'^[A-Z]{2}$').hasMatch(candidateRegion)
        ? candidateRegion
        : 'US';
    final key =
        'apple:${normalizedRegion.toLowerCase()}:${query.toLowerCase()}';
    final now = DateTime.now().toUtc();
    await (_database.delete(_database.searchCaches)..where(
          (row) =>
              row.expiresAt.isSmallerThanValue(now) | row.expiresAt.equals(now),
        ))
        .go();
    final cached = await (_database.select(
      _database.searchCaches,
    )..where((row) => row.key.equals(key))).getSingleOrNull();
    if (cached != null) {
      final decoded = _decode(cached.payload);
      if (decoded != null) return decoded;
      await (_database.delete(
        _database.searchCaches,
      )..where((row) => row.key.equals(key))).go();
    }

    await _waitForRateSlot();
    final uri = Uri.https('itunes.apple.com', '/search', {
      'term': query,
      'media': 'podcast',
      'entity': 'podcast',
      'country': normalizedRegion,
      'limit': '50',
      'explicit': 'Yes',
    });
    final document = await _network.get(
      uri,
      maxBytes: AppConstants.discoveryLimitBytes,
      totalTimeout: const Duration(seconds: 15),
    );
    final data = (jsonDecode(document.text) as Map).cast<String, Object?>();
    final results = _parseResults(data['results']);
    await _database
        .into(_database.searchCaches)
        .insertOnConflictUpdate(
          SearchCachesCompanion.insert(
            key: key,
            payload: jsonEncode(
              results.map((result) => result.toJson()).toList(),
            ),
            expiresAt: DateTime.now().toUtc().add(const Duration(hours: 24)),
          ),
        );
    return results;
  }

  Future<void> _waitForRateSlot() async {
    while (true) {
      final now = DateTime.now().toUtc();
      _requestTimes.removeWhere(
        (time) => now.difference(time) >= const Duration(seconds: 60),
      );
      final sinceLast = _requestTimes.isEmpty
          ? null
          : now.difference(_requestTimes.last);
      final oneSecondWait =
          sinceLast == null || sinceLast >= const Duration(seconds: 1)
          ? Duration.zero
          : const Duration(seconds: 1) - sinceLast;
      final rollingWait = _requestTimes.length < 20
          ? Duration.zero
          : const Duration(seconds: 60) - now.difference(_requestTimes.first);
      final wait = oneSecondWait > rollingWait ? oneSecondWait : rollingWait;
      if (wait <= Duration.zero) {
        _requestTimes.add(now);
        return;
      }
      await Future<void>.delayed(wait);
    }
  }

  List<PodcastSearchResult>? _decode(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is List ? _parseResults(decoded) : null;
    } on Object {
      return null;
    }
  }

  List<PodcastSearchResult> _parseResults(Object? rawResults) {
    if (rawResults is! List) return const [];
    return rawResults
        .map((raw) {
          try {
            return PodcastSearchResult.fromJson(
              (raw as Map).cast<String, Object?>(),
            );
          } on Object {
            return null;
          }
        })
        .whereType<PodcastSearchResult>()
        .toList(growable: false);
  }
}
