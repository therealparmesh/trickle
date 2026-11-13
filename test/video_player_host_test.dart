import 'dart:async';
import 'dart:convert';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/app/app_providers.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/features/video/video_session.dart';
import 'package:trickle/presentation/widgets/video_player_host.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/playback_harness.dart';

void main() {
  testWidgets('a late play event cannot keep inline video playing offscreen', (
    tester,
  ) async {
    await _withVideo(tester, (_, platform) async {
      final web = platform.controller;
      web.emit('video-state');
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(web.commands, ['pause']);

      web.emit('video-state', playing: true);
      await tester.pump();
      expect(web.commands, ['pause', 'pause']);
      expect(find.byTooltip('Play video'), findsOneWidget);
    });
  });

  testWidgets('the mini-player recovers from late or missing PiP replies', (
    tester,
  ) async {
    await _withVideo(tester, (session, platform) async {
      final web = platform.controller;
      session.enterPictureInPicture();
      web.emit('video-state');
      await tester.pump();
      web.emit('pip-dismissed');
      await tester.pump();
      expect(web.commands, ['resume-after-picture-in-picture']);
      final resumeRevision = web.resumeRevision;
      await tester.tap(find.byTooltip('Pause video'));
      await tester.pump();
      expect(web.commands.last, 'pause');

      web.emit(
        'pip-resume-result',
        playing: true,
        controlRevision: resumeRevision,
      );
      await tester.pump();
      expect(find.byTooltip('Play video'), findsOneWidget);

      session.enterPictureInPicture();
      web.emit('pip-dismissed');
      await tester.pump();
      expect(find.byTooltip('Pause video'), findsOneWidget);
      web.emit('pip-resume-result', controlRevision: web.resumeRevision);
      await tester.pump();
      expect(find.byTooltip('Play video'), findsOneWidget);

      session.enterPictureInPicture();
      web.emit('pip-dismissed');
      await tester.pump();
      expect(find.text('Buffering'), findsOneWidget);
      await tester.pump(AppConstants.videoSourceLoadTimeout);
      expect(find.byTooltip('Play video'), findsOneWidget);
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      expect(web.commands.last, 'play');

      session.enterPictureInPicture();
      web.emit('pip-dismissed');
      await tester.pump();
      web.emit('video-state', playing: true);
      await tester.pump();
      expect(find.text('Buffering'), findsOneWidget);
      await tester.pump(AppConstants.videoSourceLoadTimeout);
      expect(find.text('Playing'), findsOneWidget);
    });
  });

  testWidgets('a stalled command on a closed video cannot block a new video', (
    tester,
  ) async {
    await _withVideo(tester, (_, web) async {
      final first = web.controller;
      first.emit('video-state');
      await tester.pump();
      final stalled = Completer<void>();
      first.playCommand = stalled.future;
      try {
        await tester.tap(find.byTooltip('Play video'));
        await tester.pump();
        expect(first.commands, ['play']);
        await tester.tap(find.byTooltip('Close video'));
        await tester.pump();
        web.openVideo('next.mp4');
        await tester.pump();
        await tester.pump();
        expect(web.controller, isNot(same(first)));
        expect(web.controller.loadedPath, '/next.mp4');
      } finally {
        stalled.complete();
        await tester.pump();
      }
    });
  });

  testWidgets('Play can be retried when the WebView stops answering', (
    tester,
  ) async {
    await _withVideo(tester, (_, platform) async {
      final web = platform.controller;
      web.emit('video-state');
      await tester.pump();
      final stalled = Completer<void>();
      web.playCommand = stalled.future;
      try {
        await tester.tap(find.byTooltip('Play video'));
        await tester.pump();
        expect(find.text('Buffering'), findsOneWidget);
        await tester.pump(AppConstants.shortOperationTimeout);
        expect(find.byTooltip('Play video'), findsOneWidget);

        web.playCommand = null;
        await tester.tap(find.byTooltip('Play video'));
        await tester.pump();
        expect(web.commands, ['play', 'play']);
        await tester.pump(AppConstants.videoSourceLoadTimeout);
        expect(find.byTooltip('Play video'), findsOneWidget);

        await tester.tap(find.byTooltip('Play video'));
        await tester.pump();
        web.failPause = true;
        await tester.tap(find.byTooltip('Pause video'));
        await tester.pump();
        expect(web.commands.last, 'pause');
        expect(find.byTooltip('Play video'), findsOneWidget);
      } finally {
        stalled.complete();
        await tester.pump();
      }
    });
  });
}

