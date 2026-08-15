import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/feed_identity.dart';
import '../../core/formatters.dart';
import '../../core/nostr_identifier.dart';
import '../database/app_database.dart';
import '../network/safe_network_client.dart';
import '../nostr/nostr_event.dart';

const _defaultNostrRelays = <String>[
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
];

final class NostrRepository {
  NostrRepository({
    required AppDatabase database,
    required SafeNetworkClient network,
  }) : _database = database,
       _network = network;

  final AppDatabase _database;
  final SafeNetworkClient _network;
  final Map<String, Future<bool>> _refreshes = {};

  Future<Episode> cacheAudioAttachment({
    required Article article,
    required ArticleAttachment attachment,
  }) async {
    final existing = await _database.episodeById(attachment.id);
    final now = DateTime.now().toUtc();
    await _database
        .into(_database.episodes)
        .insertOnConflictUpdate(
          EpisodesCompanion.insert(
            id: attachment.id,
            feedId: article.feedId,
            guid: Value('nostr-media:${article.id}'),
            title: article.title,
            description: Value(article.summary),
            enclosureUrl: attachment.url,
            mimeType: Value(attachment.mimeType),
            imageUrl: Value(attachment.previewUrl ?? article.imageUrl),
            publishedAt: Value(article.publishedAt),
            discoveredAt: existing?.discoveredAt ?? now,
            durationMs: Value(attachment.durationMs),
            explicit: const Value(false),
            played: Value(existing?.played ?? false),
            starred: Value(existing?.starred ?? false),
            automationApplied: const Value(true),
          ),
        );
    return (await _database.episodeById(attachment.id))!;
  }

  Future<Feed> subscribe(String rawAddress) async {
    final address = parseNostrProfile(rawAddress);
    final existingProfile =
        await (_database.select(_database.nostrProfiles)
              ..where((row) => row.publicKey.equals(address.publicKey)))
            .getSingleOrNull();
    final existing = existingProfile == null
        ? null
        : await _database.feedById(existingProfile.feedId);
    final feedId =
        existing?.id ?? stableContentId('nostr-profile', address.publicKey);
    final relays = _preferredRelays(
      address.relays.map((relay) => relay.toString()),
    );
    final now = DateTime.now().toUtc();
    await _database.transaction(() async {
      await _database
          .into(_database.feeds)
          .insertOnConflictUpdate(
            FeedsCompanion.insert(
              id: feedId,
              title: existing?.title ?? _abbreviatedKey(address.publicKey),
              description: Value(existing?.description),
              feedUrl: 'nostr:${address.displayAddress}',
              siteUrl: Value(existing?.siteUrl),
              imageUrl: Value(existing?.imageUrl),
              author: Value(existing?.author ?? encodeNpub(address.publicKey)),
              category: Value(existing?.category),
              kind: Value(FeedKind.reader.index),
              protocol: Value(FeedProtocol.nostr.index),
              subscribed: const Value(true),
              isPrivate: const Value(false),
              lastRefresh: Value(existing?.lastRefresh),
              refreshError: const Value(null),
              autoDownload: const Value(false),
              autoDownloadLimit: const Value(3),
              notifications: Value(existing?.notifications ?? false),
              introSkipMs: const Value(0),
              outroSkipMs: const Value(0),
              autoQueue: const Value(false),
              createdAt: existing?.createdAt ?? now,
              updatedAt: now,
            ),
          );
      await _database
          .into(_database.nostrProfiles)
          .insertOnConflictUpdate(
            NostrProfilesCompanion.insert(
              feedId: feedId,
              publicKey: address.publicKey,
            ),
          );
      await _replaceRelays(feedId, relays);
    });
    final feed = (await _database.feedById(feedId))!;
    await refresh(feed);
    return (await _database.feedById(feedId))!;
  }

