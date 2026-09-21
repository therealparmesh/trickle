import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/feed_category.dart';
import '../../core/nostr_identifier.dart';
import '../../core/youtube_support.dart';
import '../../data/database/app_database.dart';
import 'common.dart';
import 'feed_category_field.dart';

final class AddFeedDialog extends ConsumerStatefulWidget {
  const AddFeedDialog({this.initialInput, super.key})
    : youtubeOnly = false,
      podcastIntent = false;

  const AddFeedDialog.youtube({super.key})
    : youtubeOnly = true,
      podcastIntent = false,
      initialInput = null;

  const AddFeedDialog.podcast({super.key})
    : youtubeOnly = false,
      podcastIntent = true,
      initialInput = null;

  final bool youtubeOnly;
  final bool podcastIntent;
  final String? initialInput;

  @override
  ConsumerState<AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends ConsumerState<AddFeedDialog> {
  late final TextEditingController _url;
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _bearer = TextEditingController();
  final _category = TextEditingController();
  final _categoryFocus = FocusNode();
  bool _private = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialInput);
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _bearer.dispose();
    _category.dispose();
    _categoryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categoryOptions = widget.podcastIntent
        ? const <String>[]
        : feedCategoryOptions(
            (ref.watch(readerFeedsProvider).value ?? const <Feed>[]).map(
              (feed) => feed.category,
            ),
          );
    return AlertDialog(
      title: Text(
        widget.youtubeOnly
            ? 'Add YouTube feed'
            : widget.podcastIntent
            ? 'Add podcast URL'
            : 'Add feed',
      ),
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
                const SizedBox(height: AppSpacing.md),
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
                      : widget.podcastIntent
                      ? 'Podcast RSS URL'
                      : 'Feed, website, or Nostr profile',
                  hintText: widget.youtubeOnly
                      ? 'youtube.com/@channel or playlist URL'
                      : widget.podcastIntent
                      ? 'https://publisher.com/podcast.xml'
                      : 'RSS, Atom, JSON Feed, website, npub, or nprofile',
                ),
              ),
              if (!widget.podcastIntent) ...[
                const SizedBox(height: AppSpacing.md),
                FeedCategoryField(
                  controller: _category,
                  focusNode: _categoryFocus,
                  options: categoryOptions,
                  enabled: !_busy,
                ),
              ],
              if (!widget.youtubeOnly)
                AdaptiveSwitchTile(
                  value: _private,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _private = value;
                          _error = null;
                        }),
                  title: 'Private feed',
                  subtitle:
                      'trickle doesn’t collect your feed URL or credentials.',
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
                const SizedBox(height: AppSpacing.sm),
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
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
                const SizedBox(height: AppSpacing.md),
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
            : widget.podcastIntent
            ? 'Enter a podcast RSS URL.'
            : 'Enter a feed, website, or Nostr profile.',
      );
      return;
    }
    if (widget.podcastIntent && looksLikeNostrProfile(url)) {
      setState(() => _error = 'Enter a podcast RSS URL.');
      return;
    }
    if (!widget.youtubeOnly && looksLikeNostrProfile(url) && _private) {
      setState(
        () => _error =
            'Nostr profiles are public. Turn off Private feed to continue.',
      );
      return;
    }
    if (!widget.youtubeOnly && looksLikeNostrProfile(url)) {
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        final feed = await ref
            .read(nostrRepositoryProvider)
            .subscribe(url, category: _category.text);
        if (!mounted) return;
        final router = GoRouter.of(context);
        Navigator.pop(context);
        unawaited(router.push('/feed/${feed.id}'));
      } on Object catch (error) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = friendlyError(error);
          });
        }
      }
      return;
    }
    final candidate = Uri.tryParse(
      Uri.tryParse(url)?.hasScheme == true ? url : 'https://$url',
    );
    if (candidate == null || candidate.host.isEmpty) {
      setState(
        () => _error = widget.podcastIntent
            ? 'Enter a valid podcast RSS address.'
            : 'Enter a valid feed or website address.',
      );
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
            expectedKind: widget.youtubeOnly ? FeedKind.reader : null,
            category: widget.podcastIntent ? null : _category.text,
          );
      if (!mounted) return;
      final kind =
          FeedKind.values[feed.kind.clamp(0, FeedKind.values.length - 1)];
      final router = GoRouter.of(context);
      if (!widget.youtubeOnly &&
          widget.initialInput == null &&
          (kind == FeedKind.podcast) != widget.podcastIntent) {
        showMessageSnackBar(
          context,
          kind == FeedKind.podcast
              ? 'This is a podcast. Added to Podcasts.'
              : 'This is a feed. Added to Feeds.',
        );
      }
      Navigator.pop(context);
      unawaited(router.push('/feed/${feed.id}'));
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
