import 'dart:convert';
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
import '../core/errors.dart';
import '../data/database/app_database.dart';
import '../data/repositories/feed_repository.dart';
import '../data/security/private_feed_store.dart';

final class OpmlImportResult {
  const OpmlImportResult({required this.imported, required this.failed});
  final int imported;
  final int failed;
}

enum OpmlExportScope { podcasts, reading, allSubscriptions }

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
    final (title, filename) = switch (scope) {
      OpmlExportScope.podcasts => ('trickle podcasts', 'trickle-podcasts.opml'),
      OpmlExportScope.reading => (
        'trickle reading feeds',
        'trickle-reading-feeds.opml',
      ),
      OpmlExportScope.allSubscriptions => (
        'trickle subscriptions',
        'trickle-subscriptions.opml',
      ),
    };
    final document = await buildOpmlExportDocument(
      _database,
      privateFeeds: _privateFeeds,
      scope: scope,
    );
    final temp = await getTemporaryDirectory();
    final file = File(p.join(temp.path, filename));
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
    XFile? file;
    try {
      file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'OPML',
            extensions: ['opml', 'xml'],
            mimeTypes: [
              'text/x-opml',
              'application/x-opml+xml',
              'text/xml',
              'application/xml',
              // Android document providers commonly classify .opml as plain
              // text or generic binary data. File contents are validated.
              'text/plain',
              'application/octet-stream',
            ],
            // iOS ignores extensions and requires uniform type identifiers.
            // public.data keeps custom .opml files selectable; contents are
            // still size-limited and validated before import.
            uniformTypeIdentifiers: ['public.xml', 'public.data'],
          ),
        ],
      );
    } on Object {
      throw const FeedParseException('Couldn’t open the file picker.');
    }
    if (file == null) return null;
    try {
      if (await file.length() > 10 * 1024 * 1024) {
        throw const FeedParseException(
          'That OPML file exceeds the 10 MiB import limit.',
        );
      }
      final text = decodeOpmlBytes(await file.readAsBytes());
      return await importOpmlSubscriptions(
        text,
        subscribe: (url) =>
            _feeds.subscribe(url, totalTimeout: const Duration(seconds: 45)),
      );
    } on FeedParseException {
      rethrow;
    } on XmlException {
      throw const FeedParseException('That file isn’t valid OPML.');
    } on FormatException catch (error) {
      final message = error.message.toString().trim();
      throw FeedParseException(
        message.isEmpty ? 'That file isn’t valid OPML.' : message,
      );
    } on FileSystemException {
      throw const FeedParseException('Couldn’t read that OPML file.');
    }
  }
}

String decodeOpmlBytes(List<int> bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes, offset: 2, littleEndian: true);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes, offset: 2, littleEndian: false);
    }
  }
  if (bytes.length >= 4) {
    if (bytes[0] == 0x3C && bytes[1] == 0 && bytes[2] == 0x3F) {
      return _decodeUtf16(bytes, offset: 0, littleEndian: true);
    }
    if (bytes[0] == 0 && bytes[1] == 0x3C && bytes[2] == 0) {
      return _decodeUtf16(bytes, offset: 0, littleEndian: false);
    }
  }
  final offset =
      bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF
      ? 3
      : 0;
  return utf8.decode(bytes.sublist(offset));
}

String _decodeUtf16(
  List<int> bytes, {
  required int offset,
  required bool littleEndian,
}) {
  if ((bytes.length - offset).isOdd) {
    throw const FormatException('That file has invalid UTF-16 text.');
  }
  final codeUnits = <int>[];
  for (var index = offset; index < bytes.length; index += 2) {
    final first = bytes[index];
    final second = bytes[index + 1];
    codeUnits.add(littleEndian ? first | (second << 8) : (first << 8) | second);
  }
  return String.fromCharCodes(codeUnits);
}

Future<OpmlExportDocument> buildOpmlExportDocument(
  AppDatabase database, {
  required PrivateFeedStore privateFeeds,
  required OpmlExportScope scope,
}) async {
  final query = database.select(database.feeds)
    ..where((row) {
      return switch (scope) {
        OpmlExportScope.podcasts => row.kind.isIn([
          FeedKind.podcast.index,
          FeedKind.hybrid.index,
        ]),
        OpmlExportScope.reading => row.kind.isIn([
          FeedKind.reader.index,
          FeedKind.hybrid.index,
        ]),
        OpmlExportScope.allSubscriptions => const Constant(true),
      };
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
      title: switch (scope) {
        OpmlExportScope.podcasts => 'trickle podcasts',
        OpmlExportScope.reading => 'trickle reading feeds',
        OpmlExportScope.allSubscriptions => 'trickle subscriptions',
      },
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
  final root = document.rootElement;
  final body = root.children
      .whereType<XmlElement>()
      .where((element) => element.name.local.toLowerCase() == 'body')
      .firstOrNull;
  if (root.name.local.toLowerCase() != 'opml' || body == null) {
    throw const FormatException('The selected file is not an OPML document.');
  }

  final urls = <String>[];
  final identities = <String>{};
  for (final element in body.descendants.whereType<XmlElement>()) {
    final value = element.attributes
        .where((attribute) => attribute.name.local.toLowerCase() == 'xmlurl')
        .map((attribute) => attribute.value.trim())
        .firstOrNull;
    if (value == null || value.isEmpty) continue;
    if (identities.add(_opmlUrlIdentity(value))) urls.add(value);
    if (urls.length == 1000) break;
  }
  return List.unmodifiable(urls);
}

String _opmlUrlIdentity(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return value;
  final scheme = uri.scheme.toLowerCase() == 'http'
      ? 'https'
      : uri.scheme.toLowerCase();
  return uri
      .replace(scheme: scheme, host: uri.host.toLowerCase())
      .removeFragment()
      .toString();
}