  Future<bool> refresh(
    Feed requestedFeed, {
    Duration totalTimeout = AppConstants.feedRefreshTimeout,
  }) async {
    final active = _refreshes[requestedFeed.id];
    if (active != null) return active;
    final refresh = _refresh(requestedFeed, totalTimeout);
    _refreshes[requestedFeed.id] = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_refreshes[requestedFeed.id], refresh)) {
        final _ = _refreshes.remove(requestedFeed.id);
      }
    }
  }

  Future<bool> _refresh(Feed requestedFeed, Duration totalTimeout) async {
    final feed = await _database.feedById(requestedFeed.id);
    if (feed == null ||
        feed.protocol != FeedProtocol.nostr.index ||
        !feed.subscribed) {
      return false;
    }
    final profile = await (_database.select(
      _database.nostrProfiles,
    )..where((row) => row.feedId.equals(feed.id))).getSingleOrNull();
    if (profile == null) return false;
    final storedRelays = await (_database.select(
      _database.nostrRelays,
    )..where((row) => row.feedId.equals(feed.id))).get();
    final relays = _preferredRelays(storedRelays.map((relay) => relay.url));
    try {
      final rawEvents = await _loadFromRelays(
        profile.publicKey,
        relays,
        totalTimeout,
      );
      final data = await compute(parseAndVerifyNostrEvents, {
        'publicKey': profile.publicKey,
        'events': rawEvents,
      });
      await _persist(feed, profile.publicKey, relays, data);
      return true;
    } on Object catch (error) {
      final current = await _database.feedById(feed.id);
      if (current != null && current.updatedAt == feed.updatedAt) {
        await (_database.update(
          _database.feeds,
        )..where((row) => row.id.equals(feed.id))).write(
          FeedsCompanion(
            lastRefresh: Value(DateTime.now().toUtc()),
            refreshError: Value(friendlyError(error)),
          ),
        );
      }
      return false;
    }
  }

  Future<List<Map<String, Object?>>> _loadFromRelays(
    String publicKey,
    List<Uri> relays,
    Duration totalTimeout,
  ) async {
    final stopwatch = Stopwatch()..start();
    final outcomes = await Future.wait(
      relays.map((relay) async {
        final remaining = totalTimeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) return null;
        try {
          return await _loadRelay(publicKey, relay, remaining);
        } on Object {
          return null;
        }
      }),
    );
    final successful = outcomes
        .whereType<List<Map<String, Object?>>>()
        .toList();
    if (successful.isEmpty) {
      throw const NetworkException('Couldn’t reach this profile’s relays.');
    }
    final byId = <String, Map<String, Object?>>{};
    for (final events in successful) {
      for (final event in events) {
        final id = event['id'];
        if (id is String) byId.putIfAbsent(id, () => event);
      }
    }
    return byId.values.toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _loadRelay(
    String publicKey,
    Uri relay,
    Duration timeout,
  ) async {
    final stopwatch = Stopwatch()..start();
    final connection = await _network.connectWebSocket(
      relay,
      totalTimeout: timeout,
    );
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      await connection.close();
      throw const NetworkException('The relay request timed out.');
    }
    final subscription = 'trickle-${DateTime.now().microsecondsSinceEpoch}';
    final events = <Map<String, Object?>>[];
    var receivedBytes = 0;
    final done = Completer<void>();
    late final StreamSubscription<Object?> stream;
    final timer = Timer(remaining, () {
      if (!done.isCompleted) done.complete();
    });
    stream = connection.socket.listen(
      (message) {
        if (done.isCompleted || message is! String) return;
        receivedBytes += message.length;
        if (receivedBytes > 2 * 1024 * 1024) {
          done.complete();
          return;
        }
        try {
          final decoded = jsonDecode(message);
          if (decoded is! List ||
              decoded.length < 2 ||
              decoded[1] != subscription) {
            return;
          }
          if (decoded.first == 'EOSE') {
            done.complete();
          } else if (decoded.first == 'EVENT' &&
              decoded.length >= 3 &&
              decoded[2] is Map &&
              events.length < 250) {
            events.add((decoded[2] as Map).cast<String, Object?>());
          } else if (decoded.first == 'CLOSED') {
            done.complete();
          }
        } on Object {
          // Ignore malformed relay messages; verified events remain usable.
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );
    try {
      connection.socket.add(
        jsonEncode([
          'REQ',
          subscription,
          {
            'authors': [publicKey],
            'kinds': [0, 1, 5, 20, 21, 22, 1222, 30023, 34235, 34236, 10002],
            'limit': 200,
          },
        ]),
      );
      await done.future;
      connection.socket.add(jsonEncode(['CLOSE', subscription]));
      return events;
    } finally {
      timer.cancel();
      await stream.cancel();
      await connection.close();
    }
  }

  Future<void> _persist(
    Feed feed,
    String publicKey,
    List<Uri> requestedRelays,
    NostrRefreshData data,
  ) async {
    final now = DateTime.now().toUtc();
    final profile = data.profile;
    final relays = _preferredRelays([
      ...data.advertisedRelays,
      ...requestedRelays.map((relay) => relay.toString()),
    ]);
    await _database.transaction(() async {
      final current = await _database.feedById(feed.id);
      if (current == null ||
          !current.subscribed ||
          current.protocol != FeedProtocol.nostr.index) {
        return;
      }
      final title = profile?.name ?? current.title;
      await (_database.update(
        _database.feeds,
      )..where((row) => row.id.equals(feed.id))).write(
        FeedsCompanion(
          title: Value(title),
          description: Value(profile?.about ?? current.description),
          imageUrl: Value(profile?.picture ?? current.imageUrl),
          author: Value(encodeNpub(publicKey)),
          lastRefresh: Value(now),
          refreshError: const Value(null),
          updatedAt: Value(now),
        ),
      );
      await _replaceRelays(feed.id, relays);

      final existing = {
        for (final article in await (_database.select(
          _database.articles,
        )..where((row) => row.feedId.equals(feed.id))).get())
          article.id: article,
      };
      final deletedArticleIds = {
        for (final article in existing.values)
          if (_deletionApplies(article, data)) article.id,
      };
      if (deletedArticleIds.isNotEmpty) {
        await _database.customStatement(
          "DELETE FROM search_index WHERE kind = 'article' "
          'AND entity_id IN (SELECT CAST(value AS TEXT) FROM json_each(?))',
          [jsonEncode(deletedArticleIds.toList())],
        );
        await (_database.delete(
          _database.articles,
        )..where((row) => row.id.isIn(deletedArticleIds))).go();
        existing.removeWhere((id, _) => deletedArticleIds.contains(id));
      }
      final searchItems = <SearchIndexEntry>[
        SearchIndexEntry(
          entityId: feed.id,
          kind: 'feed',
          title: title,
          body: '${profile?.about ?? ''} ${encodeNpub(publicKey)}',
          feedTitle: title,
        ),
      ];
      for (final post in data.posts) {
        final identity = post.address ?? post.eventId;
        final id = stableContentId(feed.id, identity);
        final stored = existing[id];
        final primaryImage = post.attachments
            .where(
              (attachment) => attachment.mimeType?.startsWith('image/') == true,
            )
            .firstOrNull;
        await _database
            .into(_database.articles)
            .insertOnConflictUpdate(
              ArticlesCompanion.insert(
                id: id,
                feedId: feed.id,
                guid: Value(identity),
                title: post.title,
                author: Value(title),
                summary: Value(post.summary),
                contentHtml: Value(post.content),
                canonicalUrl: Value('nostr:${encodeNote(post.eventId)}'),
                imageUrl: Value(primaryImage?.previewUrl ?? primaryImage?.url),
                contentFormat: Value(post.contentFormat.index),
                contentWarning: Value(post.contentWarning),
                sourceEventId: Value(post.eventId),
                sourceAddress: Value(post.address),
                mediaKind: Value(post.mediaKind.index),
                publishedAt: Value(post.publishedAt),
                discoveredAt: stored?.discoveredAt ?? now,
                readAt: Value(stored?.readAt),
                starred: Value(stored?.starred ?? false),
              ),
            );
        await (_database.delete(
          _database.articleAttachments,
        )..where((row) => row.articleId.equals(id))).go();
        for (var index = 0; index < post.attachments.length; index++) {
          final attachment = post.attachments[index];
          await _database
              .into(_database.articleAttachments)
              .insert(
                ArticleAttachmentsCompanion.insert(
                  id: stableContentId(id, '$index:${attachment.url}'),
                  articleId: id,
                  position: index,
                  url: attachment.url,
                  mimeType: Value(attachment.mimeType),
                  previewUrl: Value(attachment.previewUrl),
                  alt: Value(attachment.alt),
                  width: Value(attachment.width),
                  height: Value(attachment.height),
                  durationMs: Value(attachment.durationMs),
                  fallbackUrls: Value(
                    attachment.fallbackUrls.isEmpty
                        ? null
                        : jsonEncode(attachment.fallbackUrls),
                  ),
                ),
              );
        }
        searchItems.add(
          SearchIndexEntry(
            entityId: id,
            kind: 'article',
            title: post.title,
            body: '${post.summary ?? ''} ${plainText(post.content)}',
            feedTitle: title,
          ),
        );
      }
      await _database.customStatement(
        "DELETE FROM episodes WHERE feed_id = ? AND guid LIKE 'nostr-media:%' "
        'AND NOT EXISTS (SELECT 1 FROM article_attachments '
        'WHERE article_attachments.id = episodes.id) AND starred = 0 '
        'AND NOT EXISTS (SELECT 1 FROM playback_progresses '
        'WHERE playback_progresses.episode_id = episodes.id '
        'AND playback_progresses.position_ms > 0) '
        'AND NOT EXISTS (SELECT 1 FROM queue_entries '
        'WHERE queue_entries.episode_id = episodes.id) '
        'AND NOT EXISTS (SELECT 1 FROM media_downloads '
        'WHERE media_downloads.episode_id = episodes.id) '
        'AND NOT EXISTS (SELECT 1 FROM bookmarks '
        'WHERE bookmarks.episode_id = episodes.id)',
        [feed.id],
      );
      await _database.indexSearchItems(searchItems);
    });
  }

  Future<void> _replaceRelays(String feedId, Iterable<Uri> relays) async {
    await (_database.delete(
      _database.nostrRelays,
    )..where((row) => row.feedId.equals(feedId))).go();
    for (final relay in relays) {
      await _database
          .into(_database.nostrRelays)
          .insert(
            NostrRelaysCompanion.insert(feedId: feedId, url: relay.toString()),
          );
    }
  }

  List<Uri> _preferredRelays(Iterable<String> candidates) {
    final result = <Uri>[];
    for (final raw in [...candidates, ..._defaultNostrRelays]) {
      final relay = normalizeNostrRelay(raw);
      if (relay != null && !result.contains(relay)) result.add(relay);
      if (result.length == 4) break;
    }
    return result;
  }

  String _abbreviatedKey(String publicKey) {
    final npub = encodeNpub(publicKey);
    return '${npub.substring(0, 12)}…${npub.substring(npub.length - 6)}';
  }

  bool _deletionApplies(Article article, NostrRefreshData data) {
    final eventDeletion = article.sourceEventId == null
        ? null
        : data.deletedEvents[article.sourceEventId];
    final addressDeletion = article.sourceAddress == null
        ? null
        : data.deletedAddresses[article.sourceAddress];
    final cutoff = switch ((eventDeletion, addressDeletion)) {
      (final event?, final address?) =>
        event.isAfter(address) ? event : address,
      (final event?, null) => event,
      (null, final address?) => address,
      _ => null,
    };
    final publishedAt = article.publishedAt;
    return cutoff != null &&
        (publishedAt == null || !publishedAt.isAfter(cutoff));
  }
}
