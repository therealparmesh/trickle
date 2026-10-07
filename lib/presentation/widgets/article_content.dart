import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../core/constants.dart';
import '../../data/security/private_feed_store.dart';
import 'article_image.dart';
import 'common.dart';

final class ArticleContent extends StatelessWidget {
  const ArticleContent({
    required this.html,
    required this.scale,
    this.privateSecret,
    this.allowRemoteImages = true,
    this.leadingTitleToOmit,
    this.sliver = false,
    super.key,
  });

  final String html;
  final double scale;
  final PrivateFeedSecret? privateSecret;
  final bool allowRemoteImages;
  final String? leadingTitleToOmit;
  final bool sliver;

  @override
  Widget build(BuildContext context) => HtmlWidget(
    html,
    key: ValueKey((privateSecret, allowRemoteImages)),
    factoryBuilder: _ReaderWidgetFactory.new,
    renderMode: sliver ? RenderMode.sliverList : RenderMode.column,
    enableCaching: true,
    rebuildTriggers: [leadingTitleToOmit],
    textStyle: Theme.of(
      context,
    ).textTheme.bodyLarge?.copyWith(fontSize: 18 * scale, height: 1.6),
    customWidgetBuilder: (element) {
      if (element.localName != 'img') return null;
      final source = element.attributes['src'] ?? '';
      final uri = Uri.tryParse(source);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        return const SizedBox.shrink();
      }
      return ArticleImage(
        source: source,
        allowed: allowRemoteImages,
        alt: element.attributes['alt'],
        declaredWidth: double.tryParse(element.attributes['width'] ?? ''),
        declaredHeight: double.tryParse(element.attributes['height'] ?? ''),
        secret: privateSecret,
      );
    },
    customStylesBuilder: (element) {
      if (_isRepeatedTitle(element, leadingTitleToOmit)) {
        return const {'display': 'none'};
      }
      return switch (element.localName) {
        'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' => const {
          'font-family': TrickleFonts.display,
          'line-height': '1.25',
        },
        'blockquote' => {
          'border-left': '3px solid ${_cssColor(AppConstants.magenta)}',
          'padding-left': '${AppSpacing.lg}px',
          'margin-left': '0',
          'margin-right': '0',
        },
        'code' => {'color': _cssColor(AppConstants.acid)},
        'figcaption' => {
          'color': _cssColor(AppConstants.secondaryText),
          'font-size': '0.875em',
        },
        'td' || 'th' => {'padding': '${AppSpacing.sm}px'},
        _ => null,
      };
    },
    onTapUrl: (url) => _openLink(context, url),
    onLoadingBuilder: (_, _, _) =>
        const InlineLoadingView(label: 'Loading content'),
    onErrorBuilder: (_, _, _) => const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Text(
        'Couldn’t display this content. Try opening it in your browser.',
      ),
    ),
  );

  Future<bool> _openLink(BuildContext context, String url) async {
    if (url.startsWith('#')) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return true;
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      opened = false;
    }
    if (!opened && context.mounted) {
      showMessageSnackBar(context, 'Couldn’t open this link in your browser.');
    }
    return true;
  }
}

String _cssColor(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

bool _isRepeatedTitle(dom.Element element, String? title) {
  if (title == null || !const {'h1', 'h2', 'h3'}.contains(element.localName)) {
    return false;
  }
  String normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  if (normalize(element.text) != normalize(title)) return false;
  dom.Node node = element;
  while (node.parentNode != null) {
    for (final sibling in node.parentNode!.nodes) {
      if (identical(sibling, node)) break;
      if (sibling.text?.trim().isNotEmpty == true) return false;
    }
    node = node.parentNode!;
  }
  return true;
}

final class _ReaderWidgetFactory extends WidgetFactory {
  // All reader images must go through the app's bounded, authenticated loader.
  @override
  ImageProvider? imageProviderFromNetwork(String url) => null;

  @override
  ImageProvider? imageProviderFromFileUri(String url) => null;

  @override
  ImageProvider? imageProviderFromDataUri(String data) => null;

  @override
  ImageProvider? imageProviderFromAsset(String url) => null;
}
