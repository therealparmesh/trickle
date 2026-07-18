import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../domain/feed_models.dart';

final class FeedParser {
  const FeedParser();

  ParsedFeed parse(String source, Uri sourceUrl) {
    final trimmed = source.trimLeft();
    if (trimmed.startsWith('{')) return _parseJson(trimmed, sourceUrl);
    try {
      final document = XmlDocument.parse(source);
      final root = document.rootElement;
      if (root.name.local.toLowerCase() == 'feed') {
        return _parseAtom(root, sourceUrl);
      }
      return _parseRss(root, sourceUrl);
    } on XmlParserException {
      throw const FeedParseException('This feed contains invalid XML.');
    } on FeedParseException {
      rethrow;
    } on Object {
      throw const FeedParseException(
        'This address did not contain a supported feed.',
      );
    }
  }

  ParsedFeed _parseRss(XmlElement root, Uri sourceUrl) {
    final discoveredChannel = root.children.whereType<XmlElement>().firstWhere(
      (element) => element.name.local.toLowerCase() == 'channel',
      orElse: () => XmlElement(const XmlName.parts('missing')),
    );
    final channel = root.name.local.toLowerCase() == 'channel'
        ? root
        : discoveredChannel;
    if (channel.name.local == 'missing') {
      throw const FeedParseException('The RSS feed has no channel.');
    }
    final title = _childText(channel, 'title') ?? sourceUrl.host;
    final image = _rssImage(channel, sourceUrl);
    final channelItems = channel.children.whereType<XmlElement>().where(
      _isRssItem,
    );
    final items = identical(root, channel)
        ? channelItems
        : channelItems.followedBy(
            root.children.whereType<XmlElement>().where(_isRssItem),
          );
    final episodes = <ParsedEpisode>[];
    final articles = <ParsedArticle>[];
    for (final item in items.take(5000)) {
      final enclosure = _audioEnclosure(item, sourceUrl);
      if (enclosure != null) {
        episodes.add(_rssEpisode(item, sourceUrl, image, enclosure));
      } else {
        articles.add(_rssArticle(item, sourceUrl));
      }
    }
    return ParsedFeed(
      title: title,
      description: _plainText(_childText(channel, 'description')),
      siteUrl: _uri(_childText(channel, 'link'), sourceUrl),
      imageUrl: image,
      author:
          _childText(channel, 'author') ??
          _childText(channel, 'managingEditor'),
      kind: _kind(episodes, articles),
      episodes: episodes,
      articles: articles,
    );
  }

  ParsedEpisode _rssEpisode(
    XmlElement item,
    Uri sourceUrl,
    Uri? feedImage,
    _Enclosure enclosure,
  ) {
    final chapters = _qualifiedChild(item, 'podcast:chapters');
    final transcripts = item.children
        .whereType<XmlElement>()
        .where((element) => _isQualified(element, 'podcast:transcript'))
        .map((element) {
          final url = _uri(element.getAttribute('url'), sourceUrl);
          return url == null
              ? null
              : ParsedTranscript(
                  url: url,
                  mimeType: element.getAttribute('type'),
                );
        })
        .whereType<ParsedTranscript>()
        .toList(growable: false);
    return ParsedEpisode(
      guid: _childText(item, 'guid'),
      title: _childText(item, 'title') ?? 'Untitled episode',
      description:
          _qualifiedText(item, 'content:encoded') ??
          _childText(item, 'description'),
      enclosureUrl: enclosure.url,
      mimeType: enclosure.type,
      imageUrl: _itemImage(item, sourceUrl) ?? feedImage,
      publishedAt: _date(
        _childText(item, 'pubDate') ?? _childText(item, 'published'),
      ),
      duration: _duration(_qualifiedText(item, 'itunes:duration')),
      fileSize: enclosure.length,
      explicit: _explicit(_qualifiedText(item, 'itunes:explicit')),
      chaptersUrl: _uri(chapters?.getAttribute('url'), sourceUrl),
      transcripts: transcripts,
    );
  }

