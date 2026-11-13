import '../../core/audio_file.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/url_identity.dart';
import '../database/app_database.dart';
import '../network/safe_network_client.dart';
import '../security/private_feed_store.dart';

final class PlaybackSource {
  const PlaybackSource({
    required this.resource,
    required this.headers,
    required this.isLocal,
  });

  final String resource;
  final Map<String, String> headers;
  final bool isLocal;
}

final class PlaybackSourceResolver {
  PlaybackSourceResolver(this._database, this._privateFeeds, this._network);

  final AppDatabase _database;
  final PrivateFeedStore _privateFeeds;
  final SafeNetworkClient _network;

  Future<PlaybackSource> resolve(
    Episode episode, {
    Duration totalTimeout = AppConstants.interactiveRequestTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    final download = await (_database.select(
      _database.mediaDownloads,
    )..where((row) => row.episodeId.equals(episode.id))).getSingleOrNull();
    if (download != null && download.status == DownloadState.complete.index) {
      final file = await storedAudioFile(download.filePath);
      if (file != null && await isUsableAudioFile(file)) {
        return PlaybackSource(
          resource: file.path,
          headers: const {},
          isLocal: true,
        );
      }
      try {
        await _database.markDownloadFileUnavailable(download);
      } on Object {
        // A transient library write failure should not prevent streaming.
      }
    }
    final remote = await resolveRemote(
      episode,
      totalTimeout: totalTimeout - stopwatch.elapsed,
    );
    return PlaybackSource(
      resource: remote.url.toString(),
      headers: remote.headers,
      isLocal: false,
    );
  }

  Future<NetworkResource> resolveRemote(
    Episode episode, {
    required Duration totalTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    Duration remaining() {
      final value = totalTimeout - stopwatch.elapsed;
      if (value <= Duration.zero) {
        throw const NetworkException('The media request timed out.');
      }
      return value;
    }

    final feed = await _database.feedById(episode.feedId);
    if (feed?.isPrivate == true) {
      final mediaUrl = await _privateFeeds
          .readMediaUrl(episode.id)
          .timeout(remaining());
      final secret = await _privateFeeds
          .read(feed!.credentialRef ?? '')
          .timeout(remaining());
      if (mediaUrl == null || secret == null) {
        throw StateError('Private media credentials are missing.');
      }
      return _network.resolveResource(
        mediaUrl,
        headers: sameOrigin(mediaUrl, secret.url) ? secret.headers : const {},
        totalTimeout: remaining(),
      );
    }
    return _network.resolveResource(
      Uri.parse(episode.enclosureUrl),
      totalTimeout: remaining(),
    );
  }
}
