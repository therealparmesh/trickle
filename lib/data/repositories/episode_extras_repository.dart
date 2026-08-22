import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/url_identity.dart';
import '../database/app_database.dart';
import '../network/safe_network_client.dart';
import '../security/private_feed_store.dart';

const _transcriptCachePrefix = 'trickle-transcript-v1:';

final class TranscriptSegment {
  const TranscriptSegment({
    required this.text,
    this.startMs,
    this.endMs,
    this.speaker,
  });

  final String text;
  final int? startMs;
  final int? endMs;
  final String? speaker;
}

final class TranscriptDocument {
  const TranscriptDocument(this.segments);

  final List<TranscriptSegment> segments;

  String get plainText => segments.map((segment) => segment.text).join('\n\n');
  bool get hasTiming => segments.any((segment) => segment.startMs != null);

  static TranscriptDocument fromPayload(Map<String, Object?> payload) {
    final rawSegments = payload['segments'];
    if (rawSegments is! List) return const TranscriptDocument([]);
    return TranscriptDocument([
      for (final raw in rawSegments.whereType<Map>())
        if ((raw['text']?.toString().trim() ?? '').isNotEmpty)
          TranscriptSegment(
            text: raw['text']!.toString().trim(),
            startMs: _intOrNull(raw['startMs']),
            endMs: _intOrNull(raw['endMs']),
            speaker: switch (raw['speaker']?.toString().trim()) {
              final value? when value.isNotEmpty => value,
              _ => null,
            },
          ),
    ]);
  }
}

final class EpisodeExtrasRepository {
  EpisodeExtrasRepository(this._database, this._network, this._privateFeeds);

  final AppDatabase _database;
  final SafeNetworkClient _network;
  final PrivateFeedStore _privateFeeds;
  final Uuid _uuid = const Uuid();

  Future<List<Chapter>> chapters(String episodeId) async {
    final cached =
        await (_database.select(_database.chapters)
              ..where((row) => row.episodeId.equals(episodeId))
              ..orderBy([(row) => OrderingTerm.asc(row.startMs)]))
            .get();
    final episode = await _database.episodeById(episodeId);
    if (episode?.chaptersUrl == null) return cached;
    final chaptersUri = Uri.parse(episode!.chaptersUrl!);
    try {
      final document = await _network.get(
        chaptersUri,
        headers: await _headersFor(episode, chaptersUri),
        maxBytes: AppConstants.discoveryLimitBytes,
      );
      final decoded = jsonDecode(document.text);
      final list = decoded is Map
          ? decoded['chapters'] as List?
          : decoded as List?;
      if (list == null) return cached;
      final chapters = <Chapter>[];
      for (final raw in list.whereType<Map>().take(1000)) {
        final json = raw.cast<String, Object?>();
        final start = _seconds(json['startTime'] ?? json['start_time']);
        if (start == null || !start.isFinite || start < 0 || start > 31536000) {
          continue;
        }
        chapters.add(
          Chapter(
            id: _uuid.v4(),
            episodeId: episodeId,
            startMs: (start * 1000).round(),
            title:
                json['title']?.toString() ?? 'Chapter ${chapters.length + 1}',
          ),
        );
      }
      chapters.sort((a, b) => a.startMs.compareTo(b.startMs));
      await _database.transaction(() async {
        await (_database.delete(
          _database.chapters,
        )..where((row) => row.episodeId.equals(episodeId))).go();
        if (chapters.isNotEmpty) {
          await _database.batch(
            (batch) => batch.insertAll(_database.chapters, chapters),
          );
        }
      });
      return chapters;
    } on Object {
      if (cached.isNotEmpty) return cached;
      rethrow;
    }
  }

