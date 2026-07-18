import '../core/constants.dart';

final class ParsedFeed {
  const ParsedFeed({
    required this.title,
    required this.description,
    required this.siteUrl,
    required this.imageUrl,
    required this.author,
    required this.kind,
    required this.episodes,
    required this.articles,
  });

  final String title;
  final String? description;
  final Uri? siteUrl;
  final Uri? imageUrl;
  final String? author;
  final FeedKind kind;
  final List<ParsedEpisode> episodes;
  final List<ParsedArticle> articles;
}

final class ParsedEpisode {
  const ParsedEpisode({
    required this.guid,
    required this.title,
    required this.description,
    required this.enclosureUrl,
    required this.mimeType,
    required this.imageUrl,
    required this.publishedAt,
    required this.duration,
    required this.fileSize,
    required this.explicit,
    required this.chaptersUrl,
    required this.transcripts,
  });

  final String? guid;
  final String title;
  final String? description;
  final Uri enclosureUrl;
  final String? mimeType;
  final Uri? imageUrl;
  final DateTime? publishedAt;
  final Duration? duration;
  final int? fileSize;
  final bool explicit;
  final Uri? chaptersUrl;
  final List<ParsedTranscript> transcripts;
}

final class ParsedArticle {
  const ParsedArticle({
    required this.guid,
    required this.title,
    required this.author,
    required this.summary,
    required this.contentHtml,
    required this.canonicalUrl,
    required this.imageUrl,
    required this.publishedAt,
  });

  final String? guid;
  final String title;
  final String? author;
  final String? summary;
  final String? contentHtml;
  final Uri? canonicalUrl;
  final Uri? imageUrl;
  final DateTime? publishedAt;
}

final class ParsedTranscript {
  const ParsedTranscript({required this.url, this.mimeType});

  final Uri url;
  final String? mimeType;
}

final class PodcastSearchResult {
  const PodcastSearchResult({
    required this.name,
    required this.author,
    required this.feedUrl,
    required this.artworkUrl,
    required this.genre,
    required this.episodeCount,
    required this.explicit,
  });

  final String name;
  final String author;
  final Uri feedUrl;
  final Uri? artworkUrl;
  final String? genre;
  final int? episodeCount;
  final bool explicit;

  factory PodcastSearchResult.fromJson(Map<String, Object?> json) {
    final rawFeed = json['feedUrl'] as String?;
    final parsedFeed = rawFeed == null ? null : Uri.tryParse(rawFeed);
    if (parsedFeed == null ||
        !const {'http', 'https'}.contains(parsedFeed.scheme) ||
        parsedFeed.host.isEmpty ||
        parsedFeed.userInfo.isNotEmpty) {
      throw const FormatException('Podcast result has no feed URL');
    }
    final rawArtwork = Uri.tryParse(
      (json['artworkUrl600'] ?? json['artworkUrl100']) as String? ?? '',
    );
    final artwork =
        rawArtwork != null &&
            const {'http', 'https'}.contains(rawArtwork.scheme) &&
            rawArtwork.host.isNotEmpty &&
            rawArtwork.userInfo.isEmpty
        ? (rawArtwork.scheme == 'http'
              ? rawArtwork.replace(scheme: 'https')
              : rawArtwork)
        : null;
    return PodcastSearchResult(
      name: (json['collectionName'] as String?)?.trim().isNotEmpty == true
          ? (json['collectionName'] as String).trim()
          : 'Untitled podcast',
      author: (json['artistName'] as String?)?.trim() ?? '',
      feedUrl: parsedFeed.scheme == 'http'
          ? parsedFeed.replace(scheme: 'https')
          : parsedFeed,
      artworkUrl: artwork,
      genre: json['primaryGenreName'] as String?,
      episodeCount: (json['trackCount'] as num?)?.toInt(),
      explicit: (json['collectionExplicitness'] as String?) == 'explicit',
    );
  }

  Map<String, Object?> toJson() => {
    'collectionName': name,
    'artistName': author,
    'feedUrl': feedUrl.toString(),
    'artworkUrl600': artworkUrl?.toString(),
    'primaryGenreName': genre,
    'trackCount': episodeCount,
    'collectionExplicitness': explicit ? 'explicit' : 'cleaned',
  };
}
