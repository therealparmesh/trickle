import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_providers.dart';
import '../../app/theme.dart';
import '../../core/constants.dart';
import '../../core/url_identity.dart';
import '../../data/security/private_feed_store.dart';
import 'common.dart';

final class ArticleContent extends StatefulWidget {
  const ArticleContent({
    required this.html,
    required this.scale,
    this.privateSecret,
    this.allowRemoteImages = true,
    this.leadingTitleToOmit,
    super.key,
  });

  final String html;
  final double scale;
  final PrivateFeedSecret? privateSecret;
  final bool allowRemoteImages;
  final String? leadingTitleToOmit;

  @override
  State<ArticleContent> createState() => _ArticleContentState();
}

class _ArticleContentState extends State<ArticleContent> {
  static const _blockPageSize = 200;
  static const _sourcePageSize = 32 * 1024;
  final List<TapGestureRecognizer> _recognizers = [];
  List<String>? _fragments;
  List<List<dom.Node>?> _parsedFragments = const [];
  int _blockLimit = _blockPageSize;
  int _sourceLimit = _sourcePageSize;
  int _parseGeneration = 0;
  bool _preparationFailed = false;

  @override
  void initState() {
    super.initState();
    _prepareHtml();
  }

  @override
  void didUpdateWidget(ArticleContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _blockLimit = _blockPageSize;
      _sourceLimit = _sourcePageSize;
      _prepareHtml();
    }
  }

  void _prepareHtml() {
    final generation = ++_parseGeneration;
    _preparationFailed = false;
    _fragments = null;
    _parsedFragments = const [];
    final source = widget.html;
    if (source.length < 32 * 1024) {
      try {
        _installFragments(_splitArticleBlocks(source));
      } on Object {
        _preparationFailed = true;
        _installFragments(const []);
      }
      return;
    }
    compute(_splitArticleBlocks, source).then(
      (fragments) {
        if (!mounted || generation != _parseGeneration) return;
        setState(() => _installFragments(fragments));
      },
      onError: (Object _, StackTrace _) {
        if (!mounted || generation != _parseGeneration) return;
        setState(() {
          _preparationFailed = true;
          _installFragments(const []);
        });
      },
    );
  }

  void _installFragments(List<String> fragments) {
    _fragments = fragments;
    _parsedFragments = List<List<dom.Node>?>.filled(fragments.length, null);
  }

  @override
  Widget build(BuildContext context) {
    if (_recognizers.isNotEmpty) {
      final staleRecognizers = List<TapGestureRecognizer>.of(_recognizers);
      _recognizers.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final recognizer in staleRecognizers) {
          recognizer.dispose();
        }
      });
    }
    if (_preparationFailed) {
      return InlineErrorView(
        'The article content couldn’t be rendered.',
        title: 'Couldn’t prepare article',
        onRetry: () => setState(_prepareHtml),
      );
    }
    if (_fragments == null) {
      return const LoadingView(label: 'Preparing article');
    }
    final blocks = <Widget>[];
    final visibleFragmentCount = _visibleFragmentCount();
    final iterator = _allBlocks(visibleFragmentCount).iterator;
    while (blocks.length < _blockLimit && iterator.moveNext()) {
      blocks.add(iterator.current);
    }
    if (blocks.isEmpty) {
      return const Text('No readable content was supplied.');
    }
    final recognizersBeforeProbe = _recognizers.length;
    final mayHaveMore =
        iterator.moveNext() || visibleFragmentCount < _fragments!.length;
    while (_recognizers.length > recognizersBeforeProbe) {
      _recognizers.removeLast().dispose();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...blocks,
        if (mayHaveMore)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _blockLimit += _blockPageSize;
                _sourceLimit += _sourcePageSize;
              }),
              icon: const Icon(Icons.expand_more_rounded),
              label: const Text('Show more'),
            ),
          ),
      ],
    );
  }

  int _visibleFragmentCount() {
    final fragments = _fragments!;
    var count = 0;
    var sourceLength = 0;
    while (count < fragments.length) {
      final nextLength = fragments[count].length;
      if (count > 0 && sourceLength + nextLength > _sourceLimit) break;
      sourceLength += nextLength;
      count++;
    }
    return count;
  }

  Iterable<Widget> _allBlocks(int fragmentCount) sync* {
    final fragments = _fragments!;
    final titleToOmit = _normalizedHeading(widget.leadingTitleToOmit);
    var omittedHeading = false;
    var sawBodyContent = false;
    for (var index = 0; index < fragmentCount; index++) {
      final nodes = _parsedFragments[index] ??= html_parser
          .parseFragment(fragments[index])
          .nodes
          .toList();
      for (final node in nodes) {
        if (node is dom.Element && _isHeading(node)) {
          final heading = _normalizedHeading(node.text);
          if (heading == null) continue;
          if (!omittedHeading &&
              !sawBodyContent &&
              titleToOmit != null &&
              _headingMatchesTitle(heading, titleToOmit)) {
            omittedHeading = true;
            continue;
          }
        }
        if (_isBodyNode(node)) sawBodyContent = true;
        yield* _block(node);
      }
    }
  }

  bool _isHeading(dom.Element element) => switch (element.localName) {
    'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' => true,
    _ => false,
  };

  bool _isBodyNode(dom.Node node) {
    if (node is! dom.Element) return false;
    if (node.querySelector('img') != null) return true;
    return switch (node.localName) {
      'p' || 'blockquote' || 'ul' || 'ol' || 'pre' || 'img' => true,
      'h1' ||
      'h2' ||
      'h3' ||
      'h4' ||
      'h5' ||
      'h6' => node.text.trim().isNotEmpty,
      _ => false,
    };
  }

  String? _normalizedHeading(String? value) {
    final normalized = value?.trim().toLowerCase().replaceAll(
      _inlineWhitespacePattern,
      ' ',
    );
    return normalized?.isEmpty == true ? null : normalized;
  }

  bool _headingMatchesTitle(String heading, String title) {
    if (heading == title) return true;
    if (!title.startsWith(heading)) return false;
    final suffix = title.substring(heading.length).trimLeft();
    return suffix.startsWith(':') ||
        suffix.startsWith('—') ||
        suffix.startsWith('–') ||
        suffix.startsWith('|') ||
        suffix.startsWith('- ');
  }

  Iterable<Widget> _block(dom.Node node) sync* {
    if (node is dom.Text) {
      if (node.data.trim().isNotEmpty) yield _paragraph([node]);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName?.toLowerCase();
    switch (tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.tryParse(tag!.substring(1)) ?? 2;
        final continuation = _isFragmentContinuation(node);
        final continues = _fragmentContinues(node);
        yield Padding(
          padding: EdgeInsets.only(
            top: continuation ? 0 : (level <= 2 ? 24 : 18),
            bottom: continues ? 0 : 8,
          ),
          child: Semantics(
            header: !continuation,
            child: Text.rich(
              _inline(node.nodes),
              style: TextStyle(
                color: AppConstants.primaryText,
                fontFamily: TrickleFonts.display,
                fontSize: (30 - level * 2).clamp(19, 28) * widget.scale,
                height: 1.16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
              ),
            ),
          ),
        );
      case 'p':
        if (node.text.trim().isNotEmpty) {
          yield _paragraph(node.nodes, continues: _fragmentContinues(node));
        }
        yield* _images(node);
      case 'blockquote':
        final continuation = _isFragmentContinuation(node);
        final continues = _fragmentContinues(node);
        yield Container(
          margin: EdgeInsets.only(
            top: continuation ? 0 : 10,
            bottom: continues ? 0 : 10,
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            continuation ? 0 : 12,
            14,
            continues ? 0 : 12,
          ),
          decoration: const BoxDecoration(
            color: AppConstants.elevated,
            border: Border(
              left: BorderSide(color: AppConstants.magenta, width: 3),
            ),
          ),
          child: _textAndImages(
            node,
            style: _bodyStyle().copyWith(
              color: AppConstants.secondaryText,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case 'pre':
        final continuation = _isFragmentContinuation(node);
        final continues = _fragmentContinues(node);
        yield Container(
          margin: EdgeInsets.only(
            top: continuation ? 0 : 10,
            bottom: continues ? 0 : 10,
          ),
          padding: EdgeInsets.fromLTRB(
            14,
            continuation ? 0 : 14,
            14,
            continues ? 0 : 14,
          ),
          decoration: BoxDecoration(
            color: AppConstants.elevated,
            borderRadius: BorderRadius.vertical(
              top: continuation ? Radius.zero : const Radius.circular(8),
              bottom: continues ? Radius.zero : const Radius.circular(8),
            ),
            border: Border(
              left: const BorderSide(color: AppConstants.hairline),
              right: const BorderSide(color: AppConstants.hairline),
              top: continuation
                  ? BorderSide.none
                  : const BorderSide(color: AppConstants.hairline),
              bottom: continues
                  ? BorderSide.none
                  : const BorderSide(color: AppConstants.hairline),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              node.text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14 * widget.scale,
                height: 1.5,
                color: AppConstants.acid,
              ),
            ),
          ),
        );
      case 'ul' || 'ol':
        final ordered = tag == 'ol';
        final items = node.children
            .where((element) => element.localName == 'li')
            .toList();
        final markerStyle = _bodyStyle().copyWith(color: AppConstants.cyan);
        final firstIndex = ordered
            ? int.tryParse(node.attributes['start'] ?? '') ?? 1
            : 1;
        final markerWidth = ordered
            ? _orderedMarkerWidth(
                int.tryParse(node.attributes[_listFirstIndexAttribute] ?? '') ??
                    firstIndex,
                int.tryParse(node.attributes[_listLastIndexAttribute] ?? '') ??
                    firstIndex + items.length - 1,
                markerStyle,
              )
            : 28.0;
        var index = firstIndex;
        for (final item in items) {
          final continuation =
              item.attributes[_listItemContinuationAttribute] == 'true';
          yield Padding(
            padding: EdgeInsets.only(
              bottom: item.attributes[_listItemContinuesAttribute] == 'true'
                  ? 0
                  : 8,
              left: 5,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: markerWidth,
                  child: Text(
                    continuation ? '' : (ordered ? '$index.' : '•'),
                    style: markerStyle,
                  ),
                ),
                Expanded(child: _textAndImages(item, style: _bodyStyle())),
              ],
            ),
          );
          if (!continuation) index++;
        }
      case 'img':
        yield* _images(node);
      case 'figcaption':
        yield Padding(
          padding: EdgeInsets.only(
            top: _isFragmentContinuation(node) ? 0 : 5,
            bottom: _fragmentContinues(node) ? 0 : 12,
          ),
          child: Text.rich(
            _inline(node.nodes),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppConstants.secondaryText,
              fontSize: 13 * widget.scale,
              height: 1.4,
            ),
          ),
        );
      case 'a':
        if (node.text.trim().isNotEmpty) {
          yield _paragraph([node], continues: _fragmentContinues(node));
        }
        yield* _images(node);
      default:
        if (node.text.trim().isNotEmpty) {
          yield _paragraph([node], continues: _fragmentContinues(node));
        }
    }
  }

  bool _isFragmentContinuation(dom.Element node) =>
      node.attributes[_fragmentContinuationAttribute] == 'true';

  bool _fragmentContinues(dom.Element node) =>
      node.attributes[_fragmentContinuesAttribute] == 'true';

  double _orderedMarkerWidth(int firstIndex, int lastIndex, TextStyle style) {
    var widest = 0.0;
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final labels = _orderedMarkerLabels(firstIndex, lastIndex);
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: '$label.', style: style),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return math.max(28, widest + 12);
  }

  Iterable<Widget> _images(dom.Element root) sync* {
    final images = root.localName?.toLowerCase() == 'img'
        ? [root]
        : root.querySelectorAll('img');
    for (final image in images) {
      final source = image.attributes['src'];
      if (source == null || source.trim().isEmpty) continue;
      final link = _imageLink(image, root);
      yield _ArticleImage(
        source: source,
        alt: image.attributes['alt']?.trim(),
        declaredWidth: _imageDimension(image.attributes['width']),
        declaredHeight: _imageDimension(image.attributes['height']),
        secret: widget.privateSecret,
        allowed: widget.allowRemoteImages,
        onTap: link == null ? null : () => _open(link),
      );
    }
  }

  String? _imageLink(dom.Element image, dom.Element boundary) {
    dom.Node? current = image.parentNode;
    while (current != null) {
      if (current is dom.Element && current.localName == 'a') {
        return _safeExternalUrl(current.attributes['href']);
      }
      if (identical(current, boundary)) break;
      current = current.parentNode;
    }
    return null;
  }

  Widget _textAndImages(dom.Element root, {required TextStyle style}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (root.text.trim().isNotEmpty)
          Text.rich(_inline(root.nodes), style: style),
        ..._images(root),
      ],
    );
  }

  Widget _paragraph(List<dom.Node> nodes, {bool continues = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: continues ? 0 : 16),
      child: Text.rich(_inline(nodes), style: _bodyStyle()),
    );
  }

  TextStyle _bodyStyle() => TextStyle(
    fontSize: 18 * widget.scale,
    height: 1.68,
    color: AppConstants.primaryText,
  );

  TextSpan _inline(List<dom.Node> nodes, [TextStyle? inherited]) {
    final whitespace = _InlineWhitespace();
    return TextSpan(
      style: inherited,
      children: [for (final node in nodes) _span(node, inherited, whitespace)],
    );
  }

  InlineSpan _span(
    dom.Node node,
    TextStyle? inherited,
    _InlineWhitespace whitespace,
  ) {
    if (node is dom.Text) {
      return TextSpan(text: whitespace.normalize(node.data), style: inherited);
    }
    if (node is! dom.Element) return const TextSpan();
    final tag = node.localName?.toLowerCase();
    if (tag == 'br') return TextSpan(text: whitespace.lineBreak());
    if (tag == 'img') return const TextSpan();
    var style = inherited;
    if (tag == 'strong' || tag == 'b') {
      style = (style ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w800,
      );
    } else if (tag == 'em' || tag == 'i') {
      style = (style ?? const TextStyle()).copyWith(
        fontStyle: FontStyle.italic,
      );
    } else if (tag == 'code') {
      style = (style ?? const TextStyle()).copyWith(
        fontFamily: 'monospace',
        color: AppConstants.acid,
        backgroundColor: AppConstants.elevated,
      );
    }
    TapGestureRecognizer? recognizer;
    final href = tag == 'a' ? _safeExternalUrl(node.attributes['href']) : null;
    if (href != null && node.text.trim().isNotEmpty) {
      recognizer = TapGestureRecognizer()..onTap = () => _open(href);
      _recognizers.add(recognizer);
      style = (style ?? const TextStyle()).copyWith(
        color: AppConstants.cyan,
        decoration: TextDecoration.underline,
        decorationColor: AppConstants.cyan,
      );
    }
    return TextSpan(
      style: style,
      recognizer: recognizer,
      children: [
        for (final child in node.nodes) _span(child, style, whitespace),
      ],
    );
  }

  Future<void> _open(String rawUrl) async {
    var opened = false;
    try {
      final safeUrl = _safeExternalUrl(rawUrl);
      final uri = safeUrl == null ? null : Uri.parse(safeUrl);
      opened =
          uri != null &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      opened = false;
    }
    if (!opened && mounted) {
      showMessageSnackBar(context, 'Couldn’t open that link.');
    }
  }

  @override
  void dispose() {
    _parseGeneration++;
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }
}