  Future<TranscriptDocument?> transcript(String episodeId) async {
    final rows = await (_database.select(
      _database.transcripts,
    )..where((row) => row.episodeId.equals(episodeId))).get();
    if (rows.isEmpty) return null;
    rows.sort((left, right) {
      final type = _transcriptPriority(
        left.mimeType,
      ).compareTo(_transcriptPriority(right.mimeType));
      return type == 0 ? left.url.compareTo(right.url) : type;
    });
    final selected = rows.firstWhere(
      (row) => row.content?.isNotEmpty == true,
      orElse: () => rows.first,
    );
    final freshAfter = DateTime.now().toUtc().subtract(const Duration(days: 7));
    final cached = _decodeCachedTranscript(selected.content);
    if (cached != null &&
        selected.content?.startsWith(_transcriptCachePrefix) == true &&
        selected.fetchedAt?.isAfter(freshAfter) == true) {
      return cached;
    }
    final episode = await _database.episodeById(episodeId);
    if (episode == null) return null;
    final transcriptUri = Uri.parse(selected.url);
    late final Map<String, Object?> payload;
    try {
      final document = await _network.get(
        transcriptUri,
        headers: await _headersFor(episode, transcriptUri),
        maxBytes: AppConstants.transcriptLimitBytes,
      );
      payload = await compute(_parseTranscriptPayload, (
        document.text,
        selected.mimeType,
        selected.url,
      ));
    } on Object {
      if (cached != null) return cached;
      rethrow;
    }
    final transcript = TranscriptDocument.fromPayload(payload);
    final content = '$_transcriptCachePrefix${jsonEncode(payload)}';
    final updated =
        await (_database.update(
          _database.transcripts,
        )..where((row) => row.id.equals(selected.id))).write(
          TranscriptsCompanion(
            content: Value(content),
            fetchedAt: Value(DateTime.now().toUtc()),
          ),
        );
    if (updated > 0) {
      final feed = await _database.feedById(episode.feedId);
      await _database.indexSearchItem(
        entityId: episode.id,
        kind: 'episode',
        title: episode.title,
        body:
            '${html_parser.parseFragment(episode.description ?? '').text ?? ''} ${transcript.plainText}',
        feedTitle: feed?.title ?? '',
      );
    }
    return transcript;
  }

  Future<Map<String, String>> _headersFor(Episode episode, Uri uri) async {
    final feed = await _database.feedById(episode.feedId);
    if (feed?.isPrivate != true) return const {};
    final secret = await _privateFeeds.read(feed?.credentialRef ?? '');
    if (secret == null || !sameOrigin(uri, secret.url)) return const {};
    return secret.headers;
  }

  double? _seconds(Object? value) {
    if (value is num) return value.toDouble();
    final raw = value?.toString();
    if (raw == null) return null;
    final direct = double.tryParse(raw);
    if (direct != null) return direct;
    final parts = raw.split(':').map(double.tryParse).toList();
    if (parts.any((part) => part == null)) return null;
    if (parts.length == 2 && parts[1]! >= 0 && parts[1]! < 60) {
      return parts[0]! * 60 + parts[1]!;
    }
    if (parts.length == 3 &&
        parts[1]! >= 0 &&
        parts[1]! < 60 &&
        parts[2]! >= 0 &&
        parts[2]! < 60) {
      return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
    }
    return null;
  }

  int _transcriptPriority(String? mimeType) {
    final type = mimeType?.toLowerCase() ?? '';
    if (type.contains('json')) return 0;
    if (type.contains('vtt')) return 1;
    if (type.contains('srt')) return 2;
    if (type.startsWith('text/')) return 3;
    return 4;
  }
}

TranscriptDocument? _decodeCachedTranscript(String? content) {
  final value = content?.trim();
  if (value == null || value.isEmpty) return null;
  if (!value.startsWith(_transcriptCachePrefix)) {
    return TranscriptDocument([TranscriptSegment(text: value)]);
  }
  try {
    final decoded = jsonDecode(value.substring(_transcriptCachePrefix.length));
    return decoded is Map
        ? TranscriptDocument.fromPayload(decoded.cast<String, Object?>())
        : null;
  } on Object {
    return null;
  }
}