  ParsedArticle _rssArticle(XmlElement item, Uri sourceUrl) {
    final content =
        _qualifiedText(item, 'content:encoded') ??
        _childText(item, 'description');
    return ParsedArticle(
      guid: _childText(item, 'guid'),
      title: _childText(item, 'title') ?? 'Untitled article',
      author: _childText(item, 'author') ?? _qualifiedText(item, 'dc:creator'),
      summary: _plainText(_childText(item, 'description')),
      contentHtml: content,
      canonicalUrl: _uri(_childText(item, 'link'), sourceUrl),
      imageUrl: _itemImage(item, sourceUrl),
      publishedAt: _date(
        _childText(item, 'pubDate') ?? _qualifiedText(item, 'dc:date'),
      ),
    );
  }

  ParsedFeed _parseAtom(XmlElement root, Uri sourceUrl) {
    final episodes = <ParsedEpisode>[];
    final articles = <ParsedArticle>[];
    final feedImage = _uri(
      _childText(root, 'logo') ?? _childText(root, 'icon'),
      sourceUrl,
    );
    for (final entry
        in root.children
            .whereType<XmlElement>()
            .where((element) => element.name.local.toLowerCase() == 'entry')
            .take(5000)) {
      final enclosureElement = entry.children
          .whereType<XmlElement>()
          .firstWhere(
            (element) =>
                element.name.local.toLowerCase() == 'link' &&
                element.getAttribute('rel')?.toLowerCase() == 'enclosure' &&
                _isAudioType(
                  element.getAttribute('type'),
                  element.getAttribute('href'),
                ),
            orElse: () => XmlElement(const XmlName.parts('missing')),
          );
      final enclosureUrl = _uri(
        enclosureElement.getAttribute('href'),
        sourceUrl,
      );
      final alternate = entry.children.whereType<XmlElement>().firstWhere(
        (element) =>
            element.name.local.toLowerCase() == 'link' &&
            (element.getAttribute('rel') == null ||
                element.getAttribute('rel')?.toLowerCase() == 'alternate'),
        orElse: () => XmlElement(const XmlName.parts('missing')),
      );
      final summary = _atomHtml(entry, 'summary');
      final content = _atomHtml(entry, 'content') ?? summary;
      final title = _plainText(_atomHtml(entry, 'title'));
      final entryImage = _atomEntryImage(entry, sourceUrl);
      if (enclosureUrl != null) {
        episodes.add(
          ParsedEpisode(
            guid: _childText(entry, 'id'),
            title: title ?? 'Untitled episode',
            description: content,
            enclosureUrl: enclosureUrl,
            mimeType: enclosureElement.getAttribute('type'),
            imageUrl: entryImage ?? feedImage,
            publishedAt: _date(
              _childText(entry, 'published') ?? _childText(entry, 'updated'),
            ),
            duration: null,
            fileSize: _positiveInt(enclosureElement.getAttribute('length')),
            explicit: false,
            chaptersUrl: null,
            transcripts: const [],
          ),
        );
      } else {
        articles.add(
          ParsedArticle(
            guid: _childText(entry, 'id'),
            title: title ?? 'Untitled article',
            author: _descendant(entry, 'author') == null
                ? null
                : _childText(_descendant(entry, 'author')!, 'name'),
            summary: _plainText(summary),
            contentHtml: content,
            canonicalUrl: _uri(alternate.getAttribute('href'), sourceUrl),
            imageUrl: entryImage,
            publishedAt: _date(
              _childText(entry, 'published') ?? _childText(entry, 'updated'),
            ),
          ),
        );
      }
    }
    final alternate = root.children.whereType<XmlElement>().firstWhere(
      (element) =>
          element.name.local.toLowerCase() == 'link' &&
          (element.getAttribute('rel') == null ||
              element.getAttribute('rel')?.toLowerCase() == 'alternate'),
      orElse: () => XmlElement(const XmlName.parts('missing')),
    );
    return ParsedFeed(
      title: _plainText(_atomHtml(root, 'title')) ?? sourceUrl.host,
      description: _plainText(_atomHtml(root, 'subtitle')),
      siteUrl: _uri(alternate.getAttribute('href'), sourceUrl),
      imageUrl: feedImage,
      author: _descendant(root, 'author') == null
          ? null
          : _childText(_descendant(root, 'author')!, 'name'),
      kind: _kind(episodes, articles),
      episodes: episodes,
      articles: articles,
    );
  }

