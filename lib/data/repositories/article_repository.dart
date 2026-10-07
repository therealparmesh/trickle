import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:reader_mode/reader_mode.dart' as reader;

import '../../core/constants.dart';
import '../../core/url_identity.dart';
import '../database/app_database.dart';
import '../network/safe_network_client.dart';
import '../security/private_feed_store.dart';

final class ExtractedArticle {
  const ExtractedArticle({
    required this.html,
    required this.text,
    this.readerFallback = false,
  });

  final String html;
  final String text;
  final bool readerFallback;
}

final class PreviewLease {
  PreviewLease(this._release);

  void Function()? _release;

  void cancel() {
    _release?.call();
    _release = null;
  }
}

final class ArticleRepository {
  ArticleRepository(this._database, this._network, this._privateFeeds);

  final AppDatabase _database;
  final SafeNetworkClient _network;
  final PrivateFeedStore _privateFeeds;
  final Map<(String, String), Future<String?>> _previewRequests = {};
  final Map<String, Set<Object>> _previewInterest = {};
  final Set<String> _previewMisses = {};
  final Queue<Completer<void>> _previewWaiters = Queue();
  int _activePreviewLoads = 0;

  /// Finds and stores a publisher-provided image when the feed omitted one.
  /// Requests are deduplicated and capped at two at a time so a long article
  /// list cannot create an unbounded burst of page fetches.
  PreviewLease retainPreview(String articleId) {
    final token = Object();
    (_previewInterest[articleId] ??= {}).add(token);
    return PreviewLease(() {
      final interest = _previewInterest[articleId];
      interest?.remove(token);
      if (interest?.isEmpty == true) _previewInterest.remove(articleId);
    });
  }

  Future<String?> previewImageById(
    String articleId, {
    PreviewLease? lease,
  }) async {
    final stored = await _database.articleById(articleId);
    if (stored == null) return null;
    return _previewImageForStored(stored, lease: lease);
  }

