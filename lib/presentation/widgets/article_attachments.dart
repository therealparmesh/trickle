import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_providers.dart';
import '../../core/errors.dart';
import '../../data/database/app_database.dart';
import '../../features/video/video_session.dart';
import 'article_content.dart';
import 'common.dart';

final class ArticleAttachmentsView extends ConsumerWidget {
  const ArticleAttachmentsView({required this.article, super.key});

  final Article article;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(articleAttachmentsProvider(article.id))
        .when(
          loading: () => const InlineLoadingView(label: 'Loading media'),
          error: (error, _) => InlineErrorView(
            friendlyError(error),
            title: 'Couldn’t load media',
            onRetry: () =>
                ref.invalidate(articleAttachmentsProvider(article.id)),
          ),
          data: (attachments) => attachments.isEmpty
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final attachment in attachments)
                      _Attachment(article: article, attachment: attachment),
                    const SizedBox(height: 10),
                  ],
                ),
        );
  }
}

final class _Attachment extends ConsumerStatefulWidget {
  const _Attachment({required this.article, required this.attachment});

  final Article article;
  final ArticleAttachment attachment;

  @override
  ConsumerState<_Attachment> createState() => _AttachmentState();
}

final class _AttachmentState extends ConsumerState<_Attachment> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    if (_isImage(attachment)) {
      return ArticleImage(
        source: attachment.url,
        allowed: true,
        alt: attachment.alt,
        declaredWidth: attachment.width?.toDouble(),
        declaredHeight: attachment.height?.toDouble(),
      );
    }
    if (_isAudio(attachment)) return _audio(context);
    if (_isVideo(attachment)) return _video(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: OutlinedButton.icon(
        onPressed: _busy ? null : _open,
        icon: const Icon(Icons.open_in_new_rounded),
        label: Text(attachment.alt ?? 'Open attachment'),
      ),
    );
  }

  Widget _audio(BuildContext context) {
    final playback = ref.watch(
      playbackItemUiSnapshotProvider(widget.attachment.id),
    );
    final isCurrent = playback.isCurrent;
    final playing = playback.playing;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: FilledButton.tonalIcon(
        onPressed: _busy ? null : () => _toggleAudio(isCurrent, playing),
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        label: Text(
          playing
              ? 'Pause audio'
              : isCurrent
              ? 'Resume audio'
              : 'Play audio',
        ),
      ),
    );
  }

  Widget _video(BuildContext context) {
    final preview = widget.attachment.previewUrl;
    final active = ref.watch(videoSessionProvider);
    final isActive =
        active?.articleId == widget.article.id &&
        active?.sourceUri.toString() == widget.attachment.url;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (preview != null)
            ArticleImage(
              source: preview,
              allowed: true,
              alt: widget.attachment.alt,
              declaredWidth: widget.attachment.width?.toDouble(),
              declaredHeight: widget.attachment.height?.toDouble(),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : () => _playVideo(isActive),
            icon: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(isActive ? 'Open video player' : 'Play video'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleAudio(bool isCurrent, bool playing) async {
    setState(() => _busy = true);
    try {
      final handler = ref.read(audioHandlerProvider);
      if (isCurrent) {
        if (playing) {
          await handler.pause();
        } else {
          await handler.play();
        }
        return;
      }
      final media = await _resolveMedia();
      final episode = await ref
          .read(nostrRepositoryProvider)
          .cacheAudioAttachment(
            article: widget.article,
            attachment: widget.attachment.copyWith(url: media.toString()),
          );
      await handler.playStandaloneEpisode(episode.id);
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playVideo(bool isActive) async {
    if (isActive) {
      ref.read(videoSessionProvider.notifier).expand();
      return;
    }
    setState(() => _busy = true);
    final handler = ref.read(audioHandlerProvider);
    final intent = handler.beginWebVideoPlayback();
    try {
      final media = await _resolveMedia();
      if (!handler.isWebVideoPlaybackCurrent(intent) ||
          !await handler.prepareWebVideoPlayback(intent)) {
        return;
      }
      if (!mounted) {
        await handler.endWebVideoPlayback(intent);
        return;
      }
      ref
          .read(videoSessionProvider.notifier)
          .open(
            intentRevision: intent,
            articleId: widget.article.id,
            title: widget.article.title,
            sourceUri: media,
            playbackUri: media,
          );
    } on Object catch (error) {
      await handler.endWebVideoPlayback(intent).catchError((Object _) {});
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uri> _resolveMedia() async {
    Object? lastError;
    for (final candidate in _mediaCandidates(widget.attachment)) {
      try {
        return (await ref.read(networkProvider).resolveResource(candidate)).url;
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const NetworkException('No playable media URL found.');
  }

  Future<void> _open() async {
    setState(() => _busy = true);
    try {
      final uri = await _resolveMedia();
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const NetworkException('Couldn’t open this attachment.');
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

Iterable<Uri> _mediaCandidates(ArticleAttachment attachment) sync* {
  if (Uri.tryParse(attachment.url) case final primary?) yield primary;
  try {
    final decoded = jsonDecode(attachment.fallbackUrls ?? '[]');
    if (decoded is List) {
      for (final raw in decoded.whereType<String>()) {
        if (Uri.tryParse(raw) case final fallback?) yield fallback;
      }
    }
  } on Object {
    // Ignore corrupt optional fallbacks and retain the primary media URL.
  }
}

bool _isImage(ArticleAttachment attachment) =>
    attachment.mimeType?.toLowerCase().startsWith('image/') == true ||
    RegExp(
      r'\.(avif|gif|jpe?g|png|webp)$',
      caseSensitive: false,
    ).hasMatch(Uri.tryParse(attachment.url)?.path ?? '');

bool _isAudio(ArticleAttachment attachment) =>
    attachment.mimeType?.toLowerCase().startsWith('audio/') == true ||
    RegExp(
      r'\.(aac|flac|m4a|mp3|ogg|opus|wav)$',
      caseSensitive: false,
    ).hasMatch(Uri.tryParse(attachment.url)?.path ?? '');

bool _isVideo(ArticleAttachment attachment) =>
    attachment.mimeType?.toLowerCase().startsWith('video/') == true ||
    RegExp(
      r'\.(m3u8|m4v|mp4|mov|webm)$',
      caseSensitive: false,
    ).hasMatch(Uri.tryParse(attachment.url)?.path ?? '');
