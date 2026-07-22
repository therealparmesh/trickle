import 'dart:io';

import '../../core/audio_file.dart';
import '../../core/constants.dart';
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

  Future<PlaybackSource> resolve(Episode episode) async {
    final download = await (_database.select(
      _database.mediaDownloads,
    )..where((row) => row.episodeId.equals(episode.id))).getSingleOrNull();
    if (download?.status == DownloadState.complete.index &&
        download?.filePath != null) {
      final file = File(download!.filePath!);
      if (await isUsableAudioFile(file)) {
        return PlaybackSource(
          resource: download.filePath!,
          headers: const {},
          isLocal: true,
        );
      }
      // Reconciliation will repair the stale row. Streaming remains usable
      // in the meantime instead of failing on an unreadable local path.
    }
    final feed = await _database.feedById(episode.feedId);
    if (feed?.isPrivate == true) {
      final mediaUrl = await _privateFeeds.readMediaUrl(episode.id);
      final secret = await _privateFeeds.read(feed!.credentialRef ?? '');
      if (mediaUrl == null || secret == null) {
        throw StateError('Private media credentials are missing.');
      }
      final resource = await _network.resolveResource(
        mediaUrl,
        headers: sameOrigin(mediaUrl, secret.url) ? secret.headers : const {},
      );
      return PlaybackSource(
        resource: resource.url.toString(),
        headers: resource.headers,
        isLocal: false,
      );
    }
    final remote = await _network.resolveResource(
      Uri.parse(episode.enclosureUrl),
    );
    return PlaybackSource(
      resource: remote.url.toString(),
      headers: remote.headers,
      isLocal: false,
    );
  }
}
