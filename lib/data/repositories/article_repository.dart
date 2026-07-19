import 'dart:async';
import 'dart:collection';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

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
  final Map<String, Future<String?>> _previewRequests = {};
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

  Future<String?> previewImage(Article article, {PreviewLease? lease}) async {
    if (article.imageUrl?.trim().isNotEmpty == true) {
      return article.imageUrl!.trim();
    }
    final stored = await _database.articleById(article.id);
    if (stored == null) return null;
    if (stored.imageUrl?.trim().isNotEmpty == true) {
      return stored.imageUrl!.trim();
    }
    if (stored.canonicalUrl?.trim().isNotEmpty != true ||
        _previewMisses.contains(article.id)) {
      return null;
    }
    final existing = _previewRequests[article.id];
    if (existing != null) return existing;
    final request = _discoverPreviewImage(
      stored,
      lease == null
          ? null
          : () => _previewInterest[article.id]?.isNotEmpty != true,
    );
    _previewRequests[article.id] = request;
    try {
      return await request;
    } finally {
      if (identical(_previewRequests[article.id], request)) {
        _previewRequests.remove(article.id);
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
      final uri = Uri.tryParse(article.canonicalUrl!);
      if (uri == null) {
        _rememberPreviewMiss(article.id);
        return null;
      }
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
        maxBytes: AppConstants.discoveryLimitBytes,
        totalTimeout: const Duration(seconds: 8),
      );
      if (!_isHtmlDocument(document)) {
        _rememberPreviewMiss(article.id);
        return null;
      }
      final image = await compute(_extractPreviewImage, (
        document.text,
        document.url.toString(),
      )).timeout(const Duration(seconds: 2));
      if (image == null) {
        _rememberPreviewMiss(article.id);
        return null;
      }
      if (canceled?.call() == true) return null;
      final missingImage = article.imageUrl;
      final updated =
          await (_database.update(_database.articles)..where(
                (row) =>
                    row.id.equals(article.id) &
                    (missingImage == null
                        ? row.imageUrl.isNull()
                        : row.imageUrl.equals(missingImage)),
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

  void _rememberPreviewMiss(String articleId) {
    if (!_previewMisses.add(articleId)) return;
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
    final cachedSource = article.contentHtml?.trim();
    if (!forceRefresh && cachedSource?.isNotEmpty == true) {
      final cached = await sanitizeContent(cachedSource!, article.canonicalUrl);
      if (cached.text.length >= _completeArticleTextLength) return cached;
    }
    final rawUrl = article.canonicalUrl;
    if (rawUrl == null) {
      return _feedFallback(article);
    }
    late ExtractedArticle extracted;
    String feedTitle = '';
    try {
      final uri = Uri.parse(rawUrl);
      final feed = await _database.feedById(article.feedId);
      feedTitle = feed?.title ?? '';
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
      if (!_isHtmlDocument(document)) return _feedFallback(article);
      extracted = await compute(_extractArticle, (
        document.text,
        document.url.toString(),
      )).timeout(const Duration(seconds: 3));
      if (extracted.text.isEmpty) return _feedFallback(article);
    } on Object {
      return _feedFallback(article);
    }
    try {
      final updated =
          await (_database.update(_database.articles)
                ..where((row) => row.id.equals(article.id)))
              .write(ArticlesCompanion(contentHtml: Value(extracted.html)));
      if (updated > 0) {
        await _database.indexSearchItem(
          entityId: article.id,
          kind: 'article',
          title: article.title,
          body: extracted.text,
          feedTitle: feedTitle,
        );
      }
    } on Object {
      // Reader content remains usable even when its local cache cannot persist.
    }
    return extracted;
  }

  Future<ExtractedArticle> _feedFallback(Article article) async {
    final fallback = await sanitizeContent(
      article.contentHtml ?? article.summary ?? '',
      article.canonicalUrl,
    );
    return ExtractedArticle(
      html: fallback.html,
      text: fallback.text,
      readerFallback: true,
    );
  }

  Future<ExtractedArticle> sanitizeContent(String source, [String? baseUrl]) {
    return compute(_sanitizeArticleInput, (source, baseUrl));
  }
}

ExtractedArticle _sanitizeArticleInput((String, String?) input) {
  return _sanitizeArticle(input.$1, input.$2);
}

ExtractedArticle _extractArticle((String, String) input) {
  final (source, baseUrl) = input;
  final document = html_parser.parse(source);
  final page = Uri.tryParse(baseUrl);
  final baseHref = document.querySelector('base')?.attributes['href'];
  final resolvedBase = baseHref == null || page == null
      ? baseUrl
      : (_safeWebUri(baseHref, page) ?? page).toString();
  _removeReaderJunk(document.querySelectorAll('*'));
  final articles = document.querySelectorAll('article')
    ..sort((a, b) => _articleScore(b).compareTo(_articleScore(a)));
  final bestArticle = articles.where(_looksLikeArticleBody).firstOrNull;
  final main = document.querySelector('main');
  Element? candidate =
      bestArticle ?? (main == null ? null : _articleBody(main));
  if (candidate == null) {
    final candidates = document.querySelectorAll('div, section');
    candidates.sort((a, b) => _articleScore(b).compareTo(_articleScore(a)));
    candidate = candidates.isEmpty
        ? document.body
        : _articleBody(candidates.first);
  }
  return _sanitizeArticle(
    candidate?.innerHtml ?? document.body?.innerHtml ?? '',
    resolvedBase,
  );
}

Element _articleBody(Element root) {
  final paragraphCount = root.querySelectorAll('p').length;
  if (paragraphCount < 2) return root;
  final containers = root
      .querySelectorAll('div, section')
      .where(
        (element) => element.querySelectorAll('p').length == paragraphCount,
      );
  var body = containers.fold(
    root,
    (smallest, element) =>
        element.text.length < smallest.text.length ? element : smallest,
  );
  if (identical(body, root)) return root;
  var ancestor = body.parent;
  while (ancestor is Element && !identical(ancestor, root)) {
    if (ancestor.querySelectorAll('p').length != paragraphCount ||
        ancestor.querySelector('h1') != null) {
      break;
    }
    final addsContent = ancestor.text.trim().length > body.text.trim().length;
    body = ancestor;
    if (addsContent) break;
    ancestor = body.parent;
  }
  return body;
}

int _articleScore(Element element) {
  final text = element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length + element.querySelectorAll('p').length * 120;
}

bool _looksLikeArticleBody(Element element) {
  if (element.querySelectorAll('p').length >= 2) return true;
  return element.text.replaceAll(RegExp(r'\s+'), ' ').trim().length >=
      _completeArticleTextLength;
}

const _completeArticleTextLength = 400;
const _maxRememberedPreviewMisses = 512;

ExtractedArticle _sanitizeArticle(String source, [String? baseUrl]) {
  final fragment = html_parser.parseFragment(source);
  final base = baseUrl == null ? null : Uri.tryParse(baseUrl);
  _removeReaderJunk(fragment.querySelectorAll('*'));
  _separateAdjacentTextElements(fragment);
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
    }.contains(tag)) {
      _unwrap(element);
      continue;
    }
    final allowed = switch (tag) {
      'a' => {'href'},
      'img' => {'src', 'alt', 'width', 'height'},
      'ol' => {'start'},
      _ => <String>{},
    };
    final retained = <String, String>{};
    for (final name in allowed) {
      final value = element.attributes[name];
      if (value != null) retained[name] = value;
    }
    element.attributes.clear();
    element.attributes.addAll(retained);
    if (tag == 'a') {
      final href = element.attributes['href'];
      if (href != null) {
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

const _discardedReaderTags = {
  'script',
  'style',
  'noscript',
  'iframe',
  'object',
  'form',
  'nav',
  'header',
  'footer',
  'aside',
};

const _discardedReaderIdentifiers = {
  'ad',
  'ad-banner',
  'ad-block',
  'ad-container',
  'ad-slot',
  'ad-unit',
  'ad-wrapper',
  'ads',
  'advert',
  'advertisement',
  'advertising',
  'comment-list',
  'comment-section',
  'comments',
  'comments-area',
  'comments-section',
  'comment',
  'promo',
  'share',
  'share-bar',
  'share-buttons',
  'sharing',
  'social',
  'social-share',
  'social-sharing',
};

void _removeReaderJunk(Iterable<Element> elements) {
  for (final element in elements.toList()) {
    final tag = element.localName?.toLowerCase() ?? '';
    if (_discardedReaderTags.contains(tag) ||
        _hasDiscardedReaderIdentifier(element)) {
      element.remove();
    }
  }
}

bool _hasDiscardedReaderIdentifier(Element element) {
  final identifiers = [
    element.id,
    ...(element.attributes['class'] ?? '').split(RegExp(r'\s+')),
  ];
  return identifiers
      .map((identifier) => identifier.trim().toLowerCase())
      .any(_discardedReaderIdentifiers.contains);
}

void _unwrap(Element element) {
  final parent = element.parentNode;
  if (parent == null) return;
  for (final child in element.nodes.toList()) {
    parent.insertBefore(child, element);
  }
  element.remove();
}

void _separateAdjacentTextElements(Node root) {
  final nodes = root.nodes.toList();
  for (final node in nodes) {
    if (node is Element) _separateAdjacentTextElements(node);
  }
  for (var index = 1; index < nodes.length; index++) {
    final previous = nodes[index - 1];
    final next = nodes[index];
    if (previous is Element &&
        next is Element &&
        previous.text.trim().isNotEmpty &&
        next.text.trim().isNotEmpty) {
      root.insertBefore(Text(' '), next);
    }
  }
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
