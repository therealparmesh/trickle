import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../data/database/app_database.dart';
import '../episode_actions.dart';
import '../widgets/common.dart';
import '../widgets/design_system.dart';
import '../widgets/episode_playback_button.dart';
import '../widgets/episode_show_notes.dart';

final class EpisodePage extends ConsumerWidget {
  const EpisodePage({required this.episodeId, super.key});

  final String episodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episode = ref.watch(episodeProvider(episodeId));
    final value = episode.value;
    final feed = value == null
        ? null
        : ref.watch(feedProvider(value.feedId)).value;
    return Scaffold(
      appBar: AppBar(
        title: const PageTitle('Episode'),
        actions: [
          IconButton(
            tooltip: 'Share episode',
            onPressed: value == null
                ? null
                : () => _run(context, () => shareEpisode(context, value, feed)),
            icon: const Icon(Icons.share_rounded),
          ),
        ],
      ),
      body: AppBackdrop(
        child: episode.when(
          data: (value) {
            if (value == null) {
              return const EmptyState(
                icon: Icons.podcasts_rounded,
                title: 'Episode unavailable',
                message: 'This episode is no longer on this device.',
              );
            }
            return _EpisodeBody(episode: value, feed: feed);
          },
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(
            friendlyError(error),
            onRetry: () => ref.invalidate(episodeProvider(episodeId)),
          ),
        ),
      ),
    );
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }
}

final class _EpisodeBody extends ConsumerStatefulWidget {
  const _EpisodeBody({required this.episode, required this.feed});

  final Episode episode;
  final Feed? feed;

  @override
  ConsumerState<_EpisodeBody> createState() => _EpisodeBodyState();
}

class _EpisodeBodyState extends ConsumerState<_EpisodeBody> {
  final Set<EpisodeAction> _busyActions = {};

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final feed = widget.feed;
    final download = ref.watch(downloadForEpisodeProvider(episode.id));
    final downloadAction = episodeDownloadAction(download);
    final progress = ref.watch(episodeProgressProvider(episode.id)).value;
    final showNotes = ref.watch(episodeShowNotesProvider(episode.id));
    final secret = feed?.isPrivate == true
        ? ref.watch(privateFeedSecretProvider(feed!.id)).value
        : null;
    final metadata = [
      relativeDate(episode.publishedAt),
      compactDuration(episode.durationMs),
      if (episode.played) 'Played',
    ].where((part) => part.isNotEmpty).join(' · ');
    final position = progress?.positionMs ?? 0;
    final duration = progress?.durationMs ?? episode.durationMs ?? 0;
    final showProgress =
        position > 0 && duration > 0 && progress?.completed != true;

    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 56),
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 620;
              final artwork = ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wide ? 240 : 220,
                  maxHeight: wide ? 240 : 220,
                ),
                child: SignalMediaFrame(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: EpisodeArtwork(
                      episode: episode,
                      size: wide ? 228 : 208,
                      radius: 7,
                    ),
                  ),
                ),
              );
              final information = Column(
                crossAxisAlignment: wide
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.stretch,
                children: [
                  EpisodeTitle(
                    title: episode.title,
                    explicit: episode.explicit,
                    maxLines: null,
                    textAlign: wide ? TextAlign.start : TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  if (feed?.title.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    Text(
                      feed!.title,
                      textAlign: wide ? TextAlign.start : TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppConstants.cyan,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  if (metadata.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      metadata,
                      textAlign: wide ? TextAlign.start : TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppConstants.secondaryText,
                      ),
                    ),
                  ],
                  if (showProgress) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: (position / duration).clamp(0, 1),
                      minHeight: 3,
                      backgroundColor: AppConstants.hairline,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${formatDuration(Duration(milliseconds: position))} played · ${formatDuration(Duration(milliseconds: duration - position))} remaining',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppConstants.secondaryText,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  EpisodePlaybackButton(episode: episode, expanded: true),
                ],
              );
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    artwork,
                    const SizedBox(width: 24),
                    Expanded(child: information),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: artwork),
                  const SizedBox(height: 22),
                  information,
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _ActionButton(
                icon: Icons.playlist_play_rounded,
                label: 'Play next',
                busy: _busyActions.contains(EpisodeAction.playNext),
                onPressed: () => _action(context, ref, EpisodeAction.playNext),
              ),
              _ActionButton(
                icon: Icons.queue_music_rounded,
                label: 'Add to Up Next',
                busy: _busyActions.contains(EpisodeAction.addToUpNext),
                onPressed: () =>
                    _action(context, ref, EpisodeAction.addToUpNext),
              ),
              _ActionButton(
                icon: downloadAction.icon,
                label: downloadAction.label,
                busy: _busyActions.contains(downloadAction.action),
                onPressed: () => _action(context, ref, downloadAction.action),
              ),
              _ActionButton(
                icon: episode.starred
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                label: episode.starred ? 'Saved' : 'Save',
                selected: episode.starred,
                busy: _busyActions.contains(EpisodeAction.toggleSaved),
                onPressed: () =>
                    _action(context, ref, EpisodeAction.toggleSaved),
              ),
              _ActionButton(
                icon: episode.played
                    ? Icons.replay_rounded
                    : Icons.done_rounded,
                label: episode.played ? 'Mark unplayed' : 'Mark played',
                busy: _busyActions.contains(EpisodeAction.togglePlayed),
                onPressed: () =>
                    _action(context, ref, EpisodeAction.togglePlayed),
              ),
            ],
          ),
          const SizedBox(height: 34),
          Text('Show notes', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          EpisodeShowNotes(
            value: showNotes,
            onRetry: () => ref.invalidate(episodeShowNotesProvider(episode.id)),
            privateSecret: secret,
            allowRemoteImages:
                feed != null && (!feed.isPrivate || secret != null),
            leadingTitleToOmit: episode.title,
            scale: 0.95,
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
    if (_busyActions.contains(action)) return;
    setState(() => _busyActions.add(action));
    try {
      await performEpisodeAction(ref, widget.episode, action);
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busyActions.remove(action));
    }
  }
}

final class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? AppConstants.acid : null,
        side: BorderSide(
          color: selected ? AppConstants.acid : AppConstants.hairline,
        ),
      ),
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 19),
      label: Text(label),
    );
  }
}