  Future<String?> _previewImageForStored(
    Article stored, {
    PreviewLease? lease,
  }) async {
    if (stored.imageUrl?.trim().isNotEmpty == true) {
      return stored.imageUrl!.trim();
    }
    final key = (stored.id, stored.canonicalUrl ?? '');
    final existing = _previewRequests[key];
    if (existing != null) return existing;
    final request = _discoverPreviewImage(
      stored,
      lease == null
          ? null
          : () => _previewInterest[stored.id]?.isNotEmpty != true,
    );
    _previewRequests[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_previewRequests[key], request)) {
        final _ = _previewRequests.remove(key);
      }
    }
  }

  Future<String?> _discoverPreviewImage(
    Article article,
    bool Function()? canceled,
  ) async {
    await _acquirePreviewSlot();
    try {
      if (canceled?.call() == true) return null;
      final feed = await _database.feedById(article.feedId);
      if (feed == null) return null;
      final secret = feed.isPrivate
          ? await _privateFeeds.read(feed.credentialRef ?? '')
          : null;
      final baseUrl =
          article.canonicalUrl ??
          secret?.url.toString() ??
          feed.siteUrl ??
          feed.feedUrl;
      final content = (article.readerHtml ?? article.contentHtml)?.trim();
      var image = content == null || content.isEmpty
          ? null
          : await compute(_extractPreviewImage, (
              content,
              baseUrl,
            )).timeout(AppConstants.shortOperationTimeout);
      if (image == null) {
        final pageUrl = article.canonicalUrl;
        if (pageUrl == null || _previewMisses.contains(pageUrl)) return null;
        final uri = Uri.tryParse(pageUrl);
        if (uri == null) return null;
        var headers = const <String, String>{};
        if (secret != null && sameOrigin(uri, secret.url)) {
          headers = secret.headers;
        }
        final document = await _network.get(
          uri,
          headers: headers,
          maxBytes: AppConstants.discoveryLimitBytes,
          totalTimeout: AppConstants.interactiveRequestTimeout,
        );
        if (!_isHtmlDocument(document)) {
          _rememberPreviewMiss(article.canonicalUrl!);
          return null;
        }
        image = await compute(_extractPreviewImage, (
          document.text,
          document.url.toString(),
        )).timeout(AppConstants.shortOperationTimeout);
        if (image == null) {
          _rememberPreviewMiss(article.canonicalUrl!);
          return null;
        }
      }
      if (canceled?.call() == true) return null;
      final updated =
          await (_database.update(_database.articles)..where(
                (row) =>
                    row.id.equals(article.id) &
                    row.canonicalUrl.equalsNullable(article.canonicalUrl) &
                    row.contentHtml.equalsNullable(article.contentHtml) &
                    row.imageUrl.equalsNullable(article.imageUrl),
              ))
              .write(ArticlesCompanion(imageUrl: Value(image)));
      if (updated > 0) return image;
      return (await _database.articleById(article.id))?.imageUrl;
    } on Object {
      // Transient network failures may be retried if this item is shown again.
      return null;
    } finally {
      _releasePreviewSlot();
    }
  }

  void _rememberPreviewMiss(String url) {
    if (!_previewMisses.add(url)) return;
    if (_previewMisses.length > _maxRememberedPreviewMisses) {
      _previewMisses.remove(_previewMisses.first);
    }
  }

  Future<void> _acquirePreviewSlot() async {
    if (_activePreviewLoads < 2) {
      _activePreviewLoads++;
      return;
    }
    final waiter = Completer<void>();
    _previewWaiters.addLast(waiter);
    await waiter.future;
  }

  void _releasePreviewSlot() {
    if (_previewWaiters.isNotEmpty) {
      _previewWaiters.removeFirst().complete();
    } else {
      _activePreviewLoads--;
    }
  }

  Future<ExtractedArticle> load(
    Article article, {
    bool forceRefresh = false,
  }) async {
    final cachedSource = article.readerHtml?.trim();
    if (!forceRefresh &&
        article.readerFetchedAt != null &&
        cachedSource?.isNotEmpty == true) {
      return sanitizeContent(cachedSource!, article.canonicalUrl);
    }
    final rawUrl = article.canonicalUrl;
    if (rawUrl == null) {
      return _feedFallback(article, readerFallback: false);
    }
    late ExtractedArticle extracted;
    try {
      final uri = Uri.parse(rawUrl);
      final feed = await _database.feedById(article.feedId);
      var headers = const <String, String>{};
      if (feed?.isPrivate == true) {
        final secret = await _privateFeeds.read(feed?.credentialRef ?? '');
        if (secret != null && sameOrigin(uri, secret.url)) {
          headers = secret.headers;
        }
      }
      final document = await _network.get(
        uri,
        headers: headers,
        maxBytes: AppConstants.articleLimitBytes,
      );
      if (!_isHtmlDocument(document)) return await _feedFallback(article);
      extracted = await compute(_extractArticle, (
        document.text,
        document.url.toString(),
      )).timeout(AppConstants.shortOperationTimeout);
      if (extracted.text.isEmpty) return await _feedFallback(article);
    } on Object {
      return await _feedFallback(article);
    }
    try {
      await _database.transaction(() async {
        final updated =
            await (_database.update(_database.articles)..where(
                  (row) =>
                      row.id.equals(article.id) &
                      row.canonicalUrl.equals(rawUrl) &
                      row.title.equals(article.title) &
                      row.contentHtml.equalsNullable(article.contentHtml) &
                      row.readerFetchedAt.equalsNullable(
                        article.readerFetchedAt,
                      ),
                ))
                .write(
                  ArticlesCompanion(
                    readerHtml: Value(extracted.html),
                    readerFetchedAt: Value(DateTime.now().toUtc()),
                  ),
                );
        if (updated > 0) {
          await _database.indexSearchItem(
            entityId: article.id,
            kind: 'article',
            title: article.title,
            body: extracted.text,
            feedTitle: (await _database.feedById(article.feedId))?.title ?? '',
          );
        }
      });
    } on Object {
      // Reader content remains usable even when its local cache cannot persist.
    }
    return extracted;
  }

  Future<ExtractedArticle> _feedFallback(
    Article article, {
    bool readerFallback = true,
  }) async {
    final cached = article.readerHtml?.trim();
    final content = cached?.isNotEmpty == true
        ? cached
        : article.contentHtml?.trim();
    final fallback = await sanitizeContent(
      content?.isNotEmpty == true
          ? content!
          : const HtmlEscape(
              HtmlEscapeMode.element,
            ).convert(article.summary ?? ''),
      article.canonicalUrl,
    );
    return ExtractedArticle(
      html: fallback.html,
      text: fallback.text,
      readerFallback: readerFallback,
    );
  }

  Future<ExtractedArticle> sanitizeContent(String source, [String? baseUrl]) {
    return compute(_sanitizeArticleInput, (source, baseUrl));
  }
}

