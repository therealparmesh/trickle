const _youtubeHosts = {
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtu.be',
  'www.youtu.be',
};

const _youtubePlaybackHosts = {
  ..._youtubeHosts,
  'yout-ube.com',
  'www.yout-ube.com',
  'youtube-nocookie.com',
  'www.youtube-nocookie.com',
};

final _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _channelIdPattern = RegExp(r'^UC[A-Za-z0-9_-]{20,}$');

enum YouTubeFeedKind { channel, playlist }

bool isYouTubeAddress(Uri uri) =>
    uri.scheme.toLowerCase() == 'https' &&
    _youtubeHosts.contains(uri.host.toLowerCase());

YouTubeFeedKind? youtubeFeedKind(Uri? uri) {
  if (uri == null || !isYouTubeAddress(uri)) return null;
  final canonical = directYouTubeFeedUri(uri) ?? uri;
  if (_validPlaylistId(canonical.queryParameters['playlist_id'])) {
    return YouTubeFeedKind.playlist;
  }
  if (_channelIdPattern.hasMatch(
    canonical.queryParameters['channel_id'] ?? '',
  )) {
    return YouTubeFeedKind.channel;
  }
  final firstSegment = uri.pathSegments.firstOrNull?.toLowerCase();
  if (firstSegment?.startsWith('@') == true ||
      const {'channel', 'c', 'user'}.contains(firstSegment)) {
    return YouTubeFeedKind.channel;
  }
  return null;
}

/// Converts YouTube URLs that contain a stable channel or playlist identifier
/// directly to YouTube's Atom endpoint. Handle, custom, and legacy user URLs
/// return null so the caller can inspect the channel page for its identifier.
Uri? directYouTubeFeedUri(Uri uri) {
  if (!isYouTubeAddress(uri)) return null;

  if (uri.path == '/feeds/videos.xml') {
    final channelId = uri.queryParameters['channel_id']?.trim();
    if (channelId != null && _channelIdPattern.hasMatch(channelId)) {
      return _youtubeFeedUri('channel_id', channelId);
    }
    final playlistId = uri.queryParameters['playlist_id']?.trim();
    if (_validPlaylistId(playlistId)) {
      return _youtubeFeedUri('playlist_id', playlistId!);
    }
    return null;
  }

  // Playlist share links can point at the playlist itself or at a video
  // currently being watched inside it. In both cases the explicit list is the
  // subscription the user pasted.
  final playlistId = uri.queryParameters['list']?.trim();
  if (_validPlaylistId(playlistId)) {
    return _youtubeFeedUri('playlist_id', playlistId!);
  }

  final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (segments.length >= 2 &&
      segments.first.toLowerCase() == 'channel' &&
      _channelIdPattern.hasMatch(segments[1])) {
    return _youtubeFeedUri('channel_id', segments[1]);
  }

  return null;
}

/// Finds a channel identifier in a YouTube channel page without depending on
/// one exact page serialization. The returned endpoint is stable and can be
/// refreshed without revisiting the page.
Uri? discoverYouTubeFeedUri(Uri pageUri, String html) {
  if (!isYouTubeAddress(pageUri)) return null;
  final direct = directYouTubeFeedUri(pageUri);
  if (direct != null) return direct;

  final patterns = [
    RegExp(
      r'''<meta[^>]+itemprop=["']channelId["'][^>]+content=["'](UC[A-Za-z0-9_-]{20,})["']''',
      caseSensitive: false,
    ),
    RegExp(
      r'''<meta[^>]+content=["'](UC[A-Za-z0-9_-]{20,})["'][^>]+itemprop=["']channelId["']''',
      caseSensitive: false,
    ),
    RegExp(r'"(?:channelId|externalId)"\s*:\s*"(UC[A-Za-z0-9_-]{20,})"'),
    RegExp(r'https://(?:www\.)?youtube\.com/channel/(UC[A-Za-z0-9_-]{20,})'),
  ];
  for (final pattern in patterns) {
    final channelId = pattern.firstMatch(html)?.group(1);
    if (channelId != null) return _youtubeFeedUri('channel_id', channelId);
  }
  return null;
}

String? youtubeVideoId(Uri? uri) {
  if (uri == null || uri.scheme.toLowerCase() != 'https') return null;
  final host = uri.host.toLowerCase();
  if (!_youtubePlaybackHosts.contains(host)) return null;

  String? candidate;
  if (host == 'youtu.be' || host == 'www.youtu.be') {
    candidate = uri.pathSegments.firstOrNull;
  } else if (uri.path == '/watch') {
    candidate = uri.queryParameters['v'];
  } else {
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.length >= 2 &&
        const {
          'embed',
          'shorts',
          'live',
        }.contains(segments.first.toLowerCase())) {
      candidate = segments[1];
    }
  }
  final value = candidate?.trim();
  return value != null && _videoIdPattern.hasMatch(value) ? value : null;
}

Uri? privacyYouTubePlaybackUri(Uri? source) {
  final videoId = youtubeVideoId(source);
  if (videoId == null) return null;
  return Uri.https('www.yout-ube.com', '/watch', {'v': videoId});
}

Uri? officialYouTubePlaybackUri(Uri? source) {
  final videoId = youtubeVideoId(source);
  if (videoId == null) return null;
  return Uri.https('www.youtube.com', '/watch', {'v': videoId});
}

Uri _youtubeFeedUri(String parameter, String value) =>
    Uri.https('www.youtube.com', '/feeds/videos.xml', {parameter: value});

bool _validPlaylistId(String? value) {
  if (value == null || value.length < 10 || value.length > 128) return false;
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
}
