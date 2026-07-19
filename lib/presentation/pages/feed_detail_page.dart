import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:drift/drift.dart' hide Column;

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../data/database/app_database.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';

Future<void> deleteSubscriptionThenCleanup({
  required Future<void> Function() deleteSubscription,
  required Iterable<Future<void> Function()> cleanupOperations,
}) async {
  await deleteSubscription();
  for (final cleanup in cleanupOperations) {
    try {
      await cleanup();
    } on Object {
      // The database commit is authoritative. Continue best-effort cleanup
      // without presenting a failed deletion for a subscription that is gone.
    }
  }
}

Future<bool> _confirmUnsubscribe(BuildContext context, Feed feed) async {
  final kind = FeedKind.values[feed.kind.clamp(0, FeedKind.values.length - 1)];
  final noun = switch (kind) {
    FeedKind.podcast => 'podcast',
    FeedKind.reader => 'feed',
  };
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Unsubscribe from this $noun?'),
          content: const Text(
            'This removes its episodes, articles, playback and reading progress, Up Next items, downloads, and private credentials from this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppConstants.danger,
                foregroundColor: AppConstants.background,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Unsubscribe'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> _removeSubscription(WidgetRef ref, Feed feed) async {
  final database = ref.read(databaseProvider);
  final episodeIds =
      await (database.selectOnly(database.episodes)
            ..addColumns([database.episodes.id])
            ..where(database.episodes.feedId.equals(feed.id)))
          .map((row) => row.read(database.episodes.id)!)
          .get();
  final downloadRows =
      await (database.select(database.mediaDownloads).join([
            innerJoin(
              database.episodes,
              database.episodes.id.equalsExp(database.mediaDownloads.episodeId),
            ),
          ])..where(database.episodes.feedId.equals(feed.id)))
          .map((row) => row.readTable(database.mediaDownloads))
          .get();
  await deleteSubscriptionThenCleanup(
    deleteSubscription: () =>
        ref.read(feedRepositoryProvider).deleteFeed(feed.id),
    cleanupOperations: [
      () =>
          ref.read(audioHandlerProvider).removeEpisodesFromLibrary(episodeIds),
      () => ref
          .read(downloadCoordinatorProvider)
          .discardTasksForDeletedEpisodes(downloadRows),
    ],
  );
}

/// Detail surface shared by podcast and reading feeds.
final class FeedDetailPage extends ConsumerStatefulWidget {
  const FeedDetailPage({required this.feedId, super.key});

  final String feedId;

  @override
  ConsumerState<FeedDetailPage> createState() => _FeedDetailPageState();
}

class _FeedDetailPageState extends ConsumerState<FeedDetailPage> {
  static const _pageSize = 100;
  int _limit = _pageSize;
  bool _unsubscribing = false;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    final feed = ref.watch(feedProvider(widget.feedId));
    final page = (feedId: widget.feedId, limit: _limit);
    final kind = feed.value == null
        ? null
        : FeedKind.values[feed.value!.kind.clamp(
            0,
            FeedKind.values.length - 1,
          )];
    final canShowEpisodes = kind == FeedKind.podcast;
    final canShowArticles = kind == FeedKind.reader;
    final AsyncValue<List<Episode>> episodes = canShowEpisodes
        ? ref.watch(episodesForFeedProvider(page))
        : const AsyncData([]);
    final AsyncValue<List<Article>> articles = canShowArticles
        ? ref.watch(articlesForFeedProvider(page))
        : const AsyncData([]);
    final episodeTotal = canShowEpisodes
        ? ref.watch(episodeCountForFeedProvider(widget.feedId)).value ?? 0
        : 0;
    final articleTotal = canShowArticles
        ? ref.watch(articleCountForFeedProvider(widget.feedId)).value ?? 0
        : 0;
    final showEpisodes =
        canShowEpisodes &&
        (episodes.isLoading ||
            episodes.hasError ||
            episodes.value?.isNotEmpty == true);
    final showArticles =
        canShowArticles &&
        (articles.isLoading ||
            articles.hasError ||
            articles.value?.isNotEmpty == true);
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (kind) {
          FeedKind.reader => 'Feed',
          FeedKind.podcast => 'Podcast',
          null => 'Subscription',
        }),
        actions: [
          if (!largeText && feed.value != null)
            _SubscriptionControl(
              feedTitle: feed.value!.title,
              unsubscribing: _unsubscribing,
              onPressed: () => _unsubscribe(feed.value!),
            ),
          IconButton(
            tooltip: switch (kind) {
              FeedKind.podcast => 'Podcast settings',
              _ => 'Feed settings',
            },
            onPressed: feed.value == null
                ? null
                : () async {
                    final deleted = await showModalBottomSheet<bool>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => FeedSettingsSheet(feed: feed.value!),
                    );
                    if (deleted != true || !context.mounted) return;
                    if (context.canPop()) {
                      context.pop();
                    } else {
                      context.go('/');
                    }
                  },
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: AppBackdrop(
        child: feed.when(
          data: (value) {
            if (value == null) {
              return const EmptyState(
                icon: Icons.rss_feed_rounded,
                title: 'Subscription unavailable',
                message: 'This subscription is no longer on this device.',
              );
            }
            return RefreshIndicator(
              onRefresh: () => _refresh(value),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: _FeedHero(
                      feed: value,
                      subscriptionControl: largeText
                          ? MediaQuery.withClampedTextScaling(
                              maxScaleFactor: 2,
                              child: _SubscriptionControl(
                                feedTitle: value.title,
                                unsubscribing: _unsubscribing,
                                onPressed: () => _unsubscribe(value),
                              ),
                            )
                          : null,
                    ),
                  ),
                  if (showEpisodes) ...[
                    const SliverToBoxAdapter(child: SectionHeader('Episodes')),
                    episodes.when(
                      data: (items) => SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (_, index) =>
                            EpisodeTile(items[index], showSource: false),
                      ),
                      loading: () => const SliverToBoxAdapter(
                        child: SizedBox(height: 180, child: LoadingView()),
                      ),
                      error: (error, _) => SliverToBoxAdapter(
                        child: ErrorView(
                          friendlyError(error),
                          onRetry: () =>
                              ref.invalidate(episodesForFeedProvider(page)),
                        ),
                      ),
                    ),
                  ],
                  if (showArticles) ...[
                    const SliverToBoxAdapter(child: SectionHeader('Articles')),
                    articles.when(
                      data: (items) => SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (_, index) =>
                            ArticleTile(items[index], showSource: false),
                      ),
                      loading: () => const SliverToBoxAdapter(
                        child: SizedBox(height: 120, child: LoadingView()),
                      ),
                      error: (error, _) => SliverToBoxAdapter(
                        child: ErrorView(
                          friendlyError(error),
                          onRetry: () =>
                              ref.invalidate(articlesForFeedProvider(page)),
                        ),
                      ),
                    ),
                  ],
                  if (!showEpisodes && !showArticles)
                    const SliverFillRemaining(
                      child: EmptyState(
                        icon: Icons.hourglass_empty_rounded,
                        title: 'No entries yet',
                        message: 'Pull down to refresh this feed.',
                      ),
                    ),
                  if ((canShowEpisodes &&
                          (episodes.value?.length ?? 0) < episodeTotal) ||
                      (canShowArticles &&
                          (articles.value?.length ?? 0) < articleTotal))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: OutlinedButton.icon(
                          onPressed: () => setState(() => _limit += _pageSize),
                          icon: const Icon(Icons.expand_more_rounded),
                          label: const Text('Load older items'),
                        ),
                      ),
                    ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
                ],
              ),
            );
          },
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(
            friendlyError(error),
            onRetry: () => ref.invalidate(feedProvider(widget.feedId)),
          ),
        ),
      ),
    );
  }

  Future<void> _unsubscribe(Feed feed) async {
    if (_unsubscribing || !await _confirmUnsubscribe(context, feed)) return;
    setState(() => _unsubscribing = true);
    try {
      await _removeSubscription(ref, feed);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/');
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _unsubscribing = false);
    }
  }

  Future<void> _refresh(Feed feed) async {
    try {
      final result = await ref.read(syncCoordinatorProvider).refreshFeed(feed);
      if (result.failedFeeds > 0 && mounted) {
        showMessageSnackBar(
          context,
          'Couldn’t refresh this feed. Check the error below.',
        );
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    }
  }
}

