import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_providers.dart';
import 'app/theme.dart';
import 'app/trickle_app.dart';
import 'data/database/app_database.dart';
import 'data/network/safe_network_client.dart';
import 'data/repositories/article_repository.dart';
import 'data/repositories/episode_extras_repository.dart';
import 'data/repositories/feed_repository.dart';
import 'data/repositories/playback_source_resolver.dart';
import 'data/repositories/podcast_search_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/security/private_feed_store.dart';
import 'features/downloads/download_coordinator.dart';
import 'features/player/trickle_audio_handler.dart';
import 'presentation/widgets/common.dart';
import 'services/background_refresh_service.dart';
import 'services/backup_service.dart';
import 'services/notification_service.dart';
import 'services/opml_service.dart';
import 'services/sync_coordinator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _registerBundledFontLicenses();
  runApp(const _TrickleBootstrap());
}

void _registerBundledFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Space Grotesk',
    ], await rootBundle.loadString('assets/fonts/OFL-SpaceGrotesk.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Chakra Petch',
    ], await rootBundle.loadString('assets/fonts/OFL-ChakraPetch.txt'));
  });
}

final class _TrickleBootstrap extends StatefulWidget {
  const _TrickleBootstrap();

  @override
  State<_TrickleBootstrap> createState() => _TrickleBootstrapState();
}

final class _TrickleBootstrapState extends State<_TrickleBootstrap> {
  late Future<_TrickleRuntime> _runtime;