  ParsedFeed _parseJson(String source, Uri sourceUrl) {
    try {
      final data = (jsonDecode(source) as Map).cast<String, Object?>();
      final episodes = <ParsedEpisode>[];
      final articles = <ParsedArticle>[];
      for (final raw in (data['items'] as List? ?? const []).take(5000)) {
        try {
          if (raw is! Map) continue;
          final item = raw.cast<String, Object?>();
          final attachments = (item['attachments'] as List? ?? const [])
              .whereType<Map>()
              .map((raw) => raw.cast<String, Object?>())
              .toList();
          final audio = attachments.firstWhere(
            (attachment) => _isAudioType(
              attachment['mime_type'] as String?,
              attachment['url'] as String?,
            ),
            orElse: () => const {},
          );
          final audioUrl = _uri(audio['url'] as String?, sourceUrl);
          final content =
              item['content_html'] as String? ??
              _escapedText(item['content_text'] as String?);
          if (audioUrl != null) {
            episodes.add(
              ParsedEpisode(
                guid: item['id']?.toString(),
                title: item['title'] as String? ?? 'Untitled episode',
                description:
                    content ?? _escapedText(item['summary'] as String?),
                enclosureUrl: audioUrl,
                mimeType: audio['mime_type'] as String?,
                imageUrl: _uri(
                  item['image'] as String? ??
                      item['banner_image'] as String? ??
                      data['icon'] as String?,
                  sourceUrl,
                ),
                publishedAt: _date(item['date_published'] as String?),
                duration: _jsonDuration(audio['duration_in_seconds']),
                fileSize: _positiveNumber(audio['size_in_bytes']),
                explicit: false,
                chaptersUrl: null,
                transcripts: const [],
              ),
            );
          } else {
            articles.add(
              ParsedArticle(
                guid: item['id']?.toString(),
                title: item['title'] as String? ?? 'Untitled article',
                author: _jsonAuthor(item),
                summary: item['summary'] as String?,
                contentHtml: content,
                canonicalUrl: _uri(
                  item['url'] as String? ?? item['external_url'] as String?,
                  sourceUrl,
                ),
                imageUrl: _uri(
                  item['image'] as String? ?? item['banner_image'] as String?,
                  sourceUrl,
                ),
                publishedAt: _date(item['date_published'] as String?),
              ),
            );
          }
        } on Object {
          // One malformed JSON Feed item must not hide every valid item.
        }
      }
      return ParsedFeed(
        title: data['title'] as String? ?? sourceUrl.host,
        description: _plainText(data['description'] as String?),
        siteUrl: _uri(data['home_page_url'] as String?, sourceUrl),
        imageUrl: _uri(
          data['icon'] as String? ?? data['favicon'] as String?,
          sourceUrl,
        ),
        author: _jsonAuthor(data),
        kind: _kind(episodes, articles),
        episodes: episodes,
        articles: articles,
      );
    } on FeedParseException {
      rethrow;
    } on Object {
      throw const FeedParseException('The JSON Feed is malformed.');
    }
  }

  String? _jsonAuthor(Map<String, Object?> data) {
    final author = data['author'];
    if (author is Map) return author['name']?.toString();
    final authors = data['authors'];
    if (authors is List && authors.isNotEmpty && authors.first is Map) {
      return (authors.first as Map)['name']?.toString();
    }
    return null;
  }

  bool _isRssItem(XmlElement element) =>
      element.name.local.toLowerCase() == 'item';