final class _FeedHero extends StatelessWidget {
  const _FeedHero({required this.feed, this.subscriptionControl});

  final Feed feed;
  final Widget? subscriptionControl;

  @override
  Widget build(BuildContext context) {
    final stackIdentity = MediaQuery.textScalerOf(context).scale(1) > 1.8;
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stackIdentity) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FeedArtwork(feed: feed, size: 88, radius: 8),
                  if (subscriptionControl != null) ...[
                    const SizedBox(width: 14),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topRight,
                        child: subscriptionControl,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              _FeedIdentity(feed: feed),
              const SizedBox(height: 14),
              _FeedDescription(feed: feed),
            ] else if (constraints.maxWidth < 460) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FeedArtwork(feed: feed, size: 88, radius: 8),
                  const SizedBox(width: 14),
                  Expanded(child: _FeedIdentity(feed: feed)),
                ],
              ),
              const SizedBox(height: 14),
              _FeedDescription(feed: feed),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FeedArtwork(feed: feed, size: 124, radius: 10),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FeedIdentity(feed: feed),
                        const SizedBox(height: 12),
                        _FeedDescription(feed: feed),
                      ],
                    ),
                  ),
                ],
              ),
            if (feed.refreshError != null) ...[
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppConstants.danger.withValues(alpha: 0.07),
                  border: const Border(
                    left: BorderSide(color: AppConstants.danger, width: 2),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      feed.refreshError!,
                      style: const TextStyle(
                        color: AppConstants.danger,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _FeedIdentity extends StatelessWidget {
  const _FeedIdentity({required this.feed});

  final Feed feed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 2.4,
            child: Text(
              feed.title,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
        if (feed.author?.isNotEmpty == true) ...[
          const SizedBox(height: 7),
          Text(
            feed.author!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppConstants.cyan,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

final class _SubscriptionControl extends StatelessWidget {
  const _SubscriptionControl({
    required this.feedTitle,
    required this.unsubscribing,
    required this.onPressed,
  });

  final String feedTitle;
  final bool unsubscribing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = unsubscribing
        ? AppConstants.secondaryText
        : AppConstants.cyan;
    return Semantics(
      button: true,
      enabled: !unsubscribing,
      label: unsubscribing
          ? 'Unsubscribing from $feedTitle'
          : 'Subscribed to $feedTitle. Unsubscribe',
      excludeSemantics: true,
      child: Tooltip(
        message: unsubscribing ? 'Unsubscribing' : 'Unsubscribe',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: unsubscribing ? null : onPressed,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: DecoratedBox(
                  key: const ValueKey('subscription-pill'),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.06),
                    border: Border.all(color: color.withValues(alpha: 0.52)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 28),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (unsubscribing)
                            const SizedBox.square(
                              dimension: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            const Icon(Icons.check_rounded, size: 14),
                          const SizedBox(width: 5),
                          Text(
                            unsubscribing ? 'Unsubscribing…' : 'Subscribed',
                            style: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(color: color),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _FeedDescription extends StatelessWidget {
  const _FeedDescription({required this.feed});

  final Feed feed;

  @override
  Widget build(BuildContext context) {
    return Text(
      feed.description?.trim().isNotEmpty == true
          ? feed.description!
          : 'RSS subscription',
      maxLines: 5,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: AppConstants.secondaryText, height: 1.45),
    );
  }
}

final class FeedSettingsSheet extends ConsumerStatefulWidget {
  const FeedSettingsSheet({required this.feed, super.key});

  final Feed feed;

  @override
  ConsumerState<FeedSettingsSheet> createState() => _FeedSettingsSheetState();
}

enum _FeedSettingsOperation { notifications, save, privateAccess, unsubscribe }

class _FeedSettingsSheetState extends ConsumerState<FeedSettingsSheet> {
  late bool _autoDownload = widget.feed.autoDownload;
  late bool _notifications = widget.feed.notifications;
  late bool _autoQueue = widget.feed.autoQueue;
  late int _limit = widget.feed.autoDownloadLimit;
  late final TextEditingController _intro = TextEditingController(
    text: '${widget.feed.introSkipMs ~/ 1000}',
  );
  late final TextEditingController _outro = TextEditingController(
    text: '${widget.feed.outroSkipMs ~/ 1000}',
  );
  _FeedSettingsOperation? _operation;

  bool get _busy => _operation != null;

  FeedKind get _kind =>
      FeedKind.values[widget.feed.kind.clamp(0, FeedKind.values.length - 1)];

  bool get _isReader => _kind == FeedKind.reader;

  @override
  void dispose() {
    _intro.dispose();
    _outro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(switch (_kind) {
                  FeedKind.reader => 'Feed settings',
                  FeedKind.podcast => 'Podcast settings',
                }, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 14),
                if (!_isReader) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _autoDownload,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _autoDownload = value),
                    title: const Text('Automatically download new episodes'),
                    subtitle: const Text('Wi-Fi only; stored by trickle.'),
                  ),
                  if (_autoDownload)
                    AdaptiveDropdownFormField<int>(
                      initialValue: _limit,
                      label: 'Maximum new episodes per refresh',
                      items: [1, 2, 3, 5, 10]
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(
                                '$value ${value == 1 ? 'episode' : 'episodes'}',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _limit = value ?? 3),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _autoQueue,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _autoQueue = value),
                    title: const Text('Add new episodes to Up Next'),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notifications,
                  onChanged: _busy ? null : _setNotifications,
                  secondary: SizedBox.square(
                    dimension: 24,
                    child: _operation == _FeedSettingsOperation.notifications
                        ? const CircularProgressIndicator(strokeWidth: 2)
                        : const Icon(Icons.notifications_outlined),
                  ),
                  title: Text(switch (_kind) {
                    FeedKind.reader => 'New article notifications',
                    FeedKind.podcast => 'New episode notifications',
                  }),
                  subtitle: const Text(
                    'Alerts depend on iOS or Android background scheduling.',
                  ),
                ),
                if (!_isReader) ...[
                  const SizedBox(height: 10),
                  Column(
                    children: [
                      TextField(
                        enabled: !_busy,
                        controller: _intro,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Skip intro (seconds)',
                          helperText: '0–600',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        enabled: !_busy,
                        controller: _outro,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Skip outro (seconds)',
                          helperText: '0–600',
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                if (widget.feed.isPrivate)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _updatePrivateAccess,
                    icon: const Icon(Icons.key_rounded),
                    label: Text(
                      _operation == _FeedSettingsOperation.privateAccess
                          ? 'Updating access…'
                          : 'Update private access',
                    ),
                  ),
                if (widget.feed.isPrivate) const SizedBox(height: 10),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(
                    _operation == _FeedSettingsOperation.save
                        ? 'Saving…'
                        : 'Save settings',
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: AppConstants.danger,
                  ),
                  onPressed: _busy ? null : _unsubscribe,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(
                    _operation == _FeedSettingsOperation.unsubscribe
                        ? 'Unsubscribing…'
                        : 'Unsubscribe and delete local data',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final intro = int.tryParse(_intro.text.trim().isEmpty ? '0' : _intro.text);
    final outro = int.tryParse(_outro.text.trim().isEmpty ? '0' : _outro.text);
    if (intro == null || outro == null || intro > 600 || outro > 600) {
      showMessageSnackBar(
        context,
        'Skip times must be between 0 and 10 minutes (600 seconds).',
      );
      return;
    }
    setState(() => _operation = _FeedSettingsOperation.save);
    try {
      await ref
          .read(feedRepositoryProvider)
          .updateFeedSettings(
            widget.feed.id,
            autoDownload: _autoDownload,
            autoDownloadLimit: _limit,
            notifications: _notifications,
            introSkipMs: intro * 1000,
            outroSkipMs: outro * 1000,
            autoQueue: _autoQueue,
          );
      if (!mounted) return;
      setState(() => _operation = null);
      Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      _finishOperation(_FeedSettingsOperation.save);
    }
  }

  Future<void> _setNotifications(bool value) async {
    if (!value) {
      setState(() => _notifications = false);
      return;
    }
    setState(() => _operation = _FeedSettingsOperation.notifications);
    try {
      final enabled = await ref
          .read(notificationServiceProvider)
          .requestPermission();
      if (!mounted) return;
      setState(() => _notifications = enabled);
      if (!enabled) {
        showMessageSnackBar(context, 'Notifications remain disabled');
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _notifications = false);
      showErrorSnackBar(context, error);
    } finally {
      _finishOperation(_FeedSettingsOperation.notifications);
    }
  }

  Future<void> _updatePrivateAccess() async {
    if (_busy) return;
    setState(() => _operation = _FeedSettingsOperation.privateAccess);
    try {
      final secret = await ref.read(
        privateFeedSecretProvider(widget.feed.id).future,
      );
      if (!mounted) return;
      final replacement = await showDialog<_PrivateAccessInput>(
        context: context,
        builder: (_) =>
            _PrivateAccessDialog(initialUrl: secret?.url.toString() ?? ''),
      );
      if (replacement == null || !mounted) return;
      await ref
          .read(feedRepositoryProvider)
          .updatePrivateAccess(
            widget.feed.id,
            replacement.url,
            username: replacement.username,
            password: replacement.password,
            bearerToken: replacement.bearer,
          );
      ref.invalidate(privateFeedSecretProvider(widget.feed.id));
      if (!mounted) return;
      showMessageSnackBar(context, 'Private access updated.');
    } on Object catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      _finishOperation(_FeedSettingsOperation.privateAccess);
    }
  }

  Future<void> _unsubscribe() async {
    if (!await _confirmUnsubscribe(context, widget.feed) || !mounted) return;
    setState(() => _operation = _FeedSettingsOperation.unsubscribe);
    try {
      await _removeSubscription(ref, widget.feed);
      if (!mounted) return;
      setState(() => _operation = null);
      Navigator.pop(context, true);
    } on Object catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      _finishOperation(_FeedSettingsOperation.unsubscribe);
    }
  }

  void _finishOperation(_FeedSettingsOperation operation) {
    if (mounted && _operation == operation) {
      setState(() => _operation = null);
    }
  }
}

typedef _PrivateAccessInput = ({
  String url,
  String username,
  String password,
  String bearer,
});

final class _PrivateAccessDialog extends StatefulWidget {
  const _PrivateAccessDialog({required this.initialUrl});

  final String initialUrl;

  @override
  State<_PrivateAccessDialog> createState() => _PrivateAccessDialogState();
}

class _PrivateAccessDialogState extends State<_PrivateAccessDialog> {
  late final TextEditingController _url = TextEditingController(
    text: widget.initialUrl,
  );
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _bearer = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _bearer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Update private access'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Private feed URL',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'For a URL token, leave the fields below blank. For Basic or Bearer authentication, enter the replacement credentials.',
                style: TextStyle(
                  color: AppConstants.secondaryText,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Username (Basic auth)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'OR',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppConstants.secondaryText,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              TextField(
                controller: _bearer,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Bearer token'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: const TextStyle(color: AppConstants.danger),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Verify and update'),
        ),
      ],
    );
  }

  void _submit() {
    final rawUrl = _url.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    final bearer = _bearer.text.trim();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      setState(() => _error = 'Enter a valid HTTP or HTTPS feed URL.');
      return;
    }
    if (username.isNotEmpty != password.isNotEmpty) {
      setState(
        () => _error = 'Basic authentication needs a username and password.',
      );
      return;
    }
    if (username.isNotEmpty && bearer.isNotEmpty) {
      setState(
        () => _error = 'Use Basic authentication or a bearer token, not both.',
      );
      return;
    }
    Navigator.pop(context, (
      url: rawUrl,
      username: username,
      password: password,
      bearer: bearer,
    ));
  }
}
