import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database/app_database.dart';
import '../episode_actions.dart';
import 'common.dart';
import 'episode_playback_button.dart';

final class EpisodeTile extends ConsumerWidget {
  const EpisodeTile(this.episode, {this.showSource = true, super.key});

  final Episode episode;
  final bool showSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourceTitle = showSource
        ? ref.watch(feedProvider(episode.feedId)).value?.title
        : null;
    final download = ref.watch(downloadForEpisodeProvider(episode.id));
    final downloadState = download == null
        ? null
        : DownloadState.values[download.status.clamp(
            0,
            DownloadState.values.length - 1,
          )];
    final downloadMenu = episodeDownloadAction(download);
    final metadata = [
      if (sourceTitle?.isNotEmpty == true) sourceTitle!,
      relativeDate(episode.publishedAt),
      compactDuration(episode.durationMs),
      if (downloadState == DownloadState.complete) 'Downloaded',
    ].where((part) => part.isNotEmpty).join(' · ');
    return _InsetListFrame(
      indent: 86,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              button: true,
              excludeSemantics: true,
              onTap: () => context.push('/episode/${episode.id}'),
              label: [
                '${episode.played ? 'Played' : 'Unplayed'} episode ${episode.title}',
                if (episode.explicit) 'Explicit',
                if (episode.starred) 'Saved',
                if (downloadState == DownloadState.complete) 'Downloaded',
                if (metadata.isNotEmpty) metadata,
              ].join('. '),
              child: InkWell(
                onTap: () => context.push('/episode/${episode.id}'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                  child: Row(
                    children: [
                      EpisodeArtwork(episode: episode, size: 58),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            EpisodeTitle(
                              title: episode.title,
                              explicit: episode.explicit,
                              maxLines: 2,
                              style: TextStyle(
                                color: episode.played
                                    ? AppConstants.secondaryText
                                    : AppConstants.primaryText,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                if (!episode.played) ...[
                                  const _NewDot(color: AppConstants.magenta),
                                  const SizedBox(width: 7),
                                ],
                                Expanded(
                                  child: Text(
                                    metadata.isEmpty
                                        ? (episode.played ? 'Played' : 'New')
                                        : metadata,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          download?.status ==
                                              DownloadState.complete.index
                                          ? AppConstants.acid
                                          : AppConstants.secondaryText,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          EpisodePlaybackButton(episode: episode),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PopupMenuButton<EpisodeAction>(
              tooltip: 'Episode actions',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (action) => _action(context, ref, action),
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: EpisodeAction.playNext,
                  child: Text('Play next'),
                ),
                const PopupMenuItem(
                  value: EpisodeAction.addToUpNext,
                  child: Text('Add to Up Next'),
                ),
                PopupMenuItem(
                  value: downloadMenu.action,
                  child: Text(downloadMenu.label),
                ),
                PopupMenuItem(
                  value: EpisodeAction.toggleSaved,
                  child: Text(episode.starred ? 'Remove from Saved' : 'Save'),
                ),
                PopupMenuItem(
                  value: EpisodeAction.togglePlayed,
                  child: Text(episode.played ? 'Mark unplayed' : 'Mark played'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _action(
    BuildContext context,
    WidgetRef ref,
    EpisodeAction action,
  ) async {
    try {
      await performEpisodeAction(ref, episode, action);
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }
}

final class ArticleTile extends ConsumerWidget {
  const ArticleTile(this.article, {this.showSource = true, super.key});
  final Article article;
  final bool showSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourceTitle = showSource
        ? ref.watch(feedProvider(article.feedId)).value?.title
        : null;
    final metadata = [
      if (sourceTitle?.isNotEmpty == true) sourceTitle!,
      if (article.author?.isNotEmpty == true) article.author!,
      relativeDate(article.publishedAt),
    ].where((part) => part.isNotEmpty).join(' · ');
    return _InsetListFrame(
      indent: 100,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Semantics(
              container: true,
              button: true,
              excludeSemantics: true,
              onTap: () => context.push('/article/${article.id}'),
              label: [
                '${article.readAt == null ? 'Unread' : 'Read'} article ${article.title}',
                if (article.starred) 'Saved',
                if (metadata.isNotEmpty) metadata,
              ].join('. '),
              child: InkWell(
                onTap: () => context.push('/article/${article.id}'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ArticleArtwork(article: article, size: 72, radius: 10),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              article.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: article.readAt == null
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: article.readAt == null
                                    ? AppConstants.primaryText
                                    : AppConstants.secondaryText,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                if (article.readAt == null) ...[
                                  const _NewDot(color: AppConstants.cyan),
                                  const SizedBox(width: 7),
                                ],
                                Expanded(
                                  child: Text(
                                    metadata.isEmpty
                                        ? (article.readAt == null
                                              ? 'New'
                                              : 'Read')
                                        : metadata,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppConstants.secondaryText,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (article.starred)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.bookmark_rounded,
                            size: 16,
                            color: AppConstants.acid,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, top: 8),
            child: PopupMenuButton<String>(
              tooltip: 'Article actions',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (action) => _action(context, ref, action),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'star',
                  child: Text(article.starred ? 'Remove from Saved' : 'Save'),
                ),
                PopupMenuItem(
                  value: 'read',
                  child: Text(
                    article.readAt == null ? 'Mark read' : 'Mark unread',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _action(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    try {
      if (action == 'star') {
        await ref
            .read(feedRepositoryProvider)
            .starArticle(article.id, starred: !article.starred);
      } else {
        await ref
            .read(feedRepositoryProvider)
            .markArticleRead(article.id, read: article.readAt == null);
      }
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }
}

final class _NewDot extends StatelessWidget {
  const _NewDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: const SizedBox.square(dimension: 7),
      ),
    );
  }
}

final class PodcastTile extends StatelessWidget {
  const PodcastTile(this.feed, {super.key});
  final Feed feed;

  @override
  Widget build(BuildContext context) {
    final detail = feed.refreshError ?? feed.author;
    return _InsetListFrame(
      indent: 102,
      child: Semantics(
        container: true,
        button: true,
        excludeSemantics: true,
        onTap: () => context.push('/podcast/${feed.id}'),
        label: [
          'Podcast ${feed.title}',
          if (detail?.trim().isNotEmpty == true) detail!.trim(),
        ].join('. '),
        child: InkWell(
          onTap: () => context.push('/podcast/${feed.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                FeedArtwork(feed: feed, size: 72, radius: 10),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        feed.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        feed.refreshError ?? feed.author ?? 'Podcast',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: feed.refreshError == null
                              ? AppConstants.secondaryText
                              : AppConstants.danger,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppConstants.secondaryText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _InsetListFrame extends StatelessWidget {
  const _InsetListFrame({required this.indent, required this.child});

  final double indent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        Divider(height: 1, indent: indent, endIndent: 16),
      ],
    );
  }
}
