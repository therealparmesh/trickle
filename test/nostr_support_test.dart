import 'dart:async';
import 'dart:convert';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/core/nostr_identifier.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/network/safe_network_client.dart';
import 'package:trickle/data/nostr/nostr_event.dart';
import 'package:trickle/data/repositories/nostr_repository.dart';

void main() {
  test(
    'NIP-19 profile identifiers match the published interoperability vectors',
    () {
      const publicKey =
          '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';
      const npub =
          'npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6';
      const nprofile =
          'nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p';

      expect(parseNostrProfile(npub).publicKey, publicKey);
      expect(encodeNpub(publicKey), npub);
      final profile = parseNostrProfile('nostr:$nprofile');
      expect(profile.publicKey, publicKey);
      expect(profile.relays.map((relay) => relay.toString()), [
        'wss://r.x.com',
        'wss://djbas.sadkb.com',
      ]);
    },
  );

  test(
    'verified profile refresh keeps root media posts and rejects replies and deletions',
    () {
      const privateKey =
          '0000000000000000000000000000000000000000000000000000000000000003';
      final publicKey = bip340.getPublicKey(privateKey);
      final deleted = _signedEvent(
        privateKey: privateKey,
        publicKey: publicKey,
        createdAt: 100,
        kind: 1,
        tags: const [],
        content: 'Delete me',
      );
      final root = _signedEvent(
        privateKey: privateKey,
        publicKey: publicKey,
        createdAt: 104,
        kind: 1222,
        tags: const [
          ['content-warning', 'Loud audio'],
          [
            'imeta',
            'url https://cdn.example/audio.opus',
            'm audio/opus',
            'duration 12.5',
            'image https://cdn.example/cover.webp',
          ],
        ],
        content: 'Voice update',
      );
      final reply = _signedEvent(
        privateKey: privateKey,
        publicKey: publicKey,
        createdAt: 103,
        kind: 1,
        tags: [
          ['e', root['id'] as String, '', 'reply'],
        ],
        content: 'This is a reply',
      );
      final deletion = _signedEvent(
        privateKey: privateKey,
        publicKey: publicKey,
        createdAt: 105,
        kind: 5,
        tags: [
          ['e', deleted['id'] as String],
        ],
        content: '',
      );
      final metadata = _signedEvent(
        privateKey: privateKey,
        publicKey: publicKey,
        createdAt: 106,
        kind: 0,
        tags: const [],
        content: jsonEncode({
          'display_name': 'Signal Author',
          'about': 'Verified profile',
          'picture': 'https://cdn.example/avatar.png',
        }),
      );
      final relays = _signedEvent(
        privateKey: privateKey,
        publicKey: publicKey,
        createdAt: 107,
        kind: 10002,
        tags: const [
          ['r', 'wss://relay.example', 'write'],
          ['r', 'wss://read-only.example', 'read'],
        ],
        content: '',
      );

      final parsed = parseAndVerifyNostrEvents({
        'publicKey': publicKey,
        'events': [deleted, root, reply, deletion, metadata, relays],
      });

      expect(parsed.profile?.name, 'Signal Author');
      expect(parsed.posts, hasLength(1));
      expect(parsed.posts.single.title, 'Voice update');
      expect(parsed.posts.single.contentWarning, 'Loud audio');
      expect(parsed.posts.single.mediaKind, ArticleMediaKind.audio);
      expect(parsed.posts.single.attachments.single.durationMs, 12500);
      expect(parsed.deletedEvents.keys, contains(deleted['id']));
      expect(parsed.advertisedRelays, ['wss://relay.example']);
    },
  );

  test('address deletion does not erase a newer replacement', () {
    const privateKey =
        '0000000000000000000000000000000000000000000000000000000000000003';
    final publicKey = bip340.getPublicKey(privateKey);
    final address = '30023:$publicKey:daily';
    final oldPost = _signedEvent(
      privateKey: privateKey,
      publicKey: publicKey,
      createdAt: 100,
      kind: 30023,
      tags: const [
        ['d', 'daily'],
        ['title', 'Old article'],
      ],
      content: 'Old',
    );
    final deletion = _signedEvent(
      privateKey: privateKey,
      publicKey: publicKey,
      createdAt: 101,
      kind: 5,
      tags: [
        ['a', address],
      ],
      content: '',
    );
    final replacement = _signedEvent(
      privateKey: privateKey,
      publicKey: publicKey,
      createdAt: 102,
      kind: 30023,
      tags: const [
        ['d', 'daily'],
        ['title', 'New article'],
      ],
      content: 'New',
    );

    final parsed = parseAndVerifyNostrEvents({
      'publicKey': publicKey,
      'events': [oldPost, deletion, replacement],
    });

    expect(parsed.posts.single.title, 'New article');
    expect(
      parsed.deletedAddresses[address],
      DateTime.fromMillisecondsSinceEpoch(101000, isUtc: true),
    );
  });

  test('post attachment parsing is bounded for hostile relay data', () {
    const privateKey =
        '0000000000000000000000000000000000000000000000000000000000000003';
    final publicKey = bip340.getPublicKey(privateKey);
    final event = _signedEvent(
      privateKey: privateKey,
      publicKey: publicKey,
      createdAt: 108,
      kind: 20,
      tags: [
        for (var index = 0; index < 25; index++)
          [
            'imeta',
            'url https://cdn.example/image-$index.jpg',
            'm image/jpeg',
            for (var fallback = 0; fallback < 12; fallback++)
              'fallback https://fallback.example/$index-$fallback.jpg',
          ],
      ],
      content: 'Gallery',
    );

    final post = parseAndVerifyNostrEvents({
      'publicKey': publicKey,
      'events': [event],
    }).posts.single;

    expect(post.attachments, hasLength(20));
    expect(
      post.attachments
          .singleWhere((item) => item.url.endsWith('-0.jpg'))
          .fallbackUrls,
      hasLength(10),
    );
  });

  test(
    'relay events are verified before matching IDs are deduplicated',
    () async {
      const privateKey =
          '0000000000000000000000000000000000000000000000000000000000000003';
      final publicKey = bip340.getPublicKey(privateKey);
      final valid = _signedEvent(
        privateKey: privateKey,
        publicKey: publicKey,
        createdAt: 109,
        kind: 1,
        tags: const [],
        content: 'Verified post',
      );
      final poisoned = {...valid, 'content': 'Tampered post'};
      var connectionIndex = 0;
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final network = SafeNetworkClient.forTesting(
        Dio(),
        addressValidator: (_) async {},
        webSocketConnector: (_, _) async {
          final events = switch (connectionIndex++) {
            0 => [poisoned],
            1 => [valid],
            _ => const <Map<String, Object?>>[],
          };
          return _ScriptedRelaySocket(events: events);
        },
      );
      final repository = NostrRepository(database: database, network: network);

      try {
        final feed = await repository.subscribe(encodeNpub(publicKey));
        final articles = await database.select(database.articles).get();

        expect(connectionIndex, 3);
        expect(feed.refreshError, isNull);
        expect(articles, hasLength(1));
        expect(articles.single.title, 'Verified post');
      } finally {
        network.close();
        await database.close();
      }
    },
  );

  test('valid relay events survive a cleanup write failure', () async {
    const privateKey =
        '0000000000000000000000000000000000000000000000000000000000000003';
    final publicKey = bip340.getPublicKey(privateKey);
    final event = _signedEvent(
      privateKey: privateKey,
      publicKey: publicKey,
      createdAt: 110,
      kind: 1,
      tags: const [],
      content: 'Keep this post',
    );
    final sockets = <_ScriptedRelaySocket>[];
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final network = SafeNetworkClient.forTesting(
      Dio(),
      addressValidator: (_) async {},
      webSocketConnector: (_, _) async {
        final socket = _ScriptedRelaySocket(
          events: [event],
          failCloseMessage: true,
        );
        sockets.add(socket);
        return socket;
      },
    );
    final repository = NostrRepository(database: database, network: network);

    try {
      final feed = await repository.subscribe(encodeNpub(publicKey));
      final articles = await database.select(database.articles).get();

      expect(feed.refreshError, isNull);
      expect(articles.single.title, 'Keep this post');
      expect(sockets, hasLength(3));
      expect(sockets.every((socket) => socket.closed), isTrue);
    } finally {
      network.close();
      await database.close();
    }
  });

  test(
    'a relay that closes without data is not reported as refreshed',
    () async {
      const privateKey =
          '0000000000000000000000000000000000000000000000000000000000000003';
      final publicKey = bip340.getPublicKey(privateKey);
      var connections = 0;
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final network = SafeNetworkClient.forTesting(
        Dio(),
        addressValidator: (_) async {},
        webSocketConnector: (_, _) async {
          connections++;
          return _ScriptedRelaySocket(closeBeforeData: true);
        },
      );
      final repository = NostrRepository(database: database, network: network);

      try {
        final feed = await repository.subscribe(encodeNpub(publicKey));

        expect(connections, 3);
        expect(feed.lastRefresh, isNotNull);
        expect(feed.refreshError, 'Couldn’t reach this profile’s relays.');
        expect(await database.select(database.articles).get(), isEmpty);
      } finally {
        network.close();
        await database.close();
      }
    },
  );

  test('an older relay response cannot replace newer content', () async {
    const privateKey =
        '0000000000000000000000000000000000000000000000000000000000000003';
    final publicKey = bip340.getPublicKey(privateKey);
    final olderEvent = _signedEvent(
      privateKey: privateKey,
      publicKey: publicKey,
      createdAt: 111,
      kind: 30023,
      tags: const [
        ['d', 'daily'],
        ['title', 'Older article'],
      ],
      content: 'Older body',
    );
    final newerEvent = _signedEvent(
      privateKey: privateKey,
      publicKey: publicKey,
      createdAt: 112,
      kind: 30023,
      tags: const [
        ['d', 'daily'],
        ['title', 'Newer article'],
      ],
      content: 'Newer body',
    );
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final initialNetwork = _testNetwork(() => _ScriptedRelaySocket());
    final feed = await NostrRepository(
      database: database,
      network: initialNetwork,
    ).subscribe(encodeNpub(publicKey));
    final releaseOlder = Completer<void>();
    final olderStarted = Completer<void>();
    var olderRequests = 0;
    final olderNetwork = _testNetwork(
      () => _ScriptedRelaySocket(
        events: [olderEvent],
        release: releaseOlder.future,
        onRequest: () {
          olderRequests++;
          if (olderRequests == 3) olderStarted.complete();
        },
      ),
    );
    final newerNetwork = _testNetwork(
      () => _ScriptedRelaySocket(events: [newerEvent]),
    );
    final olderRepository = NostrRepository(
      database: database,
      network: olderNetwork,
    );
    final newerRepository = NostrRepository(
      database: database,
      network: newerNetwork,
    );

    try {
      final olderRefresh = olderRepository.refresh(feed);
      await olderStarted.future.timeout(const Duration(seconds: 1));
      expect(await newerRepository.refresh(feed), isTrue);
      releaseOlder.complete();
      expect(await olderRefresh, isTrue);

      final articles = await database.select(database.articles).get();
      expect(articles, hasLength(1));
      expect(articles.single.title, 'Newer article');
      expect(articles.single.summary, isNull);
    } finally {
      if (!releaseOlder.isCompleted) releaseOlder.complete();
      initialNetwork.close();
      olderNetwork.close();
      newerNetwork.close();
      await database.close();
    }
  });
}