  String? _atomHtml(XmlElement parent, String localName) {
    XmlElement? element;
    final lower = localName.toLowerCase();
    for (final child in parent.children.whereType<XmlElement>()) {
      if (child.name.local.toLowerCase() == lower) {
        element = child;
        break;
      }
    }
    if (element == null) return null;

    final type = (element.getAttribute('type') ?? 'text').trim().toLowerCase();
    if (type == 'text' || type == 'text/plain') {
      return _escapedText(element.innerText);
    }
    if (type == 'html' || type == 'text/html') {
      final value = element.innerText.trim();
      return value.isEmpty ? null : value;
    }
    if (type == 'xhtml' || type == 'application/xhtml+xml') {
      XmlElement? wrapper;
      for (final child in element.children.whereType<XmlElement>()) {
        wrapper = child;
        break;
      }
      if (wrapper == null || wrapper.name.local.toLowerCase() != 'div') {
        return null;
      }
      final value = wrapper.children.map((node) => node.toXmlString()).join();
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }

  String? _escapedText(String? source) {
    if (source == null) return null;
    final value = source.trim();
    if (value.isEmpty) return null;
    return const HtmlEscape(HtmlEscapeMode.element).convert(value);
  }

  _Enclosure? _audioEnclosure(XmlElement item, Uri sourceUrl) {
    for (final element in item.children.whereType<XmlElement>()) {
      final local = element.name.local.toLowerCase();
      if (local != 'enclosure' && local != 'content') continue;
      final url = element.getAttribute('url');
      final type =
          element.getAttribute('type') ?? element.getAttribute('medium');
      if (!_isAudioType(type, url)) continue;
      final parsed = _uri(url, sourceUrl);
      if (parsed != null) {
        return _Enclosure(
          parsed,
          type,
          _positiveInt(
            element.getAttribute('length') ??
                element.getAttribute('fileSize') ??
                '',
          ),
        );
      }
    }
    return null;
  }

  bool _isAudioType(String? type, String? url) {
    final normalized = type?.toLowerCase() ?? '';
    if (normalized.startsWith('audio/') || normalized == 'audio') return true;
    final path = Uri.tryParse(url ?? '')?.path.toLowerCase() ?? '';
    return const [
      '.mp3',
      '.m4a',
      '.aac',
      '.ogg',
      '.opus',
      '.flac',
      '.m3u8',
    ].any(path.endsWith);
  }

  Uri? _rssImage(XmlElement channel, Uri sourceUrl) {
    final itunesImage = _qualifiedChild(
      channel,
      'itunes:image',
    )?.getAttribute('href');
    if (itunesImage != null) return _uri(itunesImage, sourceUrl);
    final image = channel.children.whereType<XmlElement>().firstWhere(
      (element) => element.name.local.toLowerCase() == 'image',
      orElse: () => XmlElement(const XmlName.parts('missing')),
    );
    return _uri(_childText(image, 'url'), sourceUrl);
  }

  Uri? _itemImage(XmlElement item, Uri sourceUrl) {
    XmlElement? first(String qualifiedName) {
      for (final element in item.descendants.whereType<XmlElement>()) {
        if (_isQualified(element, qualifiedName)) return element;
      }
      return null;
    }

    for (final image in [first('media:thumbnail'), first('itunes:image')]) {
      final url = _uri(
        image?.getAttribute('url') ?? image?.getAttribute('href'),
        sourceUrl,
      );
      if (url != null) return url;
    }
    for (final content in item.descendants.whereType<XmlElement>()) {
      if (!_isQualified(content, 'media:content')) continue;
      final raw = content.getAttribute('url') ?? content.getAttribute('href');
      final medium = content.getAttribute('medium')?.trim().toLowerCase();
      final type = content.getAttribute('type')?.trim().toLowerCase();
      if (!_isImageType(type: type, medium: medium, url: raw)) continue;
      final url = _uri(raw, sourceUrl);
      if (url != null) return url;
    }
    for (final enclosure in item.children.whereType<XmlElement>()) {
      if (enclosure.name.local.toLowerCase() != 'enclosure') continue;
      final raw = enclosure.getAttribute('url');
      if (!_isImageType(type: enclosure.getAttribute('type'), url: raw)) {
        continue;
      }
      final url = _uri(raw, sourceUrl);
      if (url != null) return url;
    }
    return null;
  }

  Uri? _atomEntryImage(XmlElement entry, Uri sourceUrl) {
    final mediaImage = _itemImage(entry, sourceUrl);
    if (mediaImage != null) return mediaImage;
    for (final link in entry.children.whereType<XmlElement>()) {
      if (link.name.local.toLowerCase() != 'link') continue;
      final relationships = (link.getAttribute('rel') ?? '')
          .trim()
          .toLowerCase()
          .split(RegExp(r'\s+'));
      if (!relationships.contains('enclosure')) continue;
      final raw = link.getAttribute('href');
      if (!_isImageType(type: link.getAttribute('type'), url: raw)) continue;
      final url = _uri(raw, sourceUrl);
      if (url != null) return url;
    }
    return null;
  }

  bool _isImageType({String? type, String? medium, String? url}) {
    if (medium?.trim().toLowerCase() == 'image' ||
        type?.trim().toLowerCase().startsWith('image/') == true) {
      return true;
    }
    final path = Uri.tryParse(url ?? '')?.path.toLowerCase() ?? '';
    return const [
      '.avif',
      '.gif',
      '.jpeg',
      '.jpg',
      '.png',
      '.webp',
    ].any(path.endsWith);
  }

  FeedKind _kind(List<ParsedEpisode> episodes, List<ParsedArticle> articles) {
    if (episodes.isNotEmpty && articles.isNotEmpty) return FeedKind.hybrid;
    if (episodes.isNotEmpty) return FeedKind.podcast;
    return FeedKind.reader;
  }

  String? _childText(XmlElement parent, String localName) {
    final lower = localName.toLowerCase();
    for (final child in parent.children.whereType<XmlElement>()) {
      if (child.name.local.toLowerCase() == lower) {
        final value = child.innerText.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  String? _qualifiedText(XmlElement parent, String qualifiedName) {
    final child = _qualifiedChild(parent, qualifiedName);
    final value = child?.innerText.trim();
    return value == null || value.isEmpty ? null : value;
  }

  XmlElement? _qualifiedChild(XmlElement parent, String qualifiedName) {
    final lower = qualifiedName.toLowerCase();
    for (final child in parent.children.whereType<XmlElement>()) {
      if (_isQualified(child, lower)) return child;
    }
    return null;
  }

  bool _isQualified(XmlElement element, String qualifiedName) {
    final lower = qualifiedName.toLowerCase();
    if (element.name.qualified.toLowerCase() == lower) return true;
    final parts = lower.split(':');
    if (parts.length != 2 || element.name.local.toLowerCase() != parts[1]) {
      return false;
    }
    final acceptedUris = switch (parts[0]) {
      'itunes' => const {
        'http://www.itunes.com/dtds/podcast-1.0.dtd',
        'https://www.itunes.com/dtds/podcast-1.0.dtd',
      },
      'podcast' => const {'https://podcastindex.org/namespace/1.0'},
      'content' => const {'http://purl.org/rss/1.0/modules/content/'},
      'dc' => const {'http://purl.org/dc/elements/1.1/'},
      'media' => const {'http://search.yahoo.com/mrss/'},
      _ => const <String>{},
    };
    return acceptedUris.contains(element.name.namespaceUri?.toLowerCase());
  }

  int? _positiveInt(String? raw) {
    final value = int.tryParse(raw ?? '');
    return value != null && value > 0 && value <= 0x7FFFFFFFFFFFFFFF
        ? value
        : null;
  }

  int? _positiveNumber(Object? raw) {
    if (raw is! num ||
        !raw.isFinite ||
        raw < 1 ||
        raw > 0x7FFFFFFFFFFFFFFF ||
        raw != raw.truncate()) {
      return null;
    }
    return raw.toInt();
  }

  Duration? _jsonDuration(Object? raw) {
    if (raw is! num || !raw.isFinite || raw < 0 || raw > 31536000) {
      return null;
    }
    return Duration(milliseconds: (raw * 1000).round());
  }

  XmlElement? _descendant(XmlElement parent, String localName) {
    final lower = localName.toLowerCase();
    for (final child in parent.descendants.whereType<XmlElement>()) {
      if (child.name.local.toLowerCase() == lower) return child;
    }
    return null;
  }

  Uri? _uri(String? raw, Uri base) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final resolved = base.resolve(raw.trim());
      if (resolved.scheme == 'http') return resolved.replace(scheme: 'https');
      return resolved.scheme == 'https' ? resolved : null;
    } on FormatException {
      return null;
    }
  }

  DateTime? _date(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.trim();
    final direct = DateTime.tryParse(value);
    if (direct != null) return direct.toUtc();
    try {
      return HttpDate.parse(value).toUtc();
    } on Object {
      return _rfc822Date(value);
    }
  }

  DateTime? _rfc822Date(String value) {
    final match = RegExp(
      r'^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2}|\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4}|[A-Za-z]{1,5})$',
    ).firstMatch(value);
    if (match == null) return null;
    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    const namedOffsets = {
      'ut': 0,
      'utc': 0,
      'gmt': 0,
      'z': 0,
      'est': -5 * 60,
      'edt': -4 * 60,
      'cst': -6 * 60,
      'cdt': -5 * 60,
      'mst': -7 * 60,
      'mdt': -6 * 60,
      'pst': -8 * 60,
      'pdt': -7 * 60,
    };
    final day = int.tryParse(match[1]!);
    final month = months[match[2]!.toLowerCase()];
    var year = int.tryParse(match[3]!);
    final hour = int.tryParse(match[4]!);
    final minute = int.tryParse(match[5]!);
    final second = int.tryParse(match[6] ?? '0');
    if (day == null ||
        month == null ||
        year == null ||
        hour == null ||
        minute == null ||
        second == null ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      return null;
    }
    if (year < 100) year += year < 50 ? 2000 : 1900;
    final zone = match[7]!.toLowerCase();
    int? offsetMinutes = namedOffsets[zone];
    if (offsetMinutes == null &&
        (zone.startsWith('+') || zone.startsWith('-'))) {
      final zoneHour = int.tryParse(zone.substring(1, 3));
      final zoneMinute = int.tryParse(zone.substring(3, 5));
      if (zoneHour == null ||
          zoneMinute == null ||
          zoneHour > 23 ||
          zoneMinute > 59) {
        return null;
      }
      offsetMinutes =
          (zoneHour * 60 + zoneMinute) * (zone.startsWith('-') ? -1 : 1);
    }
    if (offsetMinutes == null) return null;
    final wallClock = DateTime.utc(year, month, day, hour, minute, second);
    if (wallClock.year != year ||
        wallClock.month != month ||
        wallClock.day != day ||
        wallClock.hour != hour ||
        wallClock.minute != minute ||
        wallClock.second != second) {
      return null;
    }
    return wallClock.subtract(Duration(minutes: offsetMinutes));
  }

  Duration? _duration(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.trim();
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return seconds >= 0 && seconds <= 31536000
          ? Duration(seconds: seconds)
          : null;
    }
    final parts = value.split(':').map(int.tryParse).toList();
    if (parts.any((part) => part == null) ||
        parts.length < 2 ||
        parts.length > 3) {
      return null;
    }
    if (parts.any((part) => part! < 0) ||
        parts.last! >= 60 ||
        (parts.length == 3 && parts[1]! >= 60)) {
      return null;
    }
    if (parts.length == 2) {
      if (parts[0]! > 525600) return null;
      return Duration(minutes: parts[0]!, seconds: parts[1]!);
    }
    if (parts[0]! > 8760) return null;
    return Duration(hours: parts[0]!, minutes: parts[1]!, seconds: parts[2]!);
  }

  bool _explicit(String? raw) {
    return const {
      'yes',
      'true',
      'explicit',
    }.contains(raw?.trim().toLowerCase());
  }

  String? _plainText(String? source) {
    if (source == null) return null;
    final value = (html_parser.parseFragment(source).text ?? '').trim();
    return value.isEmpty ? null : value;
  }
}

final class _Enclosure {
  const _Enclosure(this.url, this.type, this.length);
  final Uri url;
  final String? type;
  final int? length;
}