Future<void> _withVideo(
  WidgetTester tester,
  Future<void> Function(VideoSessionNotifier, _WebPlatform) run,
) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final web = _WebPlatform();
  WebViewPlatform.instance = web;
  final audioPlatform = AudioServicePlatform.instance;
  AudioServicePlatform.instance = _UnavailableAudioService();
  addTearDown(() => AudioServicePlatform.instance = audioPlatform);
  final harness = createPlaybackHarness();
  final container = ProviderContainer(
    overrides: [
      audioHandlerProvider.overrideWithValue(harness.handler),
      articleProvider('video').overrideWith((_) => const Stream.empty()),
    ],
  );
  try {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: VideoPlayerHost(child: Scaffold())),
      ),
    );
    final session = container.read(videoSessionProvider.notifier);
    web.openVideo = (name) {
      final source = Uri.parse('https://example.test/$name');
      session.open(
        intentRevision: harness.handler.beginWebVideoPlayback(),
        articleId: 'video',
        title: 'Video',
        sourceUri: source,
        playbackUri: source,
      );
      session.minimize();
    };
    web.openVideo('video.mp4');
    await tester.pump();
    await tester.pump();
    await run(session, web);
  } finally {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    final handlerDisposal = harness.handler.disposeHandler();
    await tester.pump(const Duration(milliseconds: 1));
    await handlerDisposal;
    harness.network.close();
    await tester.runAsync(harness.database.close);
  }
}

final class _UnavailableAudioService extends NoOpAudioService {
  @override
  Future<void> configure(ConfigureRequest request) async {
    throw StateError('No native audio in this test');
  }
}

final class _WebPlatform extends WebViewPlatform {
  late _WebController controller;
  late void Function(String) openVideo;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = _WebController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _WebNavigation(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _WebWidget(params);
}

final class _WebController extends PlatformWebViewController {
  _WebController(super.params) : super.implementation();

  late JavaScriptChannelParams _channel;
  late _WebNavigation _navigation;
  late String _url;
  late int _observerToken;
  String? loadedPath;
  Future<void>? playCommand;
  bool failPause = false;
  int _revision = 0;
  int? resumeRevision;
  final commands = <String>[];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    _channel = params;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {
    _navigation = delegate as _WebNavigation;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    if (baseUrl == null) return;
    _url = baseUrl;
    loadedPath = Uri.parse(baseUrl).path;
    _navigation.finished(_url);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    final observer = RegExp(
      r'const observerToken = (\d+);',
    ).firstMatch(javaScript);
    if (observer != null) _observerToken = int.parse(observer[1]!);
    final command = RegExp(
      r'^window\.postMessage\((\{.*\}), "\*"\);$',
    ).firstMatch(javaScript);
    if (command == null) return;
    final data = jsonDecode(command[1]!) as Map<String, dynamic>;
    final action = data['__trickleVideoCommand'] as String;
    commands.add(action);
    if (action == 'play') await playCommand;
    if (action == 'pause' && failPause) {
      throw StateError('WebView failed to pause');
    }
    if (action == 'resume-after-picture-in-picture') {
      resumeRevision = data['controlRevision'] as int;
    }
  }

  void emit(String state, {bool playing = false, int? controlRevision}) {
    _channel.onMessageReceived(
      JavaScriptMessage(
        message: jsonEncode({
          'state': state,
          'url': _url,
          'observerToken': _observerToken,
          'revision': ++_revision,
          'playing': playing,
          'buffering': false,
          'controlRevision': controlRevision,
        }),
      ),
    );
  }
}

final class _WebNavigation extends PlatformNavigationDelegate {
  _WebNavigation(super.params) : super.implementation();

  late PageEventCallback finished;

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {
    finished = callback;
  }

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async {}

  @override
  Future<void> setOnProgress(ProgressCallback callback) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

final class _WebWidget extends PlatformWebViewWidget {
  _WebWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