Map<String, Object?> _signedEvent({
  required String privateKey,
  required String publicKey,
  required int createdAt,
  required int kind,
  required List<List<String>> tags,
  required String content,
}) {
  final serialized = jsonEncode([0, publicKey, createdAt, kind, tags, content]);
  final id = sha256.convert(utf8.encode(serialized)).toString();
  return {
    'id': id,
    'pubkey': publicKey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': bip340.sign(privateKey, id, ''.padLeft(64, '0')),
  };
}

final class _ScriptedRelaySocket implements NetworkWebSocket {
  _ScriptedRelaySocket({
    this.events = const [],
    this.closeBeforeData = false,
    this.failCloseMessage = false,
    this.release,
    this.onRequest,
  });

  final List<Map<String, Object?>> events;
  final bool closeBeforeData;
  final bool failCloseMessage;
  final Future<void>? release;
  final void Function()? onRequest;
  final StreamController<Object?> _messages = StreamController<Object?>();
  bool closed = false;

  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  void add(Object? data) {
    final decoded = jsonDecode(data! as String) as List<Object?>;
    if (decoded.first == 'CLOSE') {
      if (failCloseMessage) throw StateError('relay already closed');
      return;
    }
    if (decoded.first != 'REQ') return;
    final subscription = decoded[1];
    onRequest?.call();
    scheduleMicrotask(() async {
      await release;
      if (closed) return;
      if (closeBeforeData) {
        _messages.add(jsonEncode(['CLOSED', subscription, 'closed']));
        return;
      }
      for (final event in events) {
        _messages.add(jsonEncode(['EVENT', subscription, event]));
      }
      _messages.add(jsonEncode(['EOSE', subscription]));
    });
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _messages.close();
  }
}

SafeNetworkClient _testNetwork(_ScriptedRelaySocket Function() socket) {
  return SafeNetworkClient.forTesting(
    Dio(),
    addressValidator: (_) async {},
    webSocketConnector: (_, _) async => socket(),
  );
}