Map<String, Object?> _parseTranscriptPayload((String, String?, String) input) {
  final (source, mimeType, url) = input;
  final type = mimeType?.toLowerCase() ?? '';
  if (type.contains('json') || url.toLowerCase().endsWith('.json')) {
    try {
      final decoded = jsonDecode(source);
      final rawSegments = decoded is Map
          ? decoded['segments'] ?? decoded['transcript'] ?? decoded['items']
          : decoded;
      if (rawSegments is List) {
        final segments = rawSegments
            .map(_jsonTranscriptSegment)
            .whereType<Map<String, Object?>>()
            .toList();
        return {'segments': segments};
      }
    } on Object {
      // Malformed JSON is still useful as a plain-text transcript.
    }
  }
  if (type.contains('vtt') ||
      type.contains('srt') ||
      url.toLowerCase().endsWith('.vtt') ||
      url.toLowerCase().endsWith('.srt')) {
    final segments = <Map<String, Object?>>[];
    for (final block
        in source.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'))) {
      final lines = block
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      final timingIndex = lines.indexWhere((line) => line.contains('-->'));
      if (timingIndex < 0 || timingIndex + 1 >= lines.length) continue;
      final timing = lines[timingIndex].split('-->');
      if (timing.length != 2) continue;
      final sourceText = lines.skip(timingIndex + 1).join('\n').trim();
      final text =
          html_parser.parseFragment(sourceText).text?.trim() ?? sourceText;
      final startMs = _timestampMs(timing.first);
      if (text.isEmpty || startMs == null) continue;
      final segment = <String, Object?>{'text': text, 'startMs': startMs};
      final endMs = _timestampMs(timing.last.split(RegExp(r'\s+')).first);
      if (endMs != null) segment['endMs'] = endMs;
      segments.add(segment);
    }
    if (segments.isNotEmpty) return {'segments': segments};
  }
  final text = html_parser.parseFragment(source).text?.trim() ?? source.trim();
  return {
    'segments': [
      if (text.isNotEmpty) {'text': text},
    ],
  };
}

Map<String, Object?>? _jsonTranscriptSegment(Object? raw) {
  if (raw is! Map) {
    final text = raw?.toString().trim();
    return text?.isNotEmpty == true ? {'text': text} : null;
  }
  final text =
      (raw['body'] ?? raw['text'] ?? raw['content'])?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  final startMs = _jsonTimeMs(
    raw['startTime'] ?? raw['start_time'] ?? raw['start'] ?? raw['startMs'],
    milliseconds: raw.containsKey('startMs'),
  );
  final endMs = _jsonTimeMs(
    raw['endTime'] ?? raw['end_time'] ?? raw['end'] ?? raw['endMs'],
    milliseconds: raw.containsKey('endMs'),
  );
  final speaker = (raw['speaker'] ?? raw['voice'])?.toString().trim();
  final segment = <String, Object?>{'text': text};
  if (startMs != null) segment['startMs'] = startMs;
  if (endMs != null) segment['endMs'] = endMs;
  if (speaker?.isNotEmpty == true) segment['speaker'] = speaker;
  return segment;
}

int? _jsonTimeMs(Object? value, {required bool milliseconds}) {
  final number = value is num ? value.toDouble() : double.tryParse('$value');
  if (number == null || !number.isFinite || number < 0) return null;
  return milliseconds ? number.round() : (number * 1000).round();
}

int? _timestampMs(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  final parts = normalized.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final seconds = double.tryParse(parts.last);
  final minutes = int.tryParse(parts[parts.length - 2]);
  final hours = parts.length == 3 ? int.tryParse(parts.first) : 0;
  if (seconds == null || minutes == null || hours == null) return null;
  if (hours < 0 ||
      minutes < 0 ||
      minutes >= 60 ||
      seconds < 0 ||
      seconds >= 60) {
    return null;
  }
  return ((hours * 3600 + minutes * 60 + seconds) * 1000).round();
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  return int.tryParse('$value');
}
