import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../data/repositories/article_repository.dart';
import '../../data/security/private_feed_store.dart';
import 'article_content.dart';
import 'common.dart';

final class EpisodeShowNotes extends StatelessWidget {
  const EpisodeShowNotes({
    required this.value,
    required this.onRetry,
    required this.allowRemoteImages,
    this.privateSecret,
    this.leadingTitleToOmit,
    this.scale = 0.9,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final AsyncValue<ExtractedArticle?> value;
  final VoidCallback onRetry;
  final PrivateFeedSecret? privateSecret;
  final bool allowRemoteImages;
  final String? leadingTitleToOmit;
  final double scale;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const InlineLoadingView(label: 'Loading show notes'),
      error: (error, _) => InlineErrorView(
        friendlyError(error),
        title: 'Couldn’t load show notes',
        onRetry: onRetry,
      ),
      data: (notes) {
        if (notes == null || notes.text.trim().isEmpty) {
          return const Text('No show notes available.');
        }
        return Padding(
          padding: padding,
          child: ArticleContent(
            html: notes.html,
            scale: scale,
            privateSecret: privateSecret,
            allowRemoteImages: allowRemoteImages,
            leadingTitleToOmit: leadingTitleToOmit,
          ),
        );
      },
    );
  }
}
