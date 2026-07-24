import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/podcast_search_repository.dart';

void main() {
  late AppDatabase database;
  late SafeNetworkClient network;
  late _SearchAdapter adapter;
  late PodcastSearchRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    adapter = _SearchAdapter();
    network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    repository = PodcastSearchRepository(database, network);
  });

  tearDown(() async {
    network.close();
    await database.close();
  });

  test('malformed catalog entries do not hide valid siblings', () async {
    final results = await repository.search('signal', 'US');

    expect(results, hasLength(1));
    expect(results.single.name, 'Valid Signal');
    expect(adapter.requests, 1);
  });

  test('a corrupt disk cache is discarded and fetched again', () async {
    final now = DateTime.now().toUtc();
    await database
        .into(database.searchCaches)
        .insert(
          SearchCachesCompanion.insert(
            key: 'apple:us:signal',
            payload: '{broken',
            expiresAt: now.add(const Duration(hours: 1)),
          ),
        );

    final results = await repository.search('signal', 'US');

    expect(results, hasLength(1));
    expect(adapter.requests, 1);
  });

  test(
    'catalog queries are case insensitive and share one cache entry',
    () async {
      final upper = await repository.search('SiGnAl', 'us');
      final lower = await repository.search('signal', 'US');

      expect(
        upper.map((result) => result.feedUrl),
        lower.map((result) => result.feedUrl),
      );
      expect(adapter.requests, 1);
      expect(adapter.terms, ['signal']);
    },
  );
}

final class _SearchAdapter implements HttpClientAdapter {
  int requests = 0;
  final terms = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    terms.add(options.uri.queryParameters['term']!);
    return ResponseBody.fromString(
      '''
      {
        "results": [
          7,
          {"collectionName": "Missing URL"},
          {
            "collectionName": "Valid Signal",
            "artistName": "trickle tests",
            "feedUrl": "https://example.test/feed.xml",
            "artworkUrl600": "https://example.test/art.jpg",
            "trackCount": 12
          }
        ]
      }
      ''',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
