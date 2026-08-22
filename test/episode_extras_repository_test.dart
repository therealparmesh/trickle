import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/repositories/episode_extras_repository.dart';
import 'package:trickle/data/security/private_feed_store.dart';

void main() {
  late AppDatabase database;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.utc(2026, 8, 22);
    await database
        .into(database.feeds)
        .insert(
          FeedsCompanion.insert(
            id: 'podcast',
            title: 'Podcast',
            feedUrl: 'https://example.test/feed.xml',
            kind: Value(FeedKind.podcast.index),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.episodes)
        .insert(
          EpisodesCompanion.insert(
            id: 'episode',
            feedId: 'podcast',
            title: 'Episode',
            enclosureUrl: 'https://example.test/episode.mp3',
            discoveredAt: now,
          ),
        );
  });

  tearDown(() => database.close());

  test('VTT transcripts retain seek times and use the local cache', () async {
    const body = '''
WEBVTT

00:00:01.250 --> 00:00:03.000
Opening signal

00:01:02.500 --> 00:01:05.000
Second <b>segment</b> &amp; signal
''';
    final adapter = _TranscriptAdapter(body);
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    addTearDown(network.close);
    await _seedTranscript(database, mimeType: 'text/vtt', suffix: 'vtt');
    final repository = EpisodeExtrasRepository(
      database,
      network,
      PrivateFeedStore(),
    );

    final first = await repository.transcript('episode');
    final second = await repository.transcript('episode');

    expect(first?.segments.map((segment) => segment.startMs), [1250, 62500]);
    expect(first?.segments.last.text, 'Second segment & signal');
    expect(first?.hasTiming, isTrue);
    expect(second?.plainText, first?.plainText);
    expect(adapter.requests, 1);
  });

  test('JSON transcripts preserve speakers and second-based timing', () async {
    final adapter = _TranscriptAdapter('''
      {"segments":[
        {"startTime":2.5,"endTime":4,"speaker":"Ada","body":"Hello"},
        {"start_time":5,"text":"World"}
      ]}
    ''');
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    addTearDown(network.close);
    await _seedTranscript(
      database,
      mimeType: 'application/json',
      suffix: 'json',
    );
    final repository = EpisodeExtrasRepository(
      database,
      network,
      PrivateFeedStore(),
    );

    final transcript = await repository.transcript('episode');

    expect(transcript?.segments.first.startMs, 2500);
    expect(transcript?.segments.first.endMs, 4000);
    expect(transcript?.segments.first.speaker, 'Ada');
    expect(transcript?.plainText, 'Hello\n\nWorld');
  });

  test('a corrupt local transcript cache is fetched again', () async {
    final adapter = _TranscriptAdapter('Recovered transcript');
    final network = SafeNetworkClient.forTesting(
      Dio()..httpClientAdapter = adapter,
      addressValidator: (_) async {},
    );
    addTearDown(network.close);
    await _seedTranscript(database, mimeType: 'text/plain', suffix: 'txt');
    await database
        .update(database.transcripts)
        .write(
          TranscriptsCompanion(
            content: const Value('trickle-transcript-v1:{broken'),
            fetchedAt: Value(DateTime.now().toUtc()),
          ),
        );
    final repository = EpisodeExtrasRepository(
      database,
      network,
      PrivateFeedStore(),
    );

    final transcript = await repository.transcript('episode');

    expect(transcript?.plainText, 'Recovered transcript');
    expect(adapter.requests, 1);
  });
}

Future<void> _seedTranscript(
  AppDatabase database, {
  required String mimeType,
  required String suffix,
}) {
  return database
      .into(database.transcripts)
      .insert(
        TranscriptsCompanion.insert(
          id: 'transcript',
          episodeId: 'episode',
          url: 'https://example.test/transcript.$suffix',
          mimeType: Value(mimeType),
        ),
      );
}

final class _TranscriptAdapter implements HttpClientAdapter {
  _TranscriptAdapter(this.body);

  final String body;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(body, 200);
  }

  @override
  void close({bool force = false}) {}
}
