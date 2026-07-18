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

  Future<String?> transcript(String episodeId) async {
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
    if (selected.content?.isNotEmpty == true &&
        selected.fetchedAt?.isAfter(freshAfter) == true) {
      return selected.content;
    }
    final episode = await _database.episodeById(episodeId);
    if (episode == null) return null;
    final transcriptUri = Uri.parse(selected.url);
    late final String content;
    try {
      final document = await _network.get(
        transcriptUri,
        headers: await _headersFor(episode, transcriptUri),
        maxBytes: AppConstants.transcriptLimitBytes,
      );
      content = await compute(_parseTranscript, (
        document.text,
        selected.mimeType,
        selected.url,
      ));
    } on Object {
      if (selected.content?.isNotEmpty == true) return selected.content;
      rethrow;
    }
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
            '${html_parser.parseFragment(episode.description ?? '').text ?? ''} $content',
        feedTitle: feed?.title ?? '',
      );
    }
    return content;
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

String _parseTranscript((String, String?, String) input) {
  final (source, mimeType, url) = input;
  final type = mimeType?.toLowerCase() ?? '';
  if (type.contains('json') || url.toLowerCase().endsWith('.json')) {
    try {
      final decoded = jsonDecode(source);
      final segments = decoded is Map
          ? decoded['segments'] ?? decoded['transcript'] ?? decoded['items']
          : decoded;
      if (segments is List) {
        return segments
            .map((segment) {
              if (segment is Map) {
                return segment['body'] ??
                    segment['text'] ??
                    segment['content'] ??
                    '';
              }
              return segment;
            })
            .join('\n\n')
            .replaceAll(RegExp(r'\s+\n'), '\n')
            .trim();
      }
    } on Object {
      return source.trim();
    }
  }
  if (type.contains('vtt') ||
      type.contains('srt') ||
      url.toLowerCase().endsWith('.vtt') ||
      url.toLowerCase().endsWith('.srt')) {
    return source
        .split('\n')
        .where(
          (line) =>
              line.trim().isNotEmpty &&
              !line.contains('-->') &&
              !RegExp(r'^\d+$').hasMatch(line.trim()) &&
              line.trim() != 'WEBVTT',
        )
        .join('\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim();
  }
  return html_parser.parseFragment(source).text?.trim() ?? source.trim();
}
