import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/youtube_support.dart';
import '../widgets/common.dart';
import '../widgets/content_tiles.dart';

final class PodcastsPage extends ConsumerWidget {
  const PodcastsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feeds = ref.watch(podcastFeedsProvider);
    final episodes = ref.watch(recentEpisodesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Podcasts'),
        actions: [
          IconButton(
            tooltip: 'Add feed',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AddFeedDialog(),
            ),
            icon: const Icon(Icons.add_rounded),
          ),
          IconButton(
            tooltip: 'Find podcasts',
            onPressed: () => context.push('/search?tab=podcasts'),
            icon: const Icon(Icons.search_rounded),
          ),
        ],
      ),
      body: AppBackdrop(
        child: RefreshIndicator(
          onRefresh: () => refreshAllFeeds(context, ref),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              const SliverToBoxAdapter(child: SectionHeader('Subscriptions')),
              feeds.when(
                data: (items) => items.isEmpty
                    ? SliverToBoxAdapter(
                        child: EmptyState(
                          icon: Icons.radar_rounded,
                          title: 'No podcasts',
                          message:
                              'Search the catalog or add a publisher RSS URL.',
                          action: 'Find podcasts',
                          onAction: () => context.push('/search?tab=podcasts'),
                        ),
                      )
                    : SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) =>
                            PodcastTile(items[index]),
                      ),
                loading: () => const SliverToBoxAdapter(
                  child: SizedBox(height: 220, child: LoadingView()),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: ErrorView(
                    friendlyError(error),
                    onRetry: () => ref.invalidate(podcastFeedsProvider),
                  ),
                ),
              ),
              if (feeds.value?.isNotEmpty == true) ...[
                const SliverToBoxAdapter(
                  child: SectionHeader('Recent Episodes'),
                ),
                episodes.when(
                  data: (items) => items.isEmpty
                      ? const SliverToBoxAdapter(
                          child: EmptyState(
                            icon: Icons.multitrack_audio_rounded,
                            title: 'No episodes yet',
                            message:
                                'Refresh a subscription or subscribe to a podcast.',
                            compact: true,
                          ),
                        )
                      : SliverList.builder(
                          itemCount: items.length,
                          itemBuilder: (context, index) =>
                              EpisodeTile(items[index]),
                        ),
                  loading: () => const SliverToBoxAdapter(
                    child: SizedBox(height: 180, child: LoadingView()),
                  ),
                  error: (error, _) => SliverToBoxAdapter(
                    child: ErrorView(
                      friendlyError(error),
                      onRetry: () => ref.invalidate(recentEpisodesProvider),
                    ),
                  ),
                ),
              ],
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ],
          ),
        ),
      ),
    );
  }
}

final class AddFeedDialog extends ConsumerStatefulWidget {
  const AddFeedDialog({this.youtubeOnly = false, super.key});

  const AddFeedDialog.youtube({super.key}) : youtubeOnly = true;

  final bool youtubeOnly;

  @override
  ConsumerState<AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends ConsumerState<AddFeedDialog> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _bearer = TextEditingController();
  bool _private = false;
  bool _busy = false;
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
      title: Text(widget.youtubeOnly ? 'Add YouTube feed' : 'Add feed'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.youtubeOnly) ...[
                const Text(
                  'Paste a public YouTube channel or playlist. trickle finds its feed automatically.',
                ),
                const SizedBox(height: 14),
              ],
              TextField(
                controller: _url,
                enabled: !_busy,
                onChanged: (_) => _clearError(),
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: widget.youtubeOnly
                      ? 'YouTube channel or playlist URL'
                      : 'Feed or website URL',
                  hintText: widget.youtubeOnly
                      ? 'youtube.com/@channel or playlist URL'
                      : 'RSS, Atom, JSON Feed, or website',
                ),
              ),
              if (!widget.youtubeOnly)
                SwitchListTile(
                  value: _private,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _private = value;
                          _error = null;
                        }),
                  title: const Text('Private feed'),
                  subtitle: const Text(
                    'The full feed URL and any credentials are stored securely on this device.',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              if (_private) ...[
                TextField(
                  controller: _username,
                  enabled: !_busy,
                  onChanged: (_) => _clearError(),
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Username (Basic auth)',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  onChanged: (_) => _clearError(),
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
                  enabled: !_busy,
                  onChanged: (_) => _clearError(),
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Bearer token'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                InlineErrorView(_error!, title: 'Couldn’t subscribe'),
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
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Subscribing…' : 'Subscribe'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_busy) return;
    final url = _url.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    final bearer = _bearer.text.trim();
    if (url.isEmpty) {
      setState(
        () => _error = widget.youtubeOnly
            ? 'Enter a public YouTube channel or playlist URL.'
            : 'Enter an RSS feed or website.',
      );
      return;
    }
    final candidate = Uri.tryParse(
      Uri.tryParse(url)?.hasScheme == true ? url : 'https://$url',
    );
    if (candidate == null || candidate.host.isEmpty) {
      setState(() => _error = 'Enter a valid feed or website address.');
      return;
    }
    if (!const {'http', 'https'}.contains(candidate.scheme.toLowerCase())) {
      setState(() => _error = 'Use an HTTP or HTTPS address.');
      return;
    }
    if (widget.youtubeOnly && youtubeFeedKind(candidate) == null) {
      setState(
        () => _error =
            'Enter a YouTube channel, playlist, or YouTube Atom feed URL.',
      );
      return;
    }
    if (candidate.userInfo.isNotEmpty) {
      setState(
        () => _error =
            'Remove the username and password from the URL. Use the Private feed fields instead.',
      );
      return;
    }
    if (_private && username.isNotEmpty != password.isNotEmpty) {
      setState(
        () =>
            _error = 'Basic authentication needs both a username and password.',
      );
      return;
    }
    if (_private && username.isNotEmpty && bearer.isNotEmpty) {
      setState(
        () => _error = 'Use Basic authentication or a bearer token, not both.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final feed = await ref
          .read(feedRepositoryProvider)
          .subscribe(
            candidate.toString(),
            username: _private ? username : null,
            password: _private ? password : null,
            bearerToken: _private ? bearer : null,
            forcePrivate: _private,
          );
      if (!mounted) return;
      final kind =
          FeedKind.values[feed.kind.clamp(0, FeedKind.values.length - 1)];
      final route = kind == FeedKind.podcast
          ? '/podcast/${feed.id}'
          : '/feed/${feed.id}';
      final router = GoRouter.of(context);
      Navigator.pop(context);
      router.push(route);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = friendlyError(error);
        });
      }
    }
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }
}
