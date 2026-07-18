import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../services/opml_service.dart';
import '../widgets/common.dart';

final class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String? _busyAction;

  @override
  Widget build(BuildContext context) {
    final speed = ref.watch(speedProvider).value ?? AppConstants.defaultSpeed;
    final autoDelete =
        ref.watch(autoDeleteProvider).value ?? AutoDeletePolicy.after24Hours;
    final refresh =
        ref.watch(refreshIntervalProvider).value ?? RefreshInterval.every6Hours;
    final images = ref.watch(remoteImagesProvider).value ?? true;
    final package = ref.watch(packageInfoProvider).value;
    return PopScope(
      canPop: _busyAction == null,
      child: Scaffold(
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
                            await _runSilent(context, () async {
                              await ref
                                  .read(settingsRepositoryProvider)
                                  .setRefreshInterval(value);
                              await ref
                                  .read(backgroundRefreshProvider)
                                  .schedule(value);
                            });
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
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.sync_rounded),
                          title: const Text('Refresh now'),
                          onTap: () async {
                            try {
                              final result = await ref
                                  .read(syncCoordinatorProvider)
                                  .refresh();
                              if (!context.mounted) return;
                              _message(
                                context,
                                result.failedFeeds == 0
                                    ? 'Feeds refreshed'
                                    : 'Refresh finished with ${result.failedFeeds} failed feed${result.failedFeeds == 1 ? '' : 's'}',
                              );
                            } on Object catch (error) {
                              if (context.mounted) {
                                _message(context, friendlyError(error));
                              }
                            }
                          },
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.notifications_outlined),
                          title: const Text('Allow notifications'),
                          subtitle: const Text(
                            'Choose alerts in each feed’s settings.',
                          ),
                          onTap: () async {
                            try {
                              final granted = await ref
                                  .read(notificationServiceProvider)
                                  .requestPermission();
                              if (context.mounted) {
                                _message(
                                  context,
                                  granted
                                      ? 'Notifications allowed'
                                      : 'Notifications remain disabled',
                                );
                              }
                            } on Object catch (error) {
                              if (context.mounted) {
                                _message(context, friendlyError(error));
                              }
                            }
                          },
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
                          busy: _busyAction == 'podcastExport',
                          onTap: _busyAction == 'podcastExport'
                              ? null
                              : () => _runImportExport(
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
                          busy: _busyAction == 'readerExport',
                          onTap: _busyAction == 'readerExport'
                              ? null
                              : () => _runImportExport(
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
                          busy: _busyAction == 'feedExport',
                          onTap: _busyAction == 'feedExport'
                              ? null
                              : () => _runImportExport(
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
                              'Imports podcast and reading subscriptions from standard OPML files.',
                          busy: _busyAction == 'opmlImport',
                          onTap: _busyAction == 'opmlImport'
                              ? null
                              : () => _runImportExport(
                                  context,
                                  'opmlImport',
                                  () async {
                                    try {
                                      final result = await ref
                                          .read(opmlServiceProvider)
                                          .pickAndImport();
                                      if (context.mounted && result != null) {
                                        _message(
                                          context,
                                          '${result.imported} imported · ${result.failed} failed',
                                        );
                                      }
                                    } on Object catch (error) {
                                      if (context.mounted) {
                                        _message(context, friendlyError(error));
                                      }
                                    }
                                  },
                                ),
                        ),
                        _ActionTile(
                          icon: Icons.archive_outlined,
                          title: 'Export local backup',
                          subtitle:
                              'Exports subscriptions, settings, and progress without credentials or downloads.',
                          busy: _busyAction == 'backupExport',
                          onTap: _busyAction == 'backupExport'
                              ? null
                              : () => _runImportExport(
                                  context,
                                  'backupExport',
                                  () => _run(
                                    context,
                                    () => ref
                                        .read(backupServiceProvider)
                                        .exportAndShare(
                                          sharePositionOrigin: _shareOrigin(
                                            context,
                                          ),
                                        ),
                                    'Backup ready to share',
                                  ),
                                ),
                        ),
                        _ActionTile(
                          icon: Icons.unarchive_outlined,
                          title: 'Restore local backup',
                          subtitle: 'Merges a trickle ZIP into this device.',
                          busy: _busyAction == 'backupImport',
                          onTap: _busyAction == 'backupImport'
                              ? null
                              : () => _runImportExport(
                                  context,
                                  'backupImport',
                                  () async {
                                    try {
                                      final result = await ref
                                          .read(backupServiceProvider)
                                          .pickAndImport();
                                      if (result != null) {
                                        final audio = ref.read(
                                          audioHandlerProvider,
                                        );
                                        await audio.reloadQueueFromDatabase();
                                        await audio
                                            .reloadSettingsFromDatabase();
                                        final interval = await ref
                                            .read(settingsRepositoryProvider)
                                            .watchRefreshInterval()
                                            .first;
                                        await ref
                                            .read(backgroundRefreshProvider)
                                            .schedule(interval);
                                      }
                                      if (context.mounted && result != null) {
                                        _message(
                                          context,
                                          '${result.feeds} feeds · ${result.episodes} episodes · ${result.articles} articles restored',
                                        );
                                      }
                                    } on Object catch (error) {
                                      if (context.mounted) {
                                        _message(context, friendlyError(error));
                                      }
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
      ),
    );
  }

  static String _autoDeleteLabel(AutoDeletePolicy policy) => switch (policy) {
    AutoDeletePolicy.immediately => 'Immediately after playback finishes',
    AutoDeletePolicy.after24Hours => '24 hours after playback finishes',
    AutoDeletePolicy.after7Days => '7 days after playback finishes',
    AutoDeletePolicy.never => 'Never',
  };

  Future<void> _runImportExport(
    BuildContext context,
    String action,
    Future<void> Function() operation,
  ) async {
    if (_busyAction != null) {
      _message(context, 'Finish the current import or export first.');
      return;
    }
    setState(() => _busyAction = action);
    try {
      await operation();
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _exportOpml(
    BuildContext context,
    OpmlExportScope scope,
    String success,
  ) async {
    try {
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
      _message(context, '$success · ${details.join(' · ')}');
    } on Object catch (error) {
      if (context.mounted) _message(context, friendlyError(error));
    }
  }

  static Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String success,
  ) async {
    try {
      await action();
      if (context.mounted) _message(context, success);
    } on Object catch (error) {
      if (context.mounted) _message(context, friendlyError(error));
    }
  }

  static Future<void> _runSilent(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      if (context.mounted) _message(context, friendlyError(error));
    }
  }

  static void _message(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
        label: '$title. $subtitle',
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
    return ListTile(
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
    );
  }
}