final class _InlineWhitespace {
  bool _canSeparate = false;
  bool _pendingSpace = false;

  String normalize(String source) {
    final collapsed = source.replaceAll(_inlineWhitespacePattern, ' ');
    final content = collapsed.trim();
    if (content.isEmpty) {
      if (_canSeparate) _pendingSpace = true;
      return '';
    }
    final hasLeadingSpace = collapsed.startsWith(' ');
    final result = _canSeparate && (_pendingSpace || hasLeadingSpace)
        ? ' $content'
        : content;
    _canSeparate = true;
    _pendingSpace = collapsed.endsWith(' ');
    return result;
  }

  String lineBreak() {
    _canSeparate = false;
    _pendingSpace = false;
    return '\n';
  }
}

final _inlineWhitespacePattern = RegExp(r'\s+');

const _maxArticleFragmentLength = 8 * 1024;
const _fragmentMetadataReserve = 256;
const _fragmentPayloadLength =
    _maxArticleFragmentLength - _fragmentMetadataReserve;
const _maxListItemsPerFragment = 40;
const _fragmentContinuationAttribute = 'data-trickle-fragment-continuation';
const _fragmentContinuesAttribute = 'data-trickle-fragment-continues';
const _listFirstIndexAttribute = 'data-trickle-list-first';
const _listLastIndexAttribute = 'data-trickle-list-last';
const _listItemContinuationAttribute = 'data-trickle-item-continuation';
const _listItemContinuesAttribute = 'data-trickle-item-continues';

