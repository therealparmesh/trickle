import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../services/opml_service.dart';
import '../widgets/common.dart';

final class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final Set<String> _busyActions = {};
  String? _refreshProgress;
  String? _opmlProgress;

  @override
  Widget build(BuildContext context) {
    final speed = ref.watch(speedProvider).value ?? AppConstants.defaultSpeed;
    final autoDelete =
        ref.watch(autoDeleteProvider).value ?? AutoDeletePolicy.after1Day;
    final refresh =
        ref.watch(refreshIntervalProvider).value ?? RefreshInterval.every4Hours;
    final images = ref.watch(remoteImagesProvider).value ?? true;
    final package = ref.watch(packageInfoProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AppBackdrop(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
              children: [
                const SectionHeader('Playback'),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Playback speed'),
                      const SizedBox(height: 10),
                      PlaybackSpeedSelector(
                        selected: speed,
                        onSelected: (value) => _runSilent(
                          context,
                          () => ref
                              .read(audioHandlerProvider)
                              .setSpeed(value / 100),
                        ),
                      ),
                      const SizedBox(height: 20),
                      AdaptiveDropdownFormField<AutoDeletePolicy>(
                        initialValue: autoDelete,
                        label: 'Remove played downloads',
                        items: AutoDeletePolicy.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(
                                  _autoDeleteLabel(value),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) async {
                          if (value == null) return;
                          await _runSilent(context, () async {
                            await ref
                                .read(settingsRepositoryProvider)
                                .setAutoDelete(value);
                            await ref
                                .read(downloadCoordinatorProvider)
                                .cleanupPlayed();
                          });
                        },
                      ),
                    ],
                  ),
                ),
                const SectionHeader('Feeds'),
                AppCard(
                  child: Column(
                    children: [
                      AdaptiveDropdownFormField<RefreshInterval>(
                        initialValue: refresh,
                        label: 'Background refresh',
                        helperText:
                            'Scheduled by your device; timing is approximate.',
                        items: RefreshInterval.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value.label),
                              ),
                            )
                            .toList(),
                        onChanged: (value) async {
                          if (value == null) return;
                          await _runSilent(
                            context,
                            () => ref
                                .read(settingsRepositoryProvider)
                                .setRefreshInterval(value),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: images,
                        onChanged: (value) => _runSilent(
                          context,
                          () => ref
                              .read(settingsRepositoryProvider)
                              .setRemoteImages(value),
                        ),
                        title: const Text('Remote images'),
                        subtitle: const Text(
                          'Loads artwork, reader images, show-note images, and link previews from publishers.',
                        ),
                      ),
                      _ActionTile(
                        icon: Icons.sync_rounded,
                        title: 'Refresh now',
                        subtitle:
                            _refreshProgress ??
                            'Checks every subscription for new items.',
                        busy: _busyActions.contains('refresh'),
                        onTap: _busyActions.contains('refresh')
                            ? null
                            : () async {
                                setState(
                                  () => _refreshProgress = 'Starting refresh…',
                                );
                                try {
                                  await _runTracked(
                                    context,
                                    'refresh',
                                    () => refreshAllFeeds(
                                      context,
                                      ref,
                                      announceSuccess: true,
                                      onProgress: (completed, total) {
                                        if (!mounted) return;
                                        setState(
                                          () => _refreshProgress = total == 0
                                              ? 'No subscriptions to refresh'
                                              : 'Refreshing $completed of $total',
                                        );
                                      },
                                    ),
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() => _refreshProgress = null);
                                  }
                                }
                              },
                      ),
                      _ActionTile(
                        icon: Icons.notifications_outlined,
                        title: 'Allow notifications',
                        subtitle: 'Choose alerts in each feed’s settings.',
                        busy: _busyActions.contains('notifications'),
                        onTap: _busyActions.contains('notifications')
                            ? null
                            : () => _runTracked(
                                context,
                                'notifications',
                                () async {
                                  final granted = await ref
                                      .read(notificationServiceProvider)
                                      .requestPermission();
                                  if (context.mounted) {
                                    showMessageSnackBar(
                                      context,
                                      granted
                                          ? 'Notifications allowed'
                                          : 'Notifications remain disabled',
                                    );
                                  }
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                const SectionHeader('Import and export'),
                AppCard(
                  child: Column(
                    children: [
                      _ActionTile(
                        icon: Icons.upload_file_rounded,
                        title: 'Export podcast OPML',
                        subtitle:
                            'Exports podcast subscriptions. Private feeds that require sign-in headers are skipped.',
                        busy: _busyActions.contains('podcastExport'),
                        onTap: _busyActions.contains('podcastExport')
                            ? null
                            : () => _runTracked(
                                context,
                                'podcastExport',
                                () => _exportOpml(
                                  context,
                                  OpmlExportScope.podcasts,
                                  'Podcast OPML ready',
                                ),
                              ),
                      ),
                      _ActionTile(
                        icon: Icons.rss_feed_rounded,
                        title: 'Export reading feeds as OPML',
                        subtitle:
                            'Exports reading subscriptions. Private feeds that require sign-in headers are skipped.',
                        busy: _busyActions.contains('readerExport'),
                        onTap: _busyActions.contains('readerExport')
                            ? null
                            : () => _runTracked(
                                context,
                                'readerExport',
                                () => _exportOpml(
                                  context,
                                  OpmlExportScope.reading,
                                  'Reading-feed OPML ready',
                                ),
                              ),
                      ),
                      _ActionTile(
                        icon: Icons.dynamic_feed_rounded,
                        title: 'Export all feeds as OPML',
                        subtitle:
                            'Exports podcast and reading subscriptions. Private feeds that require sign-in headers are skipped.',
                        busy: _busyActions.contains('feedExport'),
                        onTap: _busyActions.contains('feedExport')
                            ? null
                            : () => _runTracked(
                                context,
                                'feedExport',
                                () => _exportOpml(
                                  context,
                                  OpmlExportScope.allSubscriptions,
                                  'Subscription OPML ready',
                                ),
                              ),
                      ),
                      _ActionTile(
                        icon: Icons.file_download_outlined,
                        title: 'Import OPML',
                        subtitle:
                            _opmlProgress ??
                            'Imports podcast and reading subscriptions from standard OPML files.',
                        busy: _busyActions.contains('opmlImport'),
                        onTap: _busyActions.contains('opmlImport')
                            ? null
                            : () async {
                                try {
                                  await _runTracked(
                                    context,
                                    'opmlImport',
                                    () async {
                                      final result = await ref
                                          .read(opmlServiceProvider)
                                          .pickAndImport(
                                            onProgress: (completed, total) {
                                              if (!mounted) return;
                                              setState(
                                                () => _opmlProgress = total == 0
                                                    ? 'No subscriptions found'
                                                    : 'Importing $completed of $total',
                                              );
                                            },
                                          );
                                      if (context.mounted && result != null) {
                                        showMessageSnackBar(
                                          context,
                                          '${result.imported} imported · ${result.failed} failed',
                                        );
                                      }
                                    },
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() => _opmlProgress = null);
                                  }
                                }
                              },
                      ),
                      _ActionTile(
                        icon: Icons.archive_outlined,
                        title: 'Export local backup',
                        subtitle:
                            'Exports subscriptions, settings, and progress without credentials or downloads.',
                        busy: _busyActions.contains('backupExport'),
                        onTap: _busyActions.contains('backupExport')
                            ? null
                            : () => _runTracked(
                                context,
                                'backupExport',
                                () async {
                                  await ref
                                      .read(backupServiceProvider)
                                      .exportAndShare(
                                        sharePositionOrigin: _shareOrigin(
                                          context,
                                        ),
                                      );
                                  if (context.mounted) {
                                    showMessageSnackBar(
                                      context,
                                      'Backup ready to share',
                                    );
                                  }
                                },
                              ),
                      ),
                      _ActionTile(
                        icon: Icons.unarchive_outlined,
                        title: 'Restore local backup',
                        subtitle: 'Merges a trickle ZIP into this device.',
                        busy: _busyActions.contains('backupImport'),
                        onTap: _busyActions.contains('backupImport')
                            ? null
                            : () => _runTracked(
                                context,
                                'backupImport',
                                () async {
                                  final result = await ref
                                      .read(backupServiceProvider)
                                      .pickAndImport();
                                  if (result != null) {
                                    final audio = ref.read(
                                      audioHandlerProvider,
                                    );
                                    await audio.reloadQueueFromDatabase();
                                    await audio.reloadSettingsFromDatabase();
                                  }
                                  if (context.mounted && result != null) {
                                    showMessageSnackBar(
                                      context,
                                      '${result.feeds} feeds · ${result.episodes} episodes · ${result.articles} articles restored',
                                    );
                                  }
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                const SectionHeader('Privacy'),
                const AppCard(
                  child: Text(
                    'trickle doesn’t collect your information.',
                    style: TextStyle(
                      color: AppConstants.secondaryText,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                AppCard(
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'trickle',
                    applicationLegalese: 'Third-party open-source licenses',
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.balance_rounded, color: AppConstants.cyan),
                      SizedBox(width: 14),
                      Expanded(child: Text('Open-source licenses')),
                      Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'trickle ${package?.version ?? ''} (${package?.buildNumber ?? ''})',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppConstants.secondaryText,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _autoDeleteLabel(AutoDeletePolicy policy) => switch (policy) {
    AutoDeletePolicy.immediately => 'Immediately',
    AutoDeletePolicy.after1Day => '1 day',
    AutoDeletePolicy.after1Week => '1 week',
  };

  Future<void> _runTracked(
    BuildContext context,
    String action,
    Future<void> Function() operation,
  ) async {
    if (_busyActions.contains(action)) return;
    setState(() => _busyActions.add(action));
    try {
      await operation();
    } on Object catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busyActions.remove(action));
    }
  }

  Future<void> _exportOpml(
    BuildContext context,
    OpmlExportScope scope,
    String success,
  ) async {
    final result = await ref
        .read(opmlServiceProvider)
        .exportAndShare(
          scope: scope,
          sharePositionOrigin: _shareOrigin(context),
        );
    if (!context.mounted) return;
    final details = <String>[
      '${result.exported} ${result.exported == 1 ? 'feed' : 'feeds'} exported',
      if (result.skippedHeaderAuth case final count when count > 0)
        '$count header-authenticated feed${count == 1 ? '' : 's'} skipped',
      if (result.skippedMissingCredentials case final count when count > 0)
        '$count feed${count == 1 ? '' : 's'} with unavailable credentials skipped',
    ];
    showMessageSnackBar(context, '$success · ${details.join(' · ')}');
  }

  static Future<void> _runSilent(
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

Rect _shareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || box.size.isEmpty) {
    return const Rect.fromLTWH(0, 0, 1, 1);
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

final class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.textScalerOf(context).scale(1) > 1.8) {
      return Semantics(
        button: true,
        enabled: onTap != null,
        liveRegion: busy,
        label: busy ? '$title. In progress. $subtitle' : '$title. $subtitle',
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      const Icon(Icons.chevron_right_rounded),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppConstants.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      enabled: onTap != null,
      liveRegion: busy,
      label: busy ? '$title. In progress. $subtitle' : '$title. $subtitle',
      excludeSemantics: true,
      onTap: onTap,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}