  @override
  void initState() {
    super.initState();
    final firstFrame = Completer<_TrickleRuntime>();
    _runtime = firstFrame.future;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<_TrickleRuntime>(
        _createRuntime,
      ).then(firstFrame.complete, onError: firstFrame.completeError);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_TrickleRuntime>(
      future: _runtime,
      builder: (context, snapshot) {
        final runtime = snapshot.data;
        if (runtime != null) return runtime.buildApp();
        return MaterialApp(
          title: 'trickle',
          debugShowCheckedModeBanner: false,
          theme: TrickleTheme.dark,
          home: Scaffold(
            body: AppBackdrop(
              child: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const TrickleMark(size: 92),
                        const SizedBox(height: 18),
                        Text(
                          'trickle',
                          style: Theme.of(context).textTheme.displaySmall
                              ?.copyWith(fontSize: 52, letterSpacing: 0.45),
                        ),
                        const SizedBox(height: 28),
                        if (snapshot.hasError) ...[
                          const Text(
                            'Initialization failed. Your local data was not changed.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: () {
                              setState(
                                () => _runtime = Future<_TrickleRuntime>(
                                  _createRuntime,
                                ),
                              );
                            },
                            child: const Text('Try again'),
                          ),
                        ] else
                          const SizedBox(height: 42, child: LoadingView()),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

final class _TrickleRuntime {
  _TrickleRuntime({
    required this.database,
    required this.network,
    required this.audio,
    required this.downloads,
    required this.completionSubscription,
    required this.feedRepository,
    required this.privateFeeds,
    required this.search,
    required this.articles,
    required this.extras,
    required this.settings,
    required this.backup,
    required this.background,
    required this.notifications,
    required this.opml,
    required this.sync,
  });

  final AppDatabase database;
  final SafeNetworkClient network;
  final TrickleAudioHandler audio;
  final DownloadCoordinator downloads;
  final StreamSubscription<Object?> completionSubscription;
  final FeedRepository feedRepository;
  final PrivateFeedStore privateFeeds;
  final PodcastSearchRepository search;
  final ArticleRepository articles;
  final EpisodeExtrasRepository extras;
  final SettingsRepository settings;
  final BackupService backup;
  final BackgroundRefreshService background;
  final NotificationService notifications;
  final OpmlService opml;
  final SyncCoordinator sync;
  bool _disposed = false;

  Widget buildApp() {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        networkProvider.overrideWithValue(network),
        feedRepositoryProvider.overrideWithValue(feedRepository),
        privateFeedStoreProvider.overrideWithValue(privateFeeds),
        podcastSearchProvider.overrideWithValue(search),
        articleRepositoryProvider.overrideWithValue(articles),
        episodeExtrasProvider.overrideWithValue(extras),
        settingsRepositoryProvider.overrideWithValue(settings),
        audioHandlerProvider.overrideWithValue(audio),
        downloadCoordinatorProvider.overrideWithValue(downloads),
        backupServiceProvider.overrideWithValue(backup),
        backgroundRefreshProvider.overrideWithValue(background),
        notificationServiceProvider.overrideWithValue(notifications),
        opmlServiceProvider.overrideWithValue(opml),
        syncCoordinatorProvider.overrideWithValue(sync),
      ],
      child: TrickleApp(sync: sync, onDispose: dispose),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await completionSubscription.cancel();
    await downloads.dispose();
    await audio.disposeHandler();
    network.close();
    await database.close();
  }
}

Future<_TrickleRuntime> _createRuntime() async {
  final database = AppDatabase();
  SafeNetworkClient? network;
  TrickleAudioHandler? audio;
  DownloadCoordinator? downloads;
  StreamSubscription<Object?>? completionSubscription;
  try {
    network = await SafeNetworkClient.create();
    final privateFeeds = PrivateFeedStore();
    await _prepareSecureStoreForInstall(privateFeeds);
    final settings = SettingsRepository(database);
    final feedRepository = FeedRepository(
      database: database,
      network: network,
      privateFeeds: privateFeeds,
    );
    final sources = PlaybackSourceResolver(database, privateFeeds, network);
    audio = TrickleAudioHandler(
      database: database,
      settings: settings,
      sourceResolver: sources,
    );
    downloads = DownloadCoordinator(
      database: database,
      sources: sources,
      settings: settings,
    );
    completionSubscription = audio.customEvent.listen((event) {
      if (event is Map && event['type'] == 'completed') {
        if (event['episodeId'] != null) {
          unawaited(downloads!.cleanupPlayed().catchError((Object _) {}));
        }
      }
    });
    final notifications = NotificationService();
    final background = BackgroundRefreshService();
    final search = PodcastSearchRepository(database, network);
    final articles = ArticleRepository(database, network, privateFeeds);
    final extras = EpisodeExtrasRepository(database, network, privateFeeds);
    final backup = BackupService(database);
    final opml = OpmlService(database, feedRepository, privateFeeds);
    final sync = SyncCoordinator(
      database: database,
      feeds: feedRepository,
      downloads: downloads,
      audio: audio,
      notifications: notifications,
    );

    unawaited(downloads.initialize().catchError((Object _) {}));
    unawaited(notifications.initialize().catchError((Object _) {}));
    unawaited(_initializeBackground(background, settings));
    await audio.reloadQueueFromDatabase();
    return _TrickleRuntime(
      database: database,
      network: network,
      audio: audio,
      downloads: downloads,
      completionSubscription: completionSubscription,
      feedRepository: feedRepository,
      privateFeeds: privateFeeds,
      search: search,
      articles: articles,
      extras: extras,
      settings: settings,
      backup: backup,
      background: background,
      notifications: notifications,
      opml: opml,
      sync: sync,
    );
  } on Object {
    await completionSubscription?.cancel();
    await downloads?.dispose();
    await audio?.disposeHandler();
    network?.close();
    await database.close();
    rethrow;
  }
}

Future<void> _prepareSecureStoreForInstall(PrivateFeedStore store) async {
  final directory = await getApplicationSupportDirectory();
  final sentinel = File('${directory.path}/.trickle-install');
  if (await sentinel.exists()) return;
  // iOS Keychain entries can survive uninstall. A sandbox file cannot, so its
  // absence identifies a fresh install and prevents old private-feed secrets
  // from silently carrying into it.
  await store.clearStaleInstallData();
  await sentinel.create(recursive: true);
  await sentinel.writeAsString('1', flush: true);
}

Future<void> _initializeBackground(
  BackgroundRefreshService background,
  SettingsRepository settings,
) async {
  try {
    await background.initialize();
    await background.schedule(await settings.watchRefreshInterval().first);
  } on Object {
    // Foreground refresh remains available if OS scheduling is unavailable.
  }
}