typedef _ListItemPart = ({
  dom.Element element,
  int itemOffset,
  bool continuation,
});

List<String> _splitArticleBlocks(String source) {
  final nodes = html_parser.parseFragment(source).nodes;
  final fragments = <String>[];

  void collect(dom.Node node) {
    if (node is dom.Text) {
      if (node.data.trim().isNotEmpty) {
        final escaped = const HtmlEscape(
          HtmlEscapeMode.element,
        ).convert(node.data);
        if (escaped.length <= _maxArticleFragmentLength) {
          _addBoundedFragment(fragments, escaped);
        } else {
          final paragraph = dom.Element.tag('p')..append(node.clone(true));
          _addSplitFragments(
            fragments,
            _splitElement(paragraph, _fragmentPayloadLength),
          );
        }
      }
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName?.toLowerCase();
    if (tag == 'div' || tag == 'section' || tag == 'figure') {
      for (final child in node.nodes) {
        collect(child);
      }
      return;
    }
    if (tag == 'p' && node.outerHtml.length > _maxArticleFragmentLength) {
      _addSplitFragments(
        fragments,
        _splitElement(node, _fragmentPayloadLength),
      );
      return;
    }
    if (tag == 'ol' || tag == 'ul') {
      for (final fragment in _splitList(node)) {
        _addBoundedFragment(fragments, fragment);
      }
      return;
    }
    if (node.outerHtml.length > _maxArticleFragmentLength) {
      _addSplitFragments(
        fragments,
        _splitElement(node, _fragmentPayloadLength),
      );
      return;
    }
    _addBoundedFragment(fragments, node.outerHtml);
  }

  for (final node in nodes) {
    collect(node);
  }
  return fragments;
}

void _addSplitFragments(List<String> target, List<dom.Element> parts) {
  for (var index = 0; index < parts.length; index++) {
    if (index > 0) {
      parts[index].attributes[_fragmentContinuationAttribute] = 'true';
    }
    if (index < parts.length - 1) {
      parts[index].attributes[_fragmentContinuesAttribute] = 'true';
    }
    _addBoundedFragment(target, parts[index].outerHtml);
  }
}

void _addBoundedFragment(List<String> target, String fragment) {
  if (fragment.length > _maxArticleFragmentLength) {
    throw StateError('Article fragment exceeded its render limit.');
  }
  target.add(fragment);
}

List<String> _splitList(dom.Element source) {
  final items = source.children
      .where((element) => element.localName == 'li')
      .toList();
  if (items.isEmpty ||
      (items.length <= _maxListItemsPerFragment &&
          source.outerHtml.length <= _maxArticleFragmentLength)) {
    return [source.outerHtml];
  }

  final ordered = source.localName == 'ol';
  final firstIndex = ordered
      ? int.tryParse(source.attributes['start'] ?? '') ?? 1
      : 1;
  final lastIndex = firstIndex + items.length - 1;
  final emptyChunk = _newListChunk(
    source,
    ordered: ordered,
    start: firstIndex,
    firstIndex: firstIndex,
    lastIndex: lastIndex,
  );
  final itemLimit = math
      .max(
        64,
        _maxArticleFragmentLength -
            emptyChunk.outerHtml.length -
            _fragmentMetadataReserve,
      )
      .toInt();
  final parts = <_ListItemPart>[];
  for (var itemOffset = 0; itemOffset < items.length; itemOffset++) {
    final item = items[itemOffset];
    final itemParts = item.outerHtml.length > itemLimit
        ? _splitElement(item, itemLimit)
        : [item.clone(true)];
    for (var partIndex = 0; partIndex < itemParts.length; partIndex++) {
      final continuation = partIndex > 0;
      if (continuation) {
        itemParts[partIndex].attributes[_listItemContinuationAttribute] =
            'true';
      }
      if (partIndex < itemParts.length - 1) {
        itemParts[partIndex].attributes[_listItemContinuesAttribute] = 'true';
      }
      parts.add((
        element: itemParts[partIndex],
        itemOffset: itemOffset,
        continuation: continuation,
      ));
    }
  }

  final result = <String>[];
  var chunk = _newListChunk(
    source,
    ordered: ordered,
    start: _listPartStart(firstIndex, parts.first),
    firstIndex: firstIndex,
    lastIndex: lastIndex,
  );

  for (final part in parts) {
    chunk.append(part.element);
    final tooLarge = chunk.outerHtml.length > _maxArticleFragmentLength;
    final tooMany = chunk.children.length > _maxListItemsPerFragment;
    if ((tooLarge || tooMany) && chunk.children.length > 1) {
      part.element.remove();
      result.add(chunk.outerHtml);
      chunk = _newListChunk(
        source,
        ordered: ordered,
        start: _listPartStart(firstIndex, part),
        firstIndex: firstIndex,
        lastIndex: lastIndex,
      )..append(part.element);
    }
  }
  if (chunk.children.isNotEmpty) result.add(chunk.outerHtml);
  return result;
}

int _listPartStart(int firstIndex, _ListItemPart part) =>
    firstIndex + part.itemOffset + (part.continuation ? 1 : 0);

dom.Element _newListChunk(
  dom.Element source, {
  required bool ordered,
  required int start,
  required int firstIndex,
  required int lastIndex,
}) {
  final chunk = source.clone(false);
  if (ordered) {
    chunk.attributes['start'] = '$start';
    chunk.attributes[_listFirstIndexAttribute] = '$firstIndex';
    chunk.attributes[_listLastIndexAttribute] = '$lastIndex';
  }
  return chunk;
}

List<dom.Element> _splitElement(dom.Element source, int maxLength) {
  final boundedSource = _boundElementAttributes(source, maxLength);
  if (boundedSource == null) return const [];
  final chunks = <dom.Element>[];
  var chunk = boundedSource.clone(false);
  final emptyLength = chunk.outerHtml.length;
  final childLimit = math.max(64, maxLength - emptyLength).toInt();

  for (final child in boundedSource.nodes) {
    for (final part in _splitNode(child, childLimit)) {
      chunk.append(part);
      if (chunk.outerHtml.length > maxLength && chunk.nodes.length > 1) {
        part.remove();
        chunks.add(chunk);
        chunk = boundedSource.clone(false)..append(part);
      }
    }
  }
  if (chunk.nodes.isNotEmpty) chunks.add(chunk);
  return chunks.isEmpty ? [boundedSource.clone(false)] : chunks;
}

List<dom.Node> _splitNode(dom.Node source, int maxLength) {
  dom.Node boundedSource = source;
  if (source is dom.Element) {
    final bounded = _boundElementAttributes(source, maxLength);
    if (bounded == null) return const [];
    boundedSource = bounded;
  }
  if (_serializedNodeLength(boundedSource) <= maxLength) {
    return [boundedSource.clone(true)];
  }
  if (boundedSource is dom.Text) {
    return _splitText(boundedSource.data, maxLength);
  }
  if (boundedSource is! dom.Element || boundedSource.nodes.isEmpty) {
    return [boundedSource.clone(true)];
  }

  final chunks = <dom.Node>[];
  var chunk = boundedSource.clone(false);
  final emptyLength = chunk.outerHtml.length;
  final childLimit = math.max(64, maxLength - emptyLength).toInt();
  for (final child in boundedSource.nodes) {
    for (final part in _splitNode(child, childLimit)) {
      chunk.append(part);
      if (chunk.outerHtml.length > maxLength && chunk.nodes.length > 1) {
        part.remove();
        chunks.add(chunk);
        chunk = boundedSource.clone(false)..append(part);
      }
    }
  }
  if (chunk.nodes.isNotEmpty) chunks.add(chunk);
  return chunks.isEmpty ? [boundedSource.clone(false)] : chunks;
}

dom.Element? _boundElementAttributes(dom.Element source, int maxLength) {
  final clone = source.clone(true);
  if (clone.clone(false).outerHtml.length <= maxLength) return clone;
  switch (clone.localName?.toLowerCase()) {
    case 'img':
      final alt = clone.attributes['alt'];
      if (alt != null && alt.length > 512) {
        clone.attributes['alt'] = _safePrefix(alt, 512);
      }
      if (clone.clone(false).outerHtml.length <= maxLength) return clone;
      clone.attributes.remove('alt');
      if (clone.clone(false).outerHtml.length <= maxLength) return clone;
      return null;
    case 'a':
      clone.attributes.remove('href');
    default:
      clone.attributes.clear();
  }
  return clone.clone(false).outerHtml.length <= maxLength ? clone : null;
}

String _safePrefix(String source, int maxCodeUnits) {
  var end = math.min(source.length, maxCodeUnits);
  if (end < source.length &&
      end > 0 &&
      _isHighSurrogate(source.codeUnitAt(end - 1)) &&
      _isLowSurrogate(source.codeUnitAt(end))) {
    end--;
  }
  return source.substring(0, end);
}

int _serializedNodeLength(dom.Node source) {
  if (source is dom.Element) return source.outerHtml.length;
  if (source is dom.Text) {
    return const HtmlEscape(HtmlEscapeMode.element).convert(source.data).length;
  }
  return 0;
}

List<dom.Node> _splitText(String source, int maxLength) {
  final chunks = <dom.Node>[];
  var start = 0;
  while (start < source.length) {
    var low = start + 1;
    var high = source.length;
    var end = low;
    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      final escapedLength = const HtmlEscape(
        HtmlEscapeMode.element,
      ).convert(source.substring(start, middle)).length;
      if (escapedLength <= maxLength) {
        end = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (end < source.length) {
      final minimumBreak = start + ((end - start) ~/ 2);
      for (var candidate = end - 1; candidate > minimumBreak; candidate--) {
        if (_isWhitespace(source.codeUnitAt(candidate))) {
          end = candidate + 1;
          break;
        }
      }
      if (end < source.length &&
          end > start &&
          _isHighSurrogate(source.codeUnitAt(end - 1)) &&
          _isLowSurrogate(source.codeUnitAt(end))) {
        end--;
      }
    }
    chunks.add(dom.Text(source.substring(start, end)));
    start = end;
  }
  return chunks;
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

Iterable<String> _orderedMarkerLabels(int firstIndex, int lastIndex) sync* {
  final count = (lastIndex - firstIndex).abs() + 1;
  if (count <= 200) {
    final step = lastIndex >= firstIndex ? 1 : -1;
    for (var value = firstIndex; ; value += step) {
      yield '$value';
      if (value == lastIndex) break;
    }
    return;
  }

  yield '$firstIndex';
  yield '$lastIndex';
  final maxDigits = math
      .max(firstIndex.abs(), lastIndex.abs())
      .toString()
      .length;
  for (var digit = 0; digit <= 9; digit++) {
    final repeated = List.filled(maxDigits, '$digit').join();
    yield repeated;
    if (firstIndex < 0 || lastIndex < 0) yield '-$repeated';
  }
}

final class _ArticleImage extends ConsumerWidget {
  const _ArticleImage({
    required this.source,
    required this.allowed,
    this.alt,
    this.declaredWidth,
    this.declaredHeight,
    this.secret,
    this.onTap,
  });

  final String source;
  final bool allowed;
  final String? alt;
  final double? declaredWidth;
  final double? declaredHeight;
  final PrivateFeedSecret? secret;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!allowed) return const SizedBox.shrink();
    final enabled = ref.watch(remoteImagesProvider).value ?? false;
    final uri = Uri.tryParse(source);
    final headers =
        secret != null && uri != null && sameOrigin(uri, secret!.url)
        ? secret!.headers
        : const <String, String>{};
    final imageState = enabled && uri != null
        ? ref.watch(safeImageFileProvider((url: source, headers: headers)))
        : null;
    if (imageState == null) return const SizedBox.shrink();
    final localPath = imageState.value;
    final image = localPath == null
        ? _placeholder(context, loading: imageState.isLoading, keyed: true)
        : LayoutBuilder(
            builder: (context, constraints) {
              final logicalWidth = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width;
              final pixelWidth =
                  (logicalWidth * MediaQuery.devicePixelRatioOf(context))
                      .round()
                      .clamp(1, 2048)
                      .toInt();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(localPath),
                    key: ValueKey('article-image:$source'),
                    cacheWidth: pixelWidth,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        _placeholder(context, loading: false, padded: false),
                  ),
                ),
              );
            },
          );
    final linkedImage = onTap == null
        ? image
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: image,
          );
    if (onTap != null) {
      return Semantics(
        image: true,
        link: true,
        label: alt?.isNotEmpty == true ? alt : 'Linked image',
        onTap: onTap,
        child: ExcludeSemantics(child: linkedImage),
      );
    }
    if (alt?.isNotEmpty == true) {
      return Semantics(
        image: true,
        label: alt,
        child: ExcludeSemantics(child: linkedImage),
      );
    }
    return ExcludeSemantics(child: linkedImage);
  }

  Widget _placeholder(
    BuildContext context, {
    required bool loading,
    bool padded = true,
    bool keyed = false,
  }) {
    final placeholder = LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final width = declaredWidth == null
            ? availableWidth
            : math.min(declaredWidth!, availableWidth);
        final aspectRatio = declaredWidth != null && declaredHeight != null
            ? (declaredWidth! / declaredHeight!).clamp(0.2, 5.0)
            : null;
        final rawHeight = aspectRatio == null
            ? math.min(declaredHeight ?? 96, 240).toDouble()
            : width / aspectRatio;
        final height = math.min(rawHeight, 480.0);
        final shortestSide = math.min(width, height);
        Widget status;
        if (shortestSide < 24) {
          status = const SizedBox.shrink();
        } else if (loading) {
          status = SizedBox.square(
            dimension: math.min(22, shortestSide * 0.5),
            child: const CircularProgressIndicator(strokeWidth: 2),
          );
        } else if (shortestSide < 64) {
          status = Icon(
            Icons.broken_image_outlined,
            size: math.min(22, shortestSide * 0.55),
            color: AppConstants.secondaryText,
          );
        } else {
          status = const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                color: AppConstants.secondaryText,
              ),
              SizedBox(height: 5),
              Text(
                'Image unavailable',
                style: TextStyle(
                  color: AppConstants.secondaryText,
                  fontSize: 12,
                ),
              ),
            ],
          );
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              key: keyed ? ValueKey('article-image:$source') : null,
              width: width,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppConstants.elevated,
                  border: Border.all(color: AppConstants.hairline),
                ),
                child: Center(child: status),
              ),
            ),
          ),
        );
      },
    );
    return padded
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: placeholder,
          )
        : placeholder;
  }
}

double? _imageDimension(String? raw) {
  final value = double.tryParse(raw ?? '');
  if (value == null || !value.isFinite || value <= 0 || value > 8192) {
    return null;
  }
  return value;
}

String? _safeExternalUrl(String? rawUrl) {
  if (rawUrl == null) return null;
  final uri = Uri.tryParse(rawUrl);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri.toString();
}
