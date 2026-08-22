import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/formatters.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/article_repository.dart';
import '../../data/repositories/episode_extras_repository.dart';
import '../../data/security/private_feed_store.dart';
import '../../features/player/trickle_audio_handler.dart';
import '../episode_actions.dart';
import '../playback_presentation.dart';
import '../widgets/common.dart';
import '../widgets/design_system.dart';
import '../widgets/episode_show_notes.dart';

String _sleepTimerDescription(SleepTimerStatus status) {
  if (status.mode == SleepTimerMode.off) return 'Sleep timer';
  if (status.mode == SleepTimerMode.endOfEpisode) {
    return 'Sleep timer set for the end of this episode';
  }
  final endsAt = status.endsAt;
  if (endsAt == null) return 'Sleep timer active';
  final seconds = math.max(
    0,
    endsAt.difference(DateTime.now().toUtc()).inSeconds,
  );
  if (seconds < 60) return 'Sleep timer has less than 1 minute remaining';
  final minutes = (seconds + 59) ~/ 60;
  return 'Sleep timer has $minutes ${minutes == 1 ? 'minute' : 'minutes'} remaining';
}

final class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentMediaProvider).value;
    final playback = ref.watch(playbackUiSnapshotProvider);
    final phase = playbackUiPhaseFor(
      processingState: playback.processingState,
      playing: playback.playing,
    );
    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: const PageTitle('Now Playing')),
        body: const AppBackdrop(
          child: EmptyState(
            icon: Icons.graphic_eq_rounded,
            title: 'Nothing playing',
            message: 'Choose an episode to light up the signal.',
          ),
        ),
      );
    }
    final explicit = item.extras?['explicit'] == true;
    final audioPost = item.extras?['articleId'] is String;
    final speed = ref.watch(speedProvider).value ?? AppConstants.defaultSpeed;
    final queue = ref.watch(queueProvider).value ?? const <MediaItem>[];
    final queueIndex = queue.indexWhere((candidate) => candidate.id == item.id);
    final hasNext = queueIndex >= 0 && queueIndex + 1 < queue.length;
    final sleep =
        ref.watch(sleepTimerStatusProvider).value ??
        const SleepTimerStatus.off();
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    return Scaffold(
      appBar: AppBar(
        title: const PageTitle('Now Playing'),
        actions: [
          IconButton(
            tooltip: _sleepTimerDescription(sleep),
            onPressed: () => _sleepTimer(context, ref),
            icon: Icon(
              sleep.isActive ? Icons.bedtime_rounded : Icons.bedtime_outlined,
              color: sleep.isActive ? AppConstants.magenta : null,
            ),
          ),
          if (!largeText) ...[
            IconButton(
              tooltip: 'Add bookmark',
              onPressed: () => _bookmark(
                context,
                ref,
                item.id,
                ref.read(playbackPositionProvider).value ?? Duration.zero,
              ),
              icon: const Icon(Icons.bookmark_add_outlined),
            ),
            IconButton(
              tooltip: audioPost ? 'Share audio post' : 'Share episode',
              onPressed: () => _runPlayback(() => _shareEpisode(item)),
              icon: const Icon(Icons.share_rounded),
            ),
          ] else
            PopupMenuButton<String>(
              tooltip: 'More actions',
              onSelected: (action) {
                if (action == 'bookmark') {
                  unawaited(
                    _bookmark(
                      context,
                      ref,
                      item.id,
                      ref.read(playbackPositionProvider).value ?? Duration.zero,
                    ),
                  );
                } else if (action == 'share') {
                  unawaited(_runPlayback(() => _shareEpisode(item)));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'bookmark',
                  child: Text('Add bookmark'),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: Text(audioPost ? 'Share audio post' : 'Share episode'),
                ),
              ],
            ),
        ],
      ),
      body: AppBackdrop(
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 10, 24, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 380),
                          child: SignalMediaFrame(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: EpisodeArtworkById(
                                episodeId: item.id,
                                fallbackUrl: item.artUri?.toString(),
                                size: 380,
                                radius: 5,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      EpisodeTitle(
                        title: item.title,
                        explicit: explicit,
                        maxLines: null,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.album ?? 'Podcast',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppConstants.cyan,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 20),
                      SignalPanel(
                        accent: phase.color,
                        color: AppConstants.surface.withValues(alpha: 0.86),
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                        child: Column(
                          children: [
                            _PlaybackProgress(
                              episodeId: item.id,
                              fallbackDuration: item.duration ?? Duration.zero,
                              phase: phase,
                            ),
                            const SizedBox(height: 8),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final showQueueNavigation =
                                    constraints.maxWidth >= 280 && !audioPost;
                                return Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: [
                                    if (showQueueNavigation)
                                      IconButton(
                                        tooltip: 'Previous',
                                        onPressed: () => _runPlayback(
                                          ref
                                              .read(audioHandlerProvider)
                                              .skipToPrevious,
                                        ),
                                        icon: const Icon(
                                          Icons.skip_previous_rounded,
                                          size: 28,
                                        ),
                                      ),
                                    _SkipButton(
                                      label: '15',
                                      tooltip: 'Back 15 seconds',
                                      onPressed: phase.isBusy || phase.isError
                                          ? null
                                          : () => _runPlayback(
                                              ref
                                                  .read(audioHandlerProvider)
                                                  .rewind,
                                            ),
                                      backwards: true,
                                    ),
                                    _PrimaryPlaybackButton(
                                      playing: playback.playing,
                                      phase: phase,
                                    ),
                                    _SkipButton(
                                      label: '30',
                                      tooltip: 'Forward 30 seconds',
                                      onPressed: phase.isBusy || phase.isError
                                          ? null
                                          : () => _runPlayback(
                                              ref
                                                  .read(audioHandlerProvider)
                                                  .fastForward,
                                            ),
                                    ),
                                    if (showQueueNavigation)
                                      IconButton(
                                        tooltip: 'Next',
                                        onPressed: hasNext
                                            ? () => _runPlayback(
                                                ref
                                                    .read(audioHandlerProvider)
                                                    .skipToNext,
                                              )
                                            : null,
                                        icon: const Icon(
                                          Icons.skip_next_rounded,
                                          size: 28,
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      if (phase.isError) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            TrickleAudioHandler.playbackErrorMessage,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: AppConstants.danger),
                          ),
                        ),
                      ],
                      const SizedBox(height: 26),
                      Row(
                        children: [
                          Container(
                            width: 18,
                            height: 3,
                            color: AppConstants.cyan,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              'Playback speed',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      PlaybackSpeedSelector(
                        selected: speed,
                        onSelected: (value) => _runPlayback(
                          () => ref
                              .read(audioHandlerProvider)
                              .setSpeed(value / 100),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _PlaybackOptions(),
                      const SizedBox(height: 22),
                      _Extras(episodeId: item.id),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _runPlayback(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    }
  }

  Future<void> _shareEpisode(MediaItem item) async {
    final articleId = item.extras?['articleId'];
    if (articleId is String) {
      final article = await ref.read(databaseProvider).articleById(articleId);
      if (article == null || !mounted) return;
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
      return;
    }
    final episode = await ref.read(databaseProvider).episodeById(item.id);
    if (episode == null) return;
    final feed = await ref.read(databaseProvider).feedById(episode.feedId);
    if (!mounted) return;
    await shareEpisode(context, episode, feed);
  }

  Future<void> _sleepTimer(BuildContext context, WidgetRef ref) async {
    final current =
        ref.read(sleepTimerStatusProvider).value ??
        const SleepTimerStatus.off();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: const Text('Sleep timer'),
                subtitle: current.isActive
                    ? Text(_sleepTimerDescription(current))
                    : const Text('Off'),
              ),
              for (final minutes in [5, 10, 15, 30, 45, 60, 90])
                ListTile(
                  title: Text(switch (minutes) {
                    60 => '1 hour',
                    90 => '1 hour 30 minutes',
                    _ => '$minutes minutes',
                  }),
                  onTap: () => Navigator.pop(context, '$minutes'),
                ),
              ListTile(
                title: const Text('End of episode'),
                trailing: current.mode == SleepTimerMode.endOfEpisode
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, 'end'),
              ),
              ListTile(
                title: const Text('Off'),
                trailing: current.mode == SleepTimerMode.off
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, 'off'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    try {
      final message = switch (choice) {
        'end' => 'Sleep timer set for the end of this episode',
        'off' => 'Sleep timer off',
        _ =>
          'Sleep timer set for ${switch (int.parse(choice)) {
            60 => '1 hour',
            90 => '1 hour 30 minutes',
            final minutes => '$minutes minutes',
          }}',
      };
      if (choice == 'end') {
        await ref
            .read(audioHandlerProvider)
            .setSleepTimer(null, endOfEpisode: true);
      } else if (choice == 'off') {
        await ref.read(audioHandlerProvider).setSleepTimer(null);
      } else {
        await ref
            .read(audioHandlerProvider)
            .setSleepTimer(Duration(minutes: int.parse(choice)));
      }
      if (context.mounted) {
        showMessageSnackBar(context, message);
      }
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }

  Future<void> _bookmark(
    BuildContext context,
    WidgetRef ref,
    String episodeId,
    Duration position,
  ) async {
    var note = '';
    try {
      final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Bookmark at ${formatDuration(position)}'),
          content: TextField(
            autofocus: true,
            maxLength: 500,
            onChanged: (value) => note = value,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (save == true) {
        await ref
            .read(databaseProvider)
            .into(ref.read(databaseProvider).bookmarks)
            .insert(
              BookmarksCompanion.insert(
                id: const Uuid().v4(),
                episodeId: episodeId,
                positionMs: position.inMilliseconds,
                note: Value(note.trim().isEmpty ? null : note.trim()),
                createdAt: DateTime.now().toUtc(),
              ),
            );
        if (context.mounted) {
          showMessageSnackBar(context, 'Bookmark saved');
        }
      }
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }
}

final class _PlaybackProgress extends ConsumerStatefulWidget {
  const _PlaybackProgress({
    required this.episodeId,
    required this.fallbackDuration,
    required this.phase,
  });

  final String episodeId;
  final Duration fallbackDuration;
  final PlaybackUiPhase phase;

  @override
  ConsumerState<_PlaybackProgress> createState() => _PlaybackProgressState();
}

class _PlaybackProgressState extends ConsumerState<_PlaybackProgress> {
  int? _scrubPositionMs;

  @override
  void didUpdateWidget(covariant _PlaybackProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodeId != widget.episodeId) _scrubPositionMs = null;
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final duration =
        ref.watch(playbackDurationProvider).value ?? widget.fallbackDuration;
    final displayPosition = _scrubPositionMs == null
        ? position
        : Duration(milliseconds: _scrubPositionMs!);
    final max = duration.inMilliseconds
        .toDouble()
        .clamp(1, double.infinity)
        .toDouble();
    final sliderPosition = displayPosition.inMilliseconds
        .toDouble()
        .clamp(0, max)
        .toDouble();
    final remaining = duration > displayPosition
        ? duration - displayPosition
        : Duration.zero;
    final enabled =
        duration > Duration.zero &&
        !widget.phase.isBusy &&
        !widget.phase.isError;
    return Column(
      children: [
        Slider(
          value: sliderPosition,
          max: max,
          semanticFormatterCallback: (_) =>
              '${formatDuration(displayPosition)} of ${formatDuration(duration)}',
          onChangeStart: enabled
              ? (value) => setState(() => _scrubPositionMs = value.round())
              : null,
          onChanged: enabled
              ? (value) {
                  if (_scrubPositionMs == null) return;
                  setState(() => _scrubPositionMs = value.round());
                }
              : null,
          onChangeEnd: enabled
              ? (value) {
                  if (_scrubPositionMs != null) {
                    unawaited(_commitSeek(value.round()));
                  }
                }
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _TimeCode(formatDuration(displayPosition)),
              _TimeCode('-${formatDuration(remaining)}'),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _commitSeek(int milliseconds) async {
    final episodeId = widget.episodeId;
    try {
      if (ref.read(currentMediaProvider).value?.id != episodeId) return;
      await ref
          .read(audioHandlerProvider)
          .seekEpisode(episodeId, Duration(milliseconds: milliseconds));
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted && widget.episodeId == episodeId) {
        setState(() => _scrubPositionMs = null);
      }
    }
  }
}

final class _PrimaryPlaybackButton extends ConsumerWidget {
  const _PrimaryPlaybackButton({required this.playing, required this.phase});

  final bool playing;
  final PlaybackUiPhase phase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = phase.canToggle(playing: playing);
    final actionLabel = phase.actionLabel(playing: playing);
    final VoidCallback? onPressed = enabled
        ? () => _run(
            context,
            playing
                ? ref.read(audioHandlerProvider).pause
                : ref.read(audioHandlerProvider).play,
          )
        : null;
    return Semantics(
      button: true,
      liveRegion: true,
      enabled: enabled,
      label: actionLabel,
      value: phase.semanticStatus,
      excludeSemantics: true,
      onTap: onPressed,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: phase.isError ? AppConstants.danger : null,
          minimumSize: const Size.square(64),
          padding: EdgeInsets.zero,
          shape: const CutCornerBorder(cut: 15),
        ),
        onPressed: onPressed,
        child: Tooltip(
          message: actionLabel,
          child: phase.isBusy
              ? SizedBox.square(
                  dimension: 27,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: enabled
                        ? AppConstants.background
                        : AppConstants.secondaryText,
                  ),
                )
              : Icon(
                  phase.isError
                      ? Icons.refresh_rounded
                      : playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 36,
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

final class _TimeCode extends StatelessWidget {
  const _TimeCode(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Text(
        value,
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: AppConstants.secondaryText,
          fontSize: 11,
          letterSpacing: 0.7,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

final class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.backwards = false,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool backwards;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            backwards ? Icons.replay_rounded : Icons.forward_rounded,
            size: 34,
          ),
          Text(
            label,
            textScaler: TextScaler.noScaling,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

final class _PlaybackOptions extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repeatMode = ref.watch(
      playbackStateProvider.select((state) => state.value?.repeatMode),
    );
    return FilterChip(
      selected: repeatMode == AudioServiceRepeatMode.one,
      label: const Text('Repeat episode'),
      onSelected: (enabled) => _run(
        context,
        () => ref
            .read(audioHandlerProvider)
            .setRepeatMode(
              enabled
                  ? AudioServiceRepeatMode.one
                  : AudioServiceRepeatMode.none,
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

final class _Extras extends ConsumerStatefulWidget {
  const _Extras({required this.episodeId});

  final String episodeId;

  @override
  ConsumerState<_Extras> createState() => _ExtrasState();
}

class _ExtrasState extends ConsumerState<_Extras> {
  static const _transcriptPageSize = 100;
  bool _loadChapters = false;
  bool _loadShowNotes = false;
  bool _loadTranscript = false;
  int _transcriptLimit = _transcriptPageSize;
  final _transcriptSearch = TextEditingController();
  String _transcriptQuery = '';

  @override
  void dispose() {
    _transcriptSearch.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _Extras oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodeId != widget.episodeId) {
      _loadChapters = false;
      _loadShowNotes = false;
      _loadTranscript = false;
      _transcriptLimit = _transcriptPageSize;
      _transcriptSearch.clear();
      _transcriptQuery = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bookmarks = ref.watch(bookmarksProvider(widget.episodeId));
    final chapters = _loadChapters
        ? ref.watch(chaptersProvider(widget.episodeId))
        : null;
    final showNotes = _loadShowNotes
        ? ref.watch(episodeShowNotesProvider(widget.episodeId))
        : null;
    final transcript = _loadTranscript
        ? ref.watch(transcriptProvider(widget.episodeId))
        : null;
    final episode = ref.watch(episodeProvider(widget.episodeId)).value;
    final feed = episode == null
        ? null
        : ref.watch(feedProvider(episode.feedId)).value;
    final secret = feed?.isPrivate == true
        ? ref.watch(privateFeedSecretProvider(feed!.id)).value
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bookmarks.when(
          data: (items) => items.isEmpty
              ? const SizedBox.shrink()
              : ExpansionTile(
                  title: Text(
                    '${items.length} bookmark${items.length == 1 ? '' : 's'}',
                  ),
                  children: [
                    for (final bookmark in items)
                      ListTile(
                        leading: Text(
                          formatDuration(
                            Duration(milliseconds: bookmark.positionMs),
                          ),
                        ),
                        title: Text(bookmark.note ?? 'Saved position'),
                        onTap: () => _run(
                          () => ref
                              .read(audioHandlerProvider)
                              .seek(
                                Duration(milliseconds: bookmark.positionMs),
                              ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Delete bookmark',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => _run(
                            () =>
                                (ref
                                        .read(databaseProvider)
                                        .delete(
                                          ref.read(databaseProvider).bookmarks,
                                        )
                                      ..where(
                                        (row) => row.id.equals(bookmark.id),
                                      ))
                                    .go(),
                          ),
                        ),
                      ),
                  ],
                ),
          loading: () => const SizedBox.shrink(),
          error: (error, _) => InlineErrorView(
            friendlyError(error),
            title: 'Couldn’t load bookmarks',
            onRetry: () => ref.invalidate(bookmarksProvider(widget.episodeId)),
          ),
        ),
        ExpansionTile(
          title: const Text('Show notes'),
          onExpansionChanged: (expanded) {
            if (expanded && !_loadShowNotes) {
              setState(() => _loadShowNotes = true);
            }
          },
          children: [
            _showNotesBody(
              showNotes,
              secret: secret,
              allowRemoteImages:
                  feed != null && (!feed.isPrivate || secret != null),
            ),
          ],
        ),
        ExpansionTile(
          title: Text(
            chapters?.value?.isNotEmpty == true
                ? '${chapters!.value!.length} chapters'
                : 'Chapters',
          ),
          onExpansionChanged: (expanded) {
            if (expanded && !_loadChapters) {
              setState(() => _loadChapters = true);
            }
          },
          children: [_chaptersBody(chapters)],
        ),
        ExpansionTile(
          title: const Text('Transcript'),
          onExpansionChanged: (expanded) {
            if (expanded && !_loadTranscript) {
              setState(() => _loadTranscript = true);
            }
          },
          children: [_transcriptBody(transcript)],
        ),
      ],
    );
  }

  Widget _showNotesBody(
    AsyncValue<ExtractedArticle?>? showNotes, {
    required PrivateFeedSecret? secret,
    required bool allowRemoteImages,
  }) {
    return EpisodeShowNotes(
      value: showNotes ?? const AsyncLoading(),
      onRetry: () => ref.invalidate(episodeShowNotesProvider(widget.episodeId)),
      privateSecret: secret,
      allowRemoteImages: allowRemoteImages,
      scale: 0.85,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
    );
  }

  Widget _chaptersBody(AsyncValue<List<Chapter>>? chapters) {
    if (chapters == null || chapters.isLoading) {
      return const InlineLoadingView(label: 'Loading chapters');
    }
    if (chapters.hasError) {
      return InlineErrorView(
        friendlyError(chapters.error!),
        title: 'Couldn’t load chapters',
        onRetry: () => ref.invalidate(chaptersProvider(widget.episodeId)),
      );
    }
    final items = chapters.value ?? const [];
    if (items.isEmpty) {
      return const ListTile(title: Text('No chapters available'));
    }
    return Column(
      children: [
        for (final chapter in items)
          ListTile(
            title: Text(chapter.title),
            leading: Text(
              formatDuration(Duration(milliseconds: chapter.startMs)),
            ),
            onTap: () => _run(
              () => ref
                  .read(audioHandlerProvider)
                  .seek(Duration(milliseconds: chapter.startMs)),
            ),
          ),
      ],
    );
  }

  Widget _transcriptBody(AsyncValue<TranscriptDocument?>? transcript) {
    if (transcript == null || transcript.isLoading) {
      return const InlineLoadingView(label: 'Loading transcript');
    }
    if (transcript.hasError) {
      return InlineErrorView(
        friendlyError(transcript.error!),
        title: 'Couldn’t load transcript',
        onRetry: () => ref.invalidate(transcriptProvider(widget.episodeId)),
      );
    }
    final document = transcript.value;
    if (document == null || document.segments.isEmpty) {
      return const ListTile(title: Text('No transcript available'));
    }
    final query = _transcriptQuery.trim().toLowerCase();
    final matches = query.isEmpty
        ? document.segments
        : document.segments
              .where(
                (segment) =>
                    segment.text.toLowerCase().contains(query) ||
                    (segment.speaker?.toLowerCase().contains(query) ?? false),
              )
              .toList();
    final visible = matches.take(_transcriptLimit).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SearchBar(
            controller: _transcriptSearch,
            hintText: 'Search transcript',
            leading: const Icon(Icons.search_rounded),
            trailing: [
              if (_transcriptQuery.isNotEmpty)
                IconButton(
                  tooltip: 'Clear transcript search',
                  onPressed: () {
                    _transcriptSearch.clear();
                    setState(() => _transcriptQuery = '');
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
            onChanged: (value) => setState(() {
              _transcriptQuery = value;
              _transcriptLimit = _transcriptPageSize;
            }),
          ),
          const SizedBox(height: 10),
          if (matches.isEmpty)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('No transcript matches'),
            )
          else if (!document.hasTiming)
            SelectableText(
              visible.map((segment) => segment.text).join('\n\n'),
              style: const TextStyle(
                height: 1.55,
                color: AppConstants.secondaryText,
              ),
            )
          else
            for (final segment in visible)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: segment.startMs == null
                    ? null
                    : Text(
                        formatDuration(
                          Duration(milliseconds: segment.startMs!),
                        ),
                      ),
                title: Text(segment.text),
                subtitle: segment.speaker == null
                    ? null
                    : Text(segment.speaker!),
                onTap: segment.startMs == null
                    ? null
                    : () => _run(
                        () => ref
                            .read(audioHandlerProvider)
                            .seek(Duration(milliseconds: segment.startMs!)),
                      ),
              ),
          if (visible.length < matches.length)
            TextButton.icon(
              onPressed: () => setState(
                () => _transcriptLimit = math.min(
                  matches.length,
                  _transcriptLimit + _transcriptPageSize,
                ),
              ),
              icon: const Icon(Icons.expand_more_rounded),
              label: Text(
                'Show ${math.min(_transcriptPageSize, matches.length - visible.length)} more',
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    }
  }
}
