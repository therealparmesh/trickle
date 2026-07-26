import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../core/youtube_support.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/article_repository.dart';
import '../../features/video/video_session.dart';
import '../widgets/common.dart';
import '../widgets/article_content.dart';
import '../widgets/article_attachments.dart';
import '../widgets/design_system.dart';

final class ArticlePage extends ConsumerStatefulWidget {
  const ArticlePage({required this.articleId, super.key});

  final String articleId;

  @override
  ConsumerState<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends ConsumerState<ArticlePage> {
  double _scale = 1;
  String? _contentSignature;
  Future<ExtractedArticle>? _content;
  String? _presentedVideoArticleId;
  Future<void> _readStateWrite = Future<void>.value();
  String? _revealedContentWarning;

  @override
  Widget build(BuildContext context) {
    final article = ref.watch(articleProvider(widget.articleId));
    final value = article.value;
    final sourceUri = Uri.tryParse(value?.canonicalUrl ?? '');
    final playbackUri = privacyYouTubePlaybackUri(sourceUri);
    final isNostr = sourceUri?.scheme == 'nostr';
    return Scaffold(
      appBar: AppBar(
        title: PageTitle(playbackUri == null ? 'Reader' : 'Video'),
        actions: [
          if (playbackUri == null)
            PopupMenuButton<String>(
              tooltip: 'Reader options',
              onSelected: (action) {
                if (action == 'refresh' && value != null) {
                  _refreshContent(value);
                } else {
                  _changeTextSize(action);
                }
              },
              icon: const Icon(Icons.text_fields_rounded),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'smaller',
                  enabled: _scale > 0.8,
                  child: const Text('Smaller text'),
                ),
                PopupMenuItem(
                  value: 'reset',
                  enabled: _scale != 1,
                  child: const Text('Default text size'),
                ),
                PopupMenuItem(
                  value: 'larger',
                  enabled: _scale < 1.5,
                  child: const Text('Larger text'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'refresh',
                  child: Text('Refresh reader view'),
                ),
              ],
            ),
          IconButton(
            tooltip: playbackUri == null ? 'Share article' : 'Share video',
            onPressed: value == null
                ? null
                : () => _runAction(() => _share(value)),
            icon: const Icon(Icons.share_rounded),
          ),
          IconButton(
            tooltip: isNostr
                ? 'Open in another app'
                : playbackUri == null
                ? 'Open in browser'
                : 'Open original',
            onPressed: value?.canonicalUrl == null
                ? null
                : () => _openInBrowser(value!),
            icon: const Icon(Icons.open_in_browser_rounded),
          ),
        ],
      ),
      body: AppBackdrop(
        child: article.when(
          data: (value) {
            if (value == null) {
              return const EmptyState(
                icon: Icons.article_outlined,
                title: 'Article unavailable',
                message: 'This item is no longer on this device.',
              );
            }
            final sourceUri = Uri.tryParse(value.canonicalUrl ?? '');
            final playbackUri = privacyYouTubePlaybackUri(sourceUri);
            if (sourceUri != null && playbackUri != null) {
              _presentVideo(value, sourceUri, playbackUri);
              return _videoDetails(value, sourceUri, playbackUri);
            }
            return FutureBuilder(
              future: _contentFor(value),
              builder: (context, snapshot) {
                if (!snapshot.hasData &&
                    snapshot.connectionState != ConnectionState.done) {
                  return const LoadingView();
                }
                if (snapshot.hasError) {
                  return ErrorView(
                    friendlyError(snapshot.error!),
                    title: 'Couldn’t prepare article',
                    onRetry: () => _refreshContent(value),
                  );
                }
                final extracted = snapshot.data;
                final html = extracted?.html.isNotEmpty == true
                    ? extracted!.html
                    : value.summary ?? '';
                final feed = ref.watch(feedProvider(value.feedId)).value;
                final secret = ref
                    .watch(privateFeedSecretProvider(value.feedId))
                    .value;
                final allowRemoteImages =
                    feed != null && (!feed.isPrivate || secret != null);
                final warning = value.contentWarning?.trim();
                final revealContent =
                    warning?.isNotEmpty != true ||
                    _revealedContentWarning == warning;
                return SelectionArea(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(22, 20, 22, 64),
                    children: [
                      Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Semantics(
                                header: true,
                                child: Text(
                                  value.title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .displaySmall
                                      ?.copyWith(fontSize: 38 * _scale),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _metadata(value, feed?.title),
                              const SizedBox(height: 26),
                              if (extracted?.readerFallback == true) ...[
                                _ReaderFallbackNotice(
                                  onRetry: () => _refreshContent(value),
                                  onOpenInBrowser: value.canonicalUrl == null
                                      ? null
                                      : () => _openInBrowser(value),
                                ),
                                const SizedBox(height: 20),
                              ],
                              if (!revealContent)
                                _ContentWarningGate(
                                  warning: warning!,
                                  onReveal: () => setState(
                                    () => _revealedContentWarning = warning,
                                  ),
                                )
                              else ...[
                                ArticleAttachmentsView(article: value),
                                ArticleContent(
                                  html: html,
                                  scale: _scale,
                                  privateSecret: secret,
                                  allowRemoteImages: allowRemoteImages,
                                  leadingTitleToOmit: value.title,
                                ),
                              ],
                              const SizedBox(height: 30),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: () => _runAction(
                                      () => ref
                                          .read(feedRepositoryProvider)
                                          .starArticle(
                                            value.id,
                                            starred: !value.starred,
                                          ),
                                    ),
                                    icon: Icon(
                                      value.starred
                                          ? Icons.bookmark_rounded
                                          : Icons.bookmark_border_rounded,
                                    ),
                                    label: Text(
                                      value.starred
                                          ? 'Remove from Saved'
                                          : 'Save',
                                    ),
                                  ),
                                  FilledButton.tonalIcon(
                                    onPressed: () => _runAction(
                                      () => ref
                                          .read(feedRepositoryProvider)
                                          .markArticleRead(
                                            value.id,
                                            read: value.readAt == null,
                                          ),
                                    ),
                                    icon: Icon(
                                      value.readAt == null
                                          ? Icons.mark_email_read_outlined
                                          : Icons.mark_email_unread_outlined,
                                    ),
                                    label: Text(
                                      value.readAt == null
                                          ? 'Mark read'
                                          : 'Mark unread',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(
            friendlyError(error),
            onRetry: () => ref.invalidate(articleProvider(widget.articleId)),
          ),
        ),
      ),
    );
  }

  Widget _videoDetails(Article article, Uri sourceUri, Uri playbackUri) {
    final feed = ref.watch(feedProvider(article.feedId)).value;
    final summary = article.summary?.trim();
    final activeVideo = ref.watch(videoSessionProvider);
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 64),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      article.title,
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _metadata(article, feed?.title),
                  if (summary?.isNotEmpty == true) ...[
                    const SizedBox(height: 26),
                    Text(
                      summary!,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () {
                      if (activeVideo?.articleId == article.id) {
                        ref.read(videoSessionProvider.notifier).expand();
                      } else {
                        _presentVideo(
                          article,
                          sourceUri,
                          playbackUri,
                          force: true,
                        );
                      }
                    },
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      activeVideo?.articleId == article.id
                          ? 'Open video player'
                          : 'Play video',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => _runAction(
                          () => ref
                              .read(feedRepositoryProvider)
                              .starArticle(
                                article.id,
                                starred: !article.starred,
                              ),
                        ),
                        icon: Icon(
                          article.starred
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                        ),
                        label: Text(
                          article.starred ? 'Remove from Saved' : 'Save',
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _runAction(
                          () => ref
                              .read(feedRepositoryProvider)
                              .markArticleRead(
                                article.id,
                                read: article.readAt == null,
                              ),
                        ),
                        icon: Icon(
                          article.readAt == null
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        label: Text(
                          article.readAt == null
                              ? 'Mark watched'
                              : 'Mark unwatched',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _presentVideo(
    Article article,
    Uri sourceUri,
    Uri playbackUri, {
    bool force = false,
  }) {
    if (!force && _presentedVideoArticleId == article.id) return;
    _presentedVideoArticleId = article.id;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ref.read(audioHandlerProvider).pause();
      } on Object {
        // Video can still start if there was no active audio session to pause.
      }
      if (!mounted || widget.articleId != article.id) return;
      ref
          .read(videoSessionProvider.notifier)
          .open(
            articleId: article.id,
            title: article.title,
            sourceUri: sourceUri,
            playbackUri: playbackUri,
          );
    });
  }

  Future<ExtractedArticle> _contentFor(Article article) {
    // The load itself may store extracted HTML and rebuild this page. Keep the
    // generation tied to the article, not to that cache write, so a short
    // article is never downloaded twice.
    final signature = '${article.id}|${article.canonicalUrl}';
    if (_content == null || _contentSignature != signature) {
      _contentSignature = signature;
      final format =
          ArticleContentFormat.values[article.contentFormat.clamp(
            0,
            ArticleContentFormat.values.length - 1,
          )];
      _content = format == ArticleContentFormat.html
          ? ref.read(articleRepositoryProvider).load(article)
          : compute(_renderStoredArticle, (
              format: format.index,
              content: article.contentHtml ?? article.summary ?? '',
            ));
    }
    return _content!;
  }

  void _refreshContent(Article article) {
    final format =
        ArticleContentFormat.values[article.contentFormat.clamp(
          0,
          ArticleContentFormat.values.length - 1,
        )];
    if (format != ArticleContentFormat.html) {
      setState(() {
        _content = compute(_renderStoredArticle, (
          format: format.index,
          content: article.contentHtml ?? article.summary ?? '',
        ));
      });
      return;
    }
    setState(() {
      _content = ref
          .read(articleRepositoryProvider)
          .load(article, forceRefresh: true);
    });
  }

  void _changeTextSize(String action) {
    final tenths = (_scale * 10).round();
    setState(() {
      _scale = switch (action) {
        'smaller' => (tenths - 1).clamp(8, 15) / 10,
        'larger' => (tenths + 1).clamp(8, 15) / 10,
        _ => 1,
      };
    });
  }

  Future<void> _share(Article article) async {
    final url = article.canonicalUrl;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: url == null ? article.title : '${article.title}\n$url',
        subject: article.title,
        sharePositionOrigin: box == null || !box.hasSize || box.size.isEmpty
            ? const Rect.fromLTWH(0, 0, 1, 1)
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _openInBrowser(Article article) async {
    final url = article.canonicalUrl;
    if (url == null) return;
    var opened = false;
    try {
      final uri = Uri.tryParse(url);
      opened =
          uri != null &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      opened = false;
    }
    if (!opened && mounted) {
      final uri = Uri.tryParse(url);
      if (uri?.scheme == 'nostr') {
        showMessageSnackBar(context, 'Couldn’t open this post in another app.');
        return;
      }
      final noun = privacyYouTubePlaybackUri(uri) == null ? 'article' : 'video';
      showMessageSnackBar(context, 'Couldn’t open this $noun in your browser.');
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      // Preserve an explicit user choice made immediately after opening the
      // page. It must run after the automatic mark-read write, not race it.
      await _readStateWrite;
      await action();
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    }
  }

  @override
  void initState() {
    super.initState();
    _markCurrentItemRead();
  }

  @override
  void didUpdateWidget(covariant ArticlePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.articleId != widget.articleId) {
      _revealedContentWarning = null;
      _markCurrentItemRead();
    }
  }

  void _markCurrentItemRead() {
    final articleId = widget.articleId;
    _readStateWrite = Future<void>.microtask(() async {
      try {
        await ref
            .read(feedRepositoryProvider)
            .markArticleRead(articleId, read: true);
      } on Object catch (error) {
        if (mounted) showErrorSnackBar(context, error);
      }
    });
  }

  Widget _metadata(Article article, String? feedTitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(width: 18, height: 3, color: AppConstants.magenta),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            metadataLine([
              if (feedTitle?.isNotEmpty == true) feedTitle!,
              if (article.author?.isNotEmpty == true &&
                  article.author!.trim().toLowerCase() !=
                      feedTitle?.trim().toLowerCase())
                article.author!,
              relativeDate(article.publishedAt),
            ]),
            style: const TextStyle(color: AppConstants.cyan),
          ),
        ),
      ],
    );
  }
}

ExtractedArticle _renderStoredArticle(({int format, String content}) input) {
  final format = ArticleContentFormat
      .values[input.format.clamp(0, ArticleContentFormat.values.length - 1)];
  final html = switch (format) {
    ArticleContentFormat.markdown => markdown.markdownToHtml(
      input.content,
      enableTagfilter: true,
      extensionSet: markdown.ExtensionSet.gitHubWeb,
    ),
    ArticleContentFormat.plainText =>
      input.content
          .split(RegExp(r'\n\s*\n'))
          .where((paragraph) => paragraph.trim().isNotEmpty)
          .map((paragraph) => '<p>${_linkPlainText(paragraph.trim())}</p>')
          .join(),
    ArticleContentFormat.html => input.content,
  };
  return ExtractedArticle(html: html, text: input.content);
}

String _linkPlainText(String input) {
  final output = StringBuffer();
  var offset = 0;
  for (final match in RegExp(
    r'https://[^\s<]+',
    caseSensitive: false,
  ).allMatches(input)) {
    output.write(
      const HtmlEscape(
        HtmlEscapeMode.element,
      ).convert(input.substring(offset, match.start)),
    );
    var url = match.group(0)!;
    var trailing = '';
    while (url.isNotEmpty &&
        RegExp(r'[.,!?:;]').hasMatch(url[url.length - 1])) {
      trailing = '${url[url.length - 1]}$trailing';
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) {
      output.write(
        const HtmlEscape(HtmlEscapeMode.element).convert(match.group(0)!),
      );
    } else {
      final label = const HtmlEscape(HtmlEscapeMode.element).convert(url);
      final href = const HtmlEscape(HtmlEscapeMode.attribute).convert(url);
      output.write('<a href="$href">$label</a>');
      output.write(const HtmlEscape(HtmlEscapeMode.element).convert(trailing));
    }
    offset = match.end;
  }
  output.write(
    const HtmlEscape(HtmlEscapeMode.element).convert(input.substring(offset)),
  );
  return output.toString().replaceAll('\n', '<br>');
}

final class _ContentWarningGate extends StatelessWidget {
  const _ContentWarningGate({required this.warning, required this.onReveal});

  final String warning;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    return SignalPanel(
      accent: AppConstants.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Content warning',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(warning),
          const SizedBox(height: 14),
          FilledButton.tonal(
            onPressed: onReveal,
            child: const Text('Show content'),
          ),
        ],
      ),
    );
  }
}

final class _ReaderFallbackNotice extends StatelessWidget {
  const _ReaderFallbackNotice({
    required this.onRetry,
    required this.onOpenInBrowser,
  });

  final VoidCallback onRetry;
  final VoidCallback? onOpenInBrowser;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          color: AppConstants.elevated,
          shape: CutCornerBorder(
            cut: 12,
            side: BorderSide(color: AppConstants.hairline),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Reader view unavailable',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Showing the feed summary instead.',
                style: TextStyle(color: AppConstants.secondaryText),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('Try again'),
                  ),
                  if (onOpenInBrowser != null)
                    TextButton(
                      onPressed: onOpenInBrowser,
                      child: const Text('Open in browser'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
