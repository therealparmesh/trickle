import 'dart:io';
import 'dart:ui' show Rect;

import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xml/xml.dart';

import '../core/constants.dart';
import '../data/database/app_database.dart';
import '../data/repositories/feed_repository.dart';
import '../data/security/private_feed_store.dart';

final class OpmlImportResult {
  const OpmlImportResult({required this.imported, required this.failed});
  final int imported;
  final int failed;
}

enum OpmlExportScope { podcasts, allSubscriptions }

final class OpmlExportResult {
  const OpmlExportResult({
    required this.exported,
    required this.skippedHeaderAuth,
    required this.skippedMissingCredentials,
  });

  final int exported;
  final int skippedHeaderAuth;
  final int skippedMissingCredentials;
}

final class OpmlExportDocument {
  const OpmlExportDocument({
    required this.xml,
    required this.exported,
    required this.skippedHeaderAuth,
    required this.skippedMissingCredentials,
  });

  final String xml;
  final int exported;
  final int skippedHeaderAuth;
  final int skippedMissingCredentials;
}

final class OpmlSubscription {
  const OpmlSubscription({
    required this.title,
    required this.feedUrl,
    this.siteUrl,
  });

  final String title;
  final String feedUrl;
  final String? siteUrl;
}

final class OpmlService {
  OpmlService(this._database, this._feeds, this._privateFeeds);

  final AppDatabase _database;
  final FeedRepository _feeds;
  final PrivateFeedStore _privateFeeds;

  Future<OpmlExportResult> exportAndShare({
    OpmlExportScope scope = OpmlExportScope.allSubscriptions,
    Rect? sharePositionOrigin,
  }) async {
    final podcastsOnly = scope == OpmlExportScope.podcasts;
    final title = podcastsOnly ? 'trickle podcasts' : 'trickle subscriptions';
    final document = await buildOpmlExportDocument(
      _database,
      privateFeeds: _privateFeeds,
      scope: scope,
    );
    final temp = await getTemporaryDirectory();
    final file = File(
      p.join(
        temp.path,
        podcastsOnly ? 'trickle-podcasts.opml' : 'trickle-subscriptions.opml',
      ),
    );
    await file.writeAsString(document.xml, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/x-opml')],
        subject: title,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
    return OpmlExportResult(
      exported: document.exported,
      skippedHeaderAuth: document.skippedHeaderAuth,
      skippedMissingCredentials: document.skippedMissingCredentials,
    );
  }

  Future<OpmlImportResult?> pickAndImport() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'OPML', extensions: ['opml', 'xml']),
      ],
    );
    if (file == null) return null;
    if (await file.length() > 10 * 1024 * 1024) {
      throw const FormatException('OPML exceeds the 10 MiB import limit.');
    }
    final text = await file.readAsString();
    return importOpmlSubscriptions(
      text,
      subscribe: (url) =>
          _feeds.subscribe(url, totalTimeout: const Duration(seconds: 45)),
    );
  }
}

Future<OpmlExportDocument> buildOpmlExportDocument(
  AppDatabase database, {
  required PrivateFeedStore privateFeeds,
  required OpmlExportScope scope,
}) async {
  final query = database.select(database.feeds)
    ..where((row) {
      if (scope == OpmlExportScope.allSubscriptions) {
        return const Constant(true);
      }
      return row.kind.isIn([FeedKind.podcast.index, FeedKind.hybrid.index]);
    })
    ..orderBy([(row) => OrderingTerm.asc(row.title)]);
  final feeds = await query.get();
  final subscriptions = <OpmlSubscription>[];
  var skippedHeaderAuth = 0;
  var skippedMissingCredentials = 0;
  for (final feed in feeds) {
    var feedUrl = feed.feedUrl;
    if (feed.isPrivate) {
      PrivateFeedSecret? secret;
      try {
        secret = await privateFeeds.read(feed.credentialRef ?? '');
      } on Object {
        skippedMissingCredentials++;
        continue;
      }
      if (secret == null) {
        skippedMissingCredentials++;
        continue;
      }
      if (secret.headers.isNotEmpty) {
        skippedHeaderAuth++;
        continue;
      }
      feedUrl = secret.url.toString();
    }
    subscriptions.add(
      OpmlSubscription(
        title: feed.title,
        feedUrl: feedUrl,
        siteUrl: feed.siteUrl,
      ),
    );
  }
  return OpmlExportDocument(
    xml: buildOpmlDocument(
      title: scope == OpmlExportScope.podcasts
          ? 'trickle podcasts'
          : 'trickle subscriptions',
      subscriptions: subscriptions,
    ),
    exported: subscriptions.length,
    skippedHeaderAuth: skippedHeaderAuth,
    skippedMissingCredentials: skippedMissingCredentials,
  );
}

String buildOpmlDocument({
  required String title,
  required Iterable<OpmlSubscription> subscriptions,
}) {
  final builder = XmlBuilder();
  builder.processing('xml', 'version="1.0" encoding="UTF-8"');
  builder.element(
    'opml',
    attributes: {'version': '2.0'},
    nest: () {
      builder.element(
        'head',
        nest: () => builder.element('title', nest: title),
      );
      builder.element(
        'body',
        nest: () {
          for (final subscription in subscriptions) {
            builder.element(
              'outline',
              attributes: {
                'text': subscription.title,
                'title': subscription.title,
                'type': 'rss',
                'xmlUrl': subscription.feedUrl,
                if (subscription.siteUrl != null)
                  'htmlUrl': subscription.siteUrl!,
              },
            );
          }
        },
      );
    },
  );
  return builder.buildDocument().toXmlString(pretty: true);
}

Future<OpmlImportResult> importOpmlSubscriptions(
  String source, {
  required Future<void> Function(String url) subscribe,
}) async {
  final urls = await compute(extractOpmlUrls, source);
  var imported = 0;
  var failed = 0;
  for (var offset = 0; offset < urls.length; offset += 4) {
    final end = (offset + 4).clamp(0, urls.length);
    final outcomes = await Future.wait(
      urls.sublist(offset, end).map((url) async {
        try {
          await subscribe(url);
          return true;
        } on Object {
          return false;
        }
      }),
    );
    imported += outcomes.where((success) => success).length;
    failed += outcomes.where((success) => !success).length;
  }
  return OpmlImportResult(imported: imported, failed: failed);
}

List<String> extractOpmlUrls(String source) {
  final document = XmlDocument.parse(source);
  return document.descendants
      .whereType<XmlElement>()
      .map(
        (element) => element.attributes
            .where(
              (attribute) => attribute.name.local.toLowerCase() == 'xmlurl',
            )
            .map((attribute) => attribute.value)
            .firstOrNull,
      )
      .whereType<String>()
      .map((url) => url.trim())
      .where((url) => url.isNotEmpty)
      .toSet()
      .take(1000)
      .toList(growable: false);
}