ExtractedArticle _sanitizeArticleInput((String, String?) input) {
  return sanitizeArticleHtml(input.$1, input.$2);
}

ExtractedArticle _extractArticle((String, String) input) {
  final article = reader.parse(input.$1, baseUri: input.$2);
  return sanitizeArticleHtml(article?.content ?? '', input.$2);
}

const _maxRememberedPreviewMisses = 512;

ExtractedArticle sanitizeArticleHtml(String source, [String? baseUrl]) {
  final fragment = html_parser.parseFragment(source);
  final base = baseUrl == null ? null : Uri.tryParse(baseUrl);
  for (final element in fragment.querySelectorAll(
    'script, style, noscript, iframe, object, embed, form, input, button, '
    'svg, canvas, template, [hidden], [aria-hidden="true"]',
  )) {
    element.remove();
  }
  for (final image in fragment.querySelectorAll('img')) {
    final resolved = _resolvedImageUri(image, base);
    if (resolved == null) {
      image.attributes.remove('src');
    } else {
      image.attributes['src'] = resolved.toString();
    }
  }
  for (final element in fragment.querySelectorAll('*').toList()) {
    final tag = element.localName?.toLowerCase() ?? '';
    if (!const {
      'article',
      'main',
      'header',
      'footer',
      'aside',
      'span',
      'time',
      'div',
      'section',
      'p',
      'br',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'strong',
      'b',
      'em',
      'i',
      'blockquote',
      'ul',
      'ol',
      'li',
      'pre',
      'code',
      'a',
      'img',
      'figure',
      'figcaption',
      'table',
      'caption',
      'thead',
      'tbody',
      'tfoot',
      'tr',
      'td',
      'th',
      'dl',
      'dt',
      'dd',
      'hr',
      's',
      'del',
      'ins',
      'u',
      'sub',
      'sup',
      'small',
      'mark',
      'abbr',
      'q',
      'cite',
      'kbd',
      'samp',
      'details',
      'summary',
    }.contains(tag)) {
      _unwrap(element);
      continue;
    }
    final allowed = switch (tag) {
      'a' => {'href'},
      'img' => {'src', 'alt', 'width', 'height'},
      'ol' => {'start', 'type', 'reversed'},
      'li' => {'value'},
      'td' || 'th' => {'colspan', 'rowspan'},
      _ => <String>{},
    };
    final retained = <String, String>{};
    for (final name in {...allowed, 'id', 'dir'}) {
      final value = element.attributes[name];
      if (value != null) retained[name] = value;
    }
    element.attributes.clear();
    element.attributes.addAll(retained);
    if (tag == 'td' || tag == 'th') {
      for (final attribute in const ['colspan', 'rowspan']) {
        final span = int.tryParse(element.attributes[attribute] ?? '');
        // Do not let malformed publisher markup allocate an enormous grid.
        if (span == null || span < 1 || span > 1000) {
          element.attributes.remove(attribute);
        }
      }
    }
    if (tag == 'a') {
      final href = element.attributes['href'];
      if (href != null && !href.startsWith('#')) {
        final resolved = _safeWebUri(href, base);
        if (resolved == null) {
          element.attributes.remove('href');
        } else {
          element.attributes['href'] = resolved.toString();
        }
      }
    }
    if (tag == 'img') {
      for (final dimension in const ['width', 'height']) {
        final value = double.tryParse(element.attributes[dimension] ?? '');
        if (value == null || !value.isFinite || value <= 0 || value > 8192) {
          element.attributes.remove(dimension);
        }
      }
      final src = element.attributes['src'];
      if (src == null) {
        element.remove();
      }
    }
  }
  final html = fragment.outerHtml.trim();
  final text = (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return ExtractedArticle(html: html, text: text);
}

bool _isHtmlDocument(NetworkDocument document) {
  final contentType = document
      .header('content-type')
      ?.split(';')
      .first
      .trim()
      .toLowerCase();
  return contentType == null ||
      contentType.isEmpty ||
      contentType == 'text/html' ||
      contentType == 'application/xhtml+xml';
}

Uri? _resolvedImageUri(Element image, Uri? base) {
  for (final candidate in _imageCandidates(image)) {
    final resolved = _safeWebUri(candidate, base);
    if (resolved != null) return resolved;
  }
  return null;
}

Iterable<String> _imageCandidates(Element image) sync* {
  for (final name in const ['data-src', 'data-original', 'data-lazy-src']) {
    final candidate = image.attributes[name]?.trim();
    if (candidate != null && candidate.isNotEmpty) yield candidate;
  }
  for (final name in const ['data-srcset', 'srcset']) {
    yield* _srcsetUrls(image.attributes[name]).reversed;
  }
  final parent = image.parent;
  if (parent is Element && parent.localName?.toLowerCase() == 'picture') {
    for (final source in parent.querySelectorAll('source')) {
      for (final name in const ['data-srcset', 'srcset']) {
        yield* _srcsetUrls(source.attributes[name]).reversed;
      }
    }
  }
  final source = image.attributes['src']?.trim();
  if (source != null && source.isNotEmpty) yield source;
}

List<String> _srcsetUrls(String? source) {
  if (source == null || source.trim().isEmpty) return const [];
  return source
      .split(',')
      .map((candidate) => candidate.trim().split(RegExp(r'\s+')).first)
      .where((candidate) => candidate.isNotEmpty)
      .toList(growable: false);
}

void _unwrap(Element element) {
  final parent = element.parentNode;
  if (parent == null) return;
  for (final child in element.nodes.toList()) {
    parent.insertBefore(child, element);
  }
  element.remove();
}

Uri? _safeWebUri(String raw, Uri? base) {
  try {
    var uri = base?.resolve(raw) ?? Uri.parse(raw);
    if (uri.scheme == 'http') uri = uri.replace(scheme: 'https');
    return uri.scheme == 'https' && uri.host.isNotEmpty ? uri : null;
  } on FormatException {
    return null;
  }
}

String? _extractPreviewImage((String, String) input) {
  final (source, pageUrl) = input;
  final document = html_parser.parse(source);
  final page = Uri.tryParse(pageUrl);
  if (page == null) return null;
  final baseHref = document.querySelector('base')?.attributes['href'];
  final base = baseHref == null ? page : _safeWebUri(baseHref, page) ?? page;

  const metadataKeys = {
    'og:image:secure_url',
    'og:image',
    'og:image:url',
    'twitter:image',
    'twitter:image:src',
  };
  for (final meta in document.querySelectorAll('meta')) {
    final key = (meta.attributes['property'] ?? meta.attributes['name'])
        ?.trim()
        .toLowerCase();
    if (!metadataKeys.contains(key)) continue;
    final image = _safePreviewUri(meta.attributes['content'], base);
    if (image != null) return image.toString();
  }
  for (final link in document.querySelectorAll('link')) {
    final relationships = (link.attributes['rel'] ?? '').toLowerCase().split(
      RegExp(r'\s+'),
    );
    if (!relationships.contains('image_src')) continue;
    final image = _safePreviewUri(link.attributes['href'], base);
    if (image != null) return image.toString();
  }
  final candidates = <Element>[
    ...document.querySelectorAll('article img'),
    ...document.querySelectorAll('main img'),
    ...document.querySelectorAll('img'),
  ];
  final seen = <Element>{};
  for (final element in candidates) {
    if (!seen.add(element)) continue;
    final width = int.tryParse(element.attributes['width'] ?? '');
    final height = int.tryParse(element.attributes['height'] ?? '');
    if ((width != null && width < 80) || (height != null && height < 80)) {
      continue;
    }
    for (final candidate in _imageCandidates(element)) {
      final image = _safePreviewUri(candidate, base);
      if (image != null) return image.toString();
    }
  }
  return null;
}

Uri? _safePreviewUri(String? raw, Uri base) {
  if (raw == null || raw.trim().isEmpty) return null;
  final uri = _safeWebUri(raw.trim(), base);
  if (uri == null || uri.path.toLowerCase().endsWith('.svg')) return null;
  return uri;
}
