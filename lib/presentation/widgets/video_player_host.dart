import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../app/app_providers.dart';
import '../../core/constants.dart';
import '../../core/youtube_support.dart';
import '../../features/video/video_session.dart';
import 'common.dart';
import 'design_system.dart';

final class VideoPlayerHost extends ConsumerStatefulWidget {
  const VideoPlayerHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<VideoPlayerHost> createState() => _VideoPlayerHostState();
}

class _VideoPlayerHostState extends ConsumerState<VideoPlayerHost>
    with WidgetsBindingObserver {
  static const _platformChannel = MethodChannel('com.parmscript.trickle/video');

  WebViewController? _controller;
  Future<WebViewController>? _controllerInitialization;
  Future<void> _navigationTail = Future<void>.value();
  String? _loadedArticleId;
  Uri? _loadedUri;
  Uri? _activeRequestUri;
  Timer? _loadTimeout;
  int _sessionGeneration = 0;
  int _controllerToken = 0;
  int _videoObserverToken = 0;
  int _activeVideoObserverToken = 0;
  int _lastVideoStateRevision = 0;
  int _progress = 0;
  bool _pageLoaded = false;
  bool _ready = false;
  bool _videoPlaying = false;
  bool _videoBuffering = false;
  bool _pausedForBackground = false;
  bool _requestingPictureInPicture = false;
  AppLifecycleState _lifecycleState =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  VideoPlaybackSource _source = VideoPlaybackSource.privacyWrapper;
  String? _error;

  bool get _usingOfficialFallback =>
      _source == VideoPlaybackSource.officialYouTube;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _platformChannel.setMethodCallHandler(_handlePlatformCall);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _platformChannel.setMethodCallHandler(null);
    }
    _loadTimeout?.cancel();
    unawaited(
      ref
          .read(audioHandlerProvider)
          .deactivateWebVideoAudioSession()
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _pausedForBackground = false;
      return;
    }
    if (state == AppLifecycleState.detached) {
      // The platform view is already being torn down. Calling into WebKit or
      // Android WebView here can race engine detachment; process teardown will
      // stop the media without another JavaScript command.
      _pausedForBackground = true;
      return;
    }
    final session = ref.read(videoSessionProvider);
    if (session != null &&
        shouldPauseVideoForLifecycle(state, session.presentation) &&
        !_pausedForBackground) {
      _pausedForBackground = true;
      unawaited(_pauseForBackground());
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(videoSessionProvider);
    ref.listen(playbackStateProvider, (previous, next) {
      if (next.value?.playing == true &&
          previous?.value?.playing != true &&
          ref.read(videoSessionProvider) != null) {
        unawaited(_close());
      }
    });
    if (session != null &&
        (session.articleId != _loadedArticleId ||
            session.playbackUri != _loadedUri)) {
      // Reserve this session before scheduling the load. A controller startup
      // failure must leave a stable retry state instead of scheduling itself
      // again on every rebuild.
      _loadedArticleId = session.articleId;
      _loadedUri = session.playbackUri;
      final generation = ++_sessionGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(session, generation: generation));
      });
    }

    final pictureInPicture =
        session?.presentation == VideoPresentation.pictureInPicture;
    final webKitPictureInPicture =
        pictureInPicture && defaultTargetPlatform == TargetPlatform.iOS;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (session != null && webKitPictureInPicture)
          _player(context, session, systemPresentation: true),
        ExcludeSemantics(
          excluding: session?.presentation == VideoPresentation.expanded,
          child: widget.child,
        ),
        if (session != null && !webKitPictureInPicture)
          _player(context, session, systemPresentation: pictureInPicture),
        if (session != null && webKitPictureInPicture)
          _pictureInPictureBar(context, session),
      ],
    );
  }

  Widget _pictureInPictureBar(BuildContext context, VideoSession session) {
    final phase = _videoPhase;
    final height = videoMiniPlayerHeight(context);
    final bottom = MediaQuery.viewInsetsOf(context).bottom > 0
        ? -height
        : MediaQuery.viewPaddingOf(context).bottom + 8;
    final previewWidth = (MediaQuery.sizeOf(context).width * 0.34).clamp(
      116.0,
      160.0,
    );
    return Positioned(
      key: const ValueKey('picture-in-picture-video-bar'),
      left: 12,
      right: 12,
      bottom: bottom,
      height: height,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Semantics(
            container: true,
            liveRegion: true,
            label: '${session.title}. ${phase.label} in Picture in Picture.',
            child: Material(
              color: AppConstants.elevated.withValues(alpha: 0.97),
              clipBehavior: Clip.antiAlias,
              shape: const CutCornerBorder(
                cut: 14,
                side: BorderSide(color: AppConstants.hairline),
              ),
              child: Row(
                children: [
                  _VideoThumbnail(
                    articleId: session.articleId,
                    width: previewWidth,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${phase.label} · Picture in Picture',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppConstants.secondaryText),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close video',
                    onPressed: _close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _player(
    BuildContext context,
    VideoSession session, {
    required bool systemPresentation,
  }) {
    final expanded =
        session.presentation == VideoPresentation.expanded ||
        systemPresentation;
    final miniHeight = videoMiniPlayerHeight(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final bottom = keyboardOpen
        ? -miniHeight
        : MediaQuery.viewPaddingOf(context).bottom + 8;

    return Positioned(
      key: const ValueKey('persistent-video-player-layer'),
      left: expanded ? 0 : 12,
      top: expanded ? 0 : null,
      right: expanded ? 0 : 12,
      bottom: expanded ? 0 : bottom,
      height: expanded ? null : miniHeight,
      child: IgnorePointer(
        ignoring: systemPresentation,
        child: ExcludeSemantics(
          excluding: systemPresentation,
          child: Semantics(
            scopesRoute: expanded,
            namesRoute: expanded,
            explicitChildNodes: true,
            label: expanded ? 'Video player' : null,
            child: Material(
              color: AppConstants.elevated,
              clipBehavior: Clip.antiAlias,
              shape: expanded
                  ? const RoundedRectangleBorder()
                  : const CutCornerBorder(
                      cut: 14,
                      side: BorderSide(color: AppConstants.hairline),
                    ),
              child: SafeArea(
                top: expanded && !systemPresentation,
                bottom: expanded && !systemPresentation,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final toolbarHeight = expanded && !systemPresentation
                        ? _expandedToolbarHeight(context)
                        : 0.0;
                    final previewSize = expanded
                        ? Size(constraints.maxWidth, constraints.maxHeight)
                        : _miniPreviewSize(constraints, miniHeight);
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(
                          left: 0,
                          top: expanded
                              ? toolbarHeight
                              : (constraints.maxHeight - previewSize.height) /
                                    2,
                          width: expanded
                              ? constraints.maxWidth
                              : previewSize.width,
                          height: expanded
                              ? constraints.maxHeight - toolbarHeight
                              : previewSize.height,
                          child: IgnorePointer(
                            ignoring: !expanded,
                            child: ColoredBox(
                              color: Colors.black,
                              child: _webContent(
                                session,
                                compact: !expanded && !systemPresentation,
                              ),
                            ),
                          ),
                        ),
                        if (systemPresentation)
                          const SizedBox.shrink()
                        else if (expanded)
                          _expandedToolbar(context, session, toolbarHeight)
                        else
                          _miniControls(context, session, previewSize.width),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _webContent(VideoSession session, {required bool compact}) {
    final controller = _controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (controller != null)
          WebViewWidget(
            key: const ValueKey('persistent-video-webview'),
            controller: controller,
          ),
        if (!_pageLoaded || _error != null)
          ColoredBox(
            color: AppConstants.background,
            child: _error == null
                ? compact
                      ? const Center(
                          child: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : const LoadingView(label: 'Loading video')
                : compact
                ? const Center(
                    child: Icon(
                      Icons.videocam_off_outlined,
                      color: AppConstants.secondaryText,
                    ),
                  )
                : _VideoError(
                    message: _error!,
                    onRetry: () => unawaited(
                      _load(session, generation: _sessionGeneration),
                    ),
                    onOpenOriginal: () => _openExternal(session.sourceUri),
                  ),
          ),
      ],
    );
  }

  Widget _expandedToolbar(
    BuildContext context,
    VideoSession session,
    double height,
  ) {
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Minimize to Now Playing',
                  onPressed: () =>
                      ref.read(videoSessionProvider.notifier).minimize(),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      session.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _requestingPictureInPicture
                      ? 'Opening Picture in Picture'
                      : _videoPlaying
                      ? 'Picture in Picture'
                      : 'Play video before Picture in Picture',
                  onPressed: _videoPlaying && !_requestingPictureInPicture
                      ? () => unawaited(_enterPictureInPicture())
                      : null,
                  icon: const Icon(Icons.picture_in_picture_alt_rounded),
                ),
                IconButton(
                  tooltip: 'Open original',
                  onPressed: () => _openExternal(session.sourceUri),
                  icon: const Icon(Icons.open_in_browser_rounded),
                ),
                IconButton(
                  tooltip: 'Close video',
                  onPressed: _close,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (!_ready && _error == null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: _progress <= 0 ? null : _progress / 100,
                  minHeight: 2,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _miniControls(
    BuildContext context,
    VideoSession session,
    double previewWidth,
  ) {
    final phase = _videoPhase;
    return Row(
      children: [
        SizedBox(
          width: previewWidth,
          height: double.infinity,
          child: Semantics(
            button: true,
            label: 'Expand video',
            excludeSemantics: true,
            onTap: () => ref.read(videoSessionProvider.notifier).expand(),
            child: InkWell(
              onTap: () => ref.read(videoSessionProvider.notifier).expand(),
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            button: true,
            liveRegion: true,
            label: 'Open video player. ${session.title}. ${phase.label}.',
            excludeSemantics: true,
            onTap: () => ref.read(videoSessionProvider.notifier).expand(),
            child: InkWell(
              onTap: () => ref.read(videoSessionProvider.notifier).expand(),
              child: Padding(
                padding: const EdgeInsets.only(left: 12, right: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(height: 1.2),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      phase.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: phase.isError
                            ? AppConstants.danger
                            : AppConstants.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: phase.actionLabel,
          onPressed: phase.canToggle
              ? () => unawaited(_toggleVideoPlayback(session))
              : null,
          icon: phase.isBusy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(phase.icon),
        ),
        IconButton(
          tooltip: 'Close video',
          onPressed: _close,
          icon: const Icon(Icons.close_rounded),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Size _miniPreviewSize(BoxConstraints constraints, double miniHeight) {
    final width = (constraints.maxWidth * 0.42).clamp(124.0, 180.0);
    final height = (width * 9 / 16).clamp(0.0, miniHeight);
    return Size(width, height);
  }

  double _expandedToolbarHeight(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium;
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 16) *
        (style?.height ?? 1.25);
    return (lineHeight * 2 + 18).clamp(64.0, 160.0);
  }

  Future<WebViewController> _createController() async {
    final controllerToken = ++_controllerToken;
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        // The WebView stays attached when the player collapses into the
        // persistent Now Playing bar. WebKit can move the same media into
        // system Picture in Picture after the user requests it.
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }
    final controller = WebViewController.fromPlatformCreationParams(params);
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.addJavaScriptChannel(
      'TrickleVideoState',
      onMessageReceived: (message) =>
          _handleWebVideoState(message, controllerToken),
    );
    await controller.setBackgroundColor(AppConstants.background);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onProgress: (progress) {
          if (_isCurrentController(controller, controllerToken) &&
              ref.read(videoSessionProvider) != null) {
            setState(() => _progress = progress);
          }
        },
        onPageFinished: (url) => unawaited(
          _finishPageLoad(controller, Uri.tryParse(url), controllerToken),
        ),
        onWebResourceError: (error) {
          if (!_isCurrentController(controller, controllerToken) ||
              ref.read(videoSessionProvider) == null) {
            return;
          }
          final failedUri = Uri.tryParse(error.url ?? '');
          if (error.isForMainFrame == false || failedUri == null) {
            return;
          }
          if (!_isActiveLoadUri(failedUri)) return;
          _fallbackOrShowError();
        },
        onHttpError: (error) {
          if (!_isCurrentController(controller, controllerToken) ||
              ref.read(videoSessionProvider) == null) {
            return;
          }
          final failedUri = error.request?.uri ?? error.response?.uri;
          if (_isActiveLoadUri(failedUri)) _fallbackOrShowError();
        },
        onNavigationRequest: (request) {
          if (!_isCurrentController(controller, controllerToken)) {
            return NavigationDecision.prevent;
          }
          final uri = Uri.tryParse(request.url);
          if (!request.isMainFrame) return NavigationDecision.navigate;
          final allowedHost = _usingOfficialFallback
              ? _isOfficialYouTubeHost(uri?.host)
              : _isWrapperHost(uri?.host) || _isPlaybackHost(uri?.host);
          final requestedVideo = youtubeVideoId(uri);
          if (uri?.scheme == 'about' ||
              (allowedHost &&
                  (requestedVideo == null || _isCurrentVideo(uri)))) {
            return NavigationDecision.navigate;
          }
          if (uri != null) unawaited(_openExternal(uri));
          return NavigationDecision.prevent;
        },
      ),
    );
    if (controller.platform case final AndroidWebViewController android) {
      await android.setMediaPlaybackRequiresUserGesture(false);
    }
    return controller;
  }

  Future<void> _finishPageLoad(
    WebViewController controller,
    Uri? uri,
    int controllerToken,
  ) async {
    if (!_isCurrentController(controller, controllerToken) ||
        ref.read(videoSessionProvider) == null ||
        !_isActivePlaybackUri(uri)) {
      return;
    }
    try {
      await controller.runJavaScript(
        _videoPresentationObserver(_activeVideoObserverToken),
      );
    } on Object {
      // Foreground playback remains usable if state observation is blocked.
    }
    if (!_isCurrentController(controller, controllerToken) ||
        ref.read(videoSessionProvider) == null ||
        !_isActivePlaybackUri(uri)) {
      return;
    }
    final session = ref.read(videoSessionProvider)!;
    if (shouldPauseVideoForLifecycle(_lifecycleState, session.presentation)) {
      await _pauseForBackground();
    }
    if (!_isCurrentController(controller, controllerToken) ||
        ref.read(videoSessionProvider) == null ||
        !_isActivePlaybackUri(uri)) {
      return;
    }
    setState(() {
      _progress = 100;
      _pageLoaded = true;
      _error = null;
    });
  }

  Future<void> _load(
    VideoSession session, {
    required int generation,
    VideoPlaybackSource source = VideoPlaybackSource.privacyWrapper,
  }) async {
    if (!_isCurrentSession(session, generation)) return;
    final requestUri = session.playbackUriFor(source);
    if (requestUri == null) {
      _showLoadError('Couldn’t load this video.', generation: generation);
      return;
    }
    _activeRequestUri = requestUri;
    _source = source;
    _activeVideoObserverToken = ++_videoObserverToken;
    _lastVideoStateRevision = 0;
    _loadTimeout?.cancel();
    if (mounted) {
      setState(() {
        _progress = 0;
        _pageLoaded = false;
        _ready = false;
        _videoPlaying = false;
        _videoBuffering = false;
        _error = null;
      });
    }
    late final WebViewController controller;
    final initialization = _controllerInitialization ??= _createController();
    try {
      controller = await initialization;
    } on Object {
      if (identical(_controllerInitialization, initialization)) {
        _controllerInitialization = null;
      }
      if (_isCurrentSession(session, generation)) {
        _showLoadError(
          'Couldn’t start the video player.',
          generation: generation,
        );
      }
      return;
    }
    if (!_isCurrentSession(session, generation) ||
        _activeRequestUri != requestUri) {
      return;
    }
    _controller = controller;
    setState(() {});
    _loadTimeout = Timer(AppConstants.videoSourceLoadTimeout, () {
      if (_isCurrentSession(session, generation) && !_ready) {
        _fallbackOrShowError(generation: generation, timedOut: true);
      }
    });
    try {
      await _serializeNavigation(() async {
        if (_isCurrentSession(session, generation) &&
            _activeRequestUri == requestUri) {
          await controller.loadRequest(requestUri);
        }
      });
    } on Object {
      if (_isCurrentSession(session, generation) &&
          _activeRequestUri == requestUri) {
        _fallbackOrShowError(generation: generation);
      }
    }
  }

  void _fallbackOrShowError({int? generation, bool timedOut = false}) {
    final activeGeneration = generation ?? _sessionGeneration;
    if (!mounted || activeGeneration != _sessionGeneration) return;
    _loadTimeout?.cancel();
    final session = ref.read(videoSessionProvider);
    final fallback = _source.fallbackAfterFailure;
    if (fallback != null && session != null) {
      unawaited(_load(session, generation: activeGeneration, source: fallback));
      return;
    }
    _showLoadError(
      timedOut
          ? 'YouTube took too long to load this video.'
          : 'Couldn’t load this video from YouTube.',
      generation: activeGeneration,
    );
  }

  bool _isActivePlaybackUri(Uri? uri) =>
      _isCurrentVideo(uri) &&
      (_usingOfficialFallback
          ? _isOfficialYouTubeHost(uri?.host)
          : _isPlaybackHost(uri?.host));

  bool _isActiveLoadUri(Uri? uri) =>
      _isCurrentVideo(uri) &&
      (_usingOfficialFallback
          ? _isOfficialYouTubeHost(uri?.host)
          : _isWrapperHost(uri?.host) || _isPlaybackHost(uri?.host));

  bool _isCurrentVideo(Uri? uri) {
    final activeVideoId = youtubeVideoId(_activeRequestUri);
    final sessionVideoId = youtubeVideoId(
      ref.read(videoSessionProvider)?.sourceUri,
    );
    return activeVideoId != null &&
        activeVideoId == sessionVideoId &&
        youtubeVideoId(uri) == activeVideoId;
  }

  void _showLoadError(String message, {int? generation}) {
    if (!mounted || (generation != null && generation != _sessionGeneration)) {
      return;
    }
    _loadTimeout?.cancel();
    setState(() {
      _pageLoaded = false;
      _ready = false;
      _videoPlaying = false;
      _videoBuffering = false;
      _error = message;
    });
  }

  Future<void> _close() async {
    if (!mounted) return;
    final audioHandler = ref.read(audioHandlerProvider);
    _sessionGeneration++;
    _controllerToken++;
    ref.read(videoSessionProvider.notifier).close();
    _loadTimeout?.cancel();
    _loadedArticleId = null;
    _loadedUri = null;
    _activeRequestUri = null;
    _pageLoaded = false;
    _ready = false;
    _videoPlaying = false;
    _videoBuffering = false;
    _pausedForBackground = false;
    _requestingPictureInPicture = false;
    _activeVideoObserverToken = ++_videoObserverToken;
    _lastVideoStateRevision = 0;
    _source = VideoPlaybackSource.privacyWrapper;
    _error = null;
    final controller = _controller;
    _controller = null;
    _controllerInitialization = null;
    final stopPlayback = controller == null
        ? Future<void>.value()
        : _serializeNavigation(() async {
            try {
              await controller.runJavaScript(
                "document.querySelectorAll('video').forEach((video) => video.pause());",
              );
            } on Object {
              // Loading a blank document still stops media if scripting fails.
            }
            try {
              await controller.loadHtmlString(
                '<!doctype html><html><body style="margin:0;background:#06080d"></body></html>',
              );
            } on Object {
              // Removing the platform view also stops playback.
            }
          });
    await Future.wait([
      audioHandler.deactivateWebVideoAudioSession().catchError((Object _) {}),
      stopPlayback,
    ]);
  }

  Future<void> _openExternal(Uri uri) async {
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      opened = false;
    }
    if (!opened && mounted) {
      showMessageSnackBar(context, 'Couldn’t open this video in your browser.');
    }
  }

  Future<Object?> _handlePlatformCall(MethodCall call) async {
    if (!mounted) return null;
    if (call.method == 'pictureInPictureClosed') {
      if (call.arguments == _sessionGeneration) await _close();
      return null;
    }
    if (call.method != 'pictureInPictureChanged') return null;
    final arguments = call.arguments;
    if (arguments is! Map || arguments['request'] != _sessionGeneration) {
      return null;
    }
    final active = arguments['active'] == true;
    if (active) {
      await _markPictureInPictureActive();
    } else {
      ref.read(videoSessionProvider.notifier).leavePictureInPicture();
    }
    return null;
  }

  void _handleWebVideoState(JavaScriptMessage message, int controllerToken) {
    if (!mounted ||
        controllerToken != _controllerToken ||
        ref.read(videoSessionProvider) == null) {
      return;
    }
    final event = _decodeVideoEvent(message.message);
    if (event == null ||
        !shouldAcceptVideoStateRevision(
          activeObserverToken: _activeVideoObserverToken,
          lastRevision: _lastVideoStateRevision,
          observerToken: event.observerToken,
          revision: event.revision,
        ) ||
        !_isActivePlaybackUri(event.sourceUri)) {
      return;
    }
    _lastVideoStateRevision = event.revision;
    switch (event.state) {
      case 'pip-start':
        unawaited(_markPictureInPictureActive());
      case 'pip-stop':
        if (ref.read(videoSessionProvider)?.presentation !=
            VideoPresentation.pictureInPicture) {
          return;
        }
        if (_lifecycleState == AppLifecycleState.hidden ||
            _lifecycleState == AppLifecycleState.paused ||
            _lifecycleState == AppLifecycleState.detached) {
          unawaited(_close());
        } else {
          ref.read(videoSessionProvider.notifier).leavePictureInPicture();
        }
      case 'pip-closed':
        unawaited(_close());
      case 'video-state':
        final session = ref.read(videoSessionProvider)!;
        if (event.playing &&
            shouldPauseVideoForLifecycle(
              _lifecycleState,
              session.presentation,
            )) {
          if (!_pausedForBackground) unawaited(_pauseForBackground());
        } else {
          _updateVideoPlayback(
            playing: event.playing,
            buffering: event.buffering,
          );
        }
      case 'video-error':
        _fallbackOrShowError();
    }
  }

  _VideoEvent? _decodeVideoEvent(String message) {
    try {
      final value = jsonDecode(message);
      if (value is! Map) return null;
      final state = value['state'];
      final url = value['url'];
      final observerToken = value['observerToken'];
      final revision = value['revision'];
      if (state is! String ||
          url is! String ||
          observerToken is! int ||
          revision is! int) {
        return null;
      }
      final sourceUri = Uri.tryParse(url);
      if (sourceUri == null) return null;
      final playing = value['playing'];
      final buffering = value['buffering'];
      if (state == 'video-state' && (playing is! bool || buffering is! bool)) {
        return null;
      }
      return _VideoEvent(
        state: state,
        sourceUri: sourceUri,
        observerToken: observerToken,
        revision: revision,
        playing: playing == true,
        buffering: buffering == true,
      );
    } on FormatException {
      return null;
    }
  }

  void _updateVideoPlayback({required bool playing, required bool buffering}) {
    if (!mounted ||
        (_ready &&
            _pageLoaded &&
            _error == null &&
            _videoPlaying == playing &&
            _videoBuffering == buffering)) {
      return;
    }
    _loadTimeout?.cancel();
    setState(() {
      _pageLoaded = true;
      _ready = true;
      _error = null;
      _videoPlaying = playing;
      _videoBuffering = buffering;
    });
  }

  Future<void> _pauseForBackground() async {
    final generation = _sessionGeneration;
    final audioHandler = ref.read(audioHandlerProvider);
    _pausedForBackground = true;
    if (mounted &&
        generation == _sessionGeneration &&
        _ready &&
        _videoPlaying) {
      _updateVideoPlayback(playing: false, buffering: false);
    }
    try {
      await _sendVideoCommand('pause');
    } on Object {
      // The platform also suspends a detached WebView.
    }
    try {
      await audioHandler.deactivateWebVideoAudioSession();
    } on Object {
      // Paused media cannot produce background audio without focus.
    }
  }

  Future<void> _enterPictureInPicture() async {
    if (_requestingPictureInPicture ||
        !_videoPlaying ||
        ref.read(videoSessionProvider) == null) {
      return;
    }
    final generation = _sessionGeneration;
    setState(() => _requestingPictureInPicture = true);
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final entered =
            await _platformChannel.invokeMethod<bool>(
              'enterPictureInPicture',
              _sessionGeneration,
            ) ??
            false;
        if (!entered && mounted) {
          showMessageSnackBar(
            context,
            'Picture in Picture isn’t available on this device.',
          );
        } else if (entered && mounted && generation == _sessionGeneration) {
          await _markPictureInPictureActive();
        }
        return;
      }
      await _sendVideoCommand('picture-in-picture');
    } on MissingPluginException {
      if (mounted) {
        showMessageSnackBar(
          context,
          'Picture in Picture isn’t available on this device.',
        );
      }
    } on PlatformException {
      if (mounted) {
        showMessageSnackBar(
          context,
          'Picture in Picture isn’t available on this device.',
        );
      }
    } finally {
      if (mounted && generation == _sessionGeneration) {
        setState(() => _requestingPictureInPicture = false);
      }
    }
  }

  Future<void> _markPictureInPictureActive() async {
    if (!mounted) return;
    final session = ref.read(videoSessionProvider);
    if (session == null ||
        session.presentation == VideoPresentation.pictureInPicture) {
      return;
    }
    ref.read(videoSessionProvider.notifier).enterPictureInPicture();
    try {
      await ref.read(audioHandlerProvider).activateWebVideoAudioSession();
    } on Object {
      // System Picture in Picture remains usable without explicit audio focus.
    }
  }

  Future<void> _toggleVideoPlayback(VideoSession session) async {
    if (_error != null) {
      await _load(session, generation: _sessionGeneration);
      return;
    }
    if (!_ready) return;
    final generation = _sessionGeneration;
    final pause = _videoPlaying;
    try {
      await _sendVideoCommand(pause ? 'pause' : 'play');
      if (pause &&
          mounted &&
          generation == _sessionGeneration &&
          ref.read(videoSessionProvider)?.articleId == session.articleId) {
        _updateVideoPlayback(playing: false, buffering: false);
      }
    } on Object catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    }
  }

  Future<void> _sendVideoCommand(String command) async {
    final controller = _controller;
    if (controller == null || ref.read(videoSessionProvider) == null) return;
    await controller.runJavaScript(
      'window.postMessage({__trickleVideoCommand: ${_javascriptString(command)}}, "*");',
    );
  }

  bool _isCurrentSession(VideoSession session, int generation) =>
      mounted &&
      generation == _sessionGeneration &&
      ref.read(videoSessionProvider)?.articleId == session.articleId &&
      ref.read(videoSessionProvider)?.playbackUri == session.playbackUri;

  bool _isCurrentController(WebViewController controller, int token) =>
      mounted &&
      token == _controllerToken &&
      identical(controller, _controller);

  Future<void> _serializeNavigation(Future<void> Function() operation) {
    final result = _navigationTail.then((_) => operation());
    _navigationTail = result.catchError((Object _) {});
    return result;
  }

  _VideoPhase get _videoPhase {
    if (_error != null) return _VideoPhase.error;
    if (!_ready) return _VideoPhase.loading;
    if (_videoBuffering) return _VideoPhase.buffering;
    return _videoPlaying ? _VideoPhase.playing : _VideoPhase.paused;
  }
}

String _videoPresentationObserver(int observerToken) =>
    '''
(() => {
  const observerToken = $observerToken;
  if (window.__trickleVideoObserverToken === observerToken) {
    if (typeof window.__trickleVideoReportState === 'function') {
      window.__trickleVideoReportState();
    }
    return;
  }
  if (typeof window.__trickleVideoObserverCleanup === 'function') {
    window.__trickleVideoObserverCleanup();
  }
  window.__trickleVideoObserverToken = observerToken;

  let revision = 0;
  const cleanups = [];
  const send = (state, details = {}) => {
    if (window.__trickleVideoObserverToken !== observerToken) return;
    try {
      window.TrickleVideoState.postMessage(JSON.stringify(Object.assign({
        state: state,
        url: window.location.href,
        observerToken: observerToken,
        revision: ++revision,
      }, details)));
    } catch (_) {}
  };
  const mode = (video) => {
    if (video.webkitPresentationMode) return video.webkitPresentationMode;
    return document.pictureInPictureElement === video
        ? 'picture-in-picture'
        : 'inline';
  };
  const area = (video) => {
    const rect = video.getBoundingClientRect();
    return Math.max(0, rect.width) * Math.max(0, rect.height);
  };
  const selectVideo = () => {
    const videos = Array.from(document.querySelectorAll('video'))
        .filter((video) => video.isConnected);
    if (videos.length === 0) return null;
    const pictureInPicture = videos.find(
      (video) => mode(video) === 'picture-in-picture'
    );
    if (pictureInPicture) return pictureInPicture;
    const playing = videos.filter((video) => !video.paused && !video.ended);
    const candidates = playing.length > 0
        ? playing
        : videos.filter((video) => !video.ended);
    const pool = candidates.length > 0 ? candidates : videos;
    return pool.reduce(
      (selected, video) => area(video) > area(selected) ? video : selected
    );
  };
  const reportState = (forceBuffering = false) => {
    const video = selectVideo();
    if (!video) return;
    const playing = !video.paused && !video.ended;
    send('video-state', {
      playing: playing,
      buffering: playing && (
        forceBuffering ||
        video.readyState < HTMLMediaElement.HAVE_FUTURE_DATA
      ),
    });
  };
  window.__trickleVideoReportState = reportState;

  const observe = (video) => {
    if (video.__trickleObservedToken === observerToken) return;
    video.__trickleObservedToken = observerToken;
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    let inPictureInPicture = false;

    const listen = (event, callback) => {
      video.addEventListener(event, callback);
      cleanups.push(() => video.removeEventListener(event, callback));
    };

    const updatePresentation = () => {
      const active = mode(video) === 'picture-in-picture';
      if (active === inPictureInPicture) return;
      inPictureInPicture = active;
      send(active ? 'pip-start' : (video.paused ? 'pip-closed' : 'pip-stop'));
      reportState();
    };
    listen('webkitpresentationmodechanged', updatePresentation);
    listen('enterpictureinpicture', updatePresentation);
    listen('leavepictureinpicture', updatePresentation);
    listen('play', () => reportState(true));
    listen('playing', () => reportState());
    listen('pause', () => reportState());
    listen('waiting', () => reportState(true));
    listen('stalled', () => reportState(true));
    listen('canplay', () => reportState());
    listen('ended', () => reportState());
    listen('emptied', () => reportState());
    listen('error', () => {
      if (selectVideo() === video) send('video-error');
    });
    reportState();
  };
  const command = (video, action) => {
    if (action === 'play') video.play().catch(() => {});
    if (action === 'pause') video.pause();
    if (action === 'picture-in-picture') {
      if (video.webkitSupportsPresentationMode &&
          video.webkitSetPresentationMode) {
        try { video.webkitSetPresentationMode('picture-in-picture'); } catch (_) {}
      } else if (video.requestPictureInPicture) {
        video.requestPictureInPicture().catch(() => {});
      }
    }
  };
  const dispatchCommand = (action) => {
    if (action === 'pause') {
      document.querySelectorAll('video').forEach((video) => video.pause());
      setTimeout(() => reportState(), 0);
      return;
    }
    const video = selectVideo();
    if (!video) return;
    command(video, action);
    setTimeout(() => reportState(), 0);
    setTimeout(() => reportState(), 250);
  };
  const receiveCommand = (event) => {
    const action = event.data && event.data.__trickleVideoCommand;
    if (action === 'play' || action === 'pause' ||
        action === 'picture-in-picture') {
      dispatchCommand(action);
    }
  };
  window.addEventListener('message', receiveCommand);
  cleanups.push(() => window.removeEventListener('message', receiveCommand));
  const scan = (root) => {
    if (root instanceof HTMLVideoElement) observe(root);
    if (root.querySelectorAll) root.querySelectorAll('video').forEach(observe);
  };
  scan(document);
  const mutationObserver = new MutationObserver((changes) => {
    changes.forEach((change) => change.addedNodes.forEach(scan));
  });
  mutationObserver.observe(document, {childList: true, subtree: true});
  window.__trickleVideoObserverCleanup = () => {
    mutationObserver.disconnect();
    cleanups.splice(0).forEach((cleanup) => cleanup());
  };
  reportState();
})();
''';

final class _VideoThumbnail extends ConsumerWidget {
  const _VideoThumbnail({required this.articleId, required this.width});

  final String articleId;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: width,
      height: double.infinity,
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: ref
              .watch(articleProvider(articleId))
              .when(
                data: (article) => article == null
                    ? _placeholder()
                    : ArticleArtwork(
                        article: article,
                        size: width,
                        aspectRatio: 16 / 9,
                        radius: 0,
                      ),
                loading: _placeholder,
                error: (_, _) => _placeholder(),
              ),
        ),
      ),
    );
  }

  Widget _placeholder() => Artwork(
    size: width,
    aspectRatio: 16 / 9,
    radius: 0,
    icon: Icons.ondemand_video_rounded,
  );
}

final class _VideoError extends StatelessWidget {
  const _VideoError({
    required this.message,
    required this.onRetry,
    required this.onOpenOriginal,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: AppConstants.secondaryText,
              size: 38,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
                OutlinedButton(
                  onPressed: onOpenOriginal,
                  child: const Text('Open original'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

bool _isWrapperHost(String? host) =>
    host == 'yout-ube.com' || host == 'www.yout-ube.com';

bool _isPlaybackHost(String? host) =>
    host == 'youtube-nocookie.com' || host == 'www.youtube-nocookie.com';

bool _isOfficialYouTubeHost(String? host) {
  if (host == null) return false;
  final normalized = host.toLowerCase();
  return normalized == 'youtu.be' ||
      normalized == 'youtube.com' ||
      normalized.endsWith('.youtube.com');
}

double videoMiniPlayerHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.2);
  return 104 + (scale - 1) * 30;
}

String _javascriptString(String value) =>
    "'${value.replaceAll(r'\\', r'\\\\').replaceAll("'", r"\'")}'";

enum _VideoPhase { loading, buffering, playing, paused, error }

final class _VideoEvent {
  const _VideoEvent({
    required this.state,
    required this.sourceUri,
    required this.observerToken,
    required this.revision,
    required this.playing,
    required this.buffering,
  });

  final String state;
  final Uri sourceUri;
  final int observerToken;
  final int revision;
  final bool playing;
  final bool buffering;
}

extension on _VideoPhase {
  String get label => switch (this) {
    _VideoPhase.loading => 'Loading video',
    _VideoPhase.buffering => 'Buffering',
    _VideoPhase.playing => 'Playing',
    _VideoPhase.paused => 'Paused',
    _VideoPhase.error => 'Couldn’t play',
  };

  String get actionLabel => switch (this) {
    _VideoPhase.loading => 'Loading video',
    _VideoPhase.buffering || _VideoPhase.playing => 'Pause video',
    _VideoPhase.paused => 'Play video',
    _VideoPhase.error => 'Try video again',
  };

  IconData get icon => switch (this) {
    _VideoPhase.loading => Icons.hourglass_top_rounded,
    _VideoPhase.buffering || _VideoPhase.playing => Icons.pause_rounded,
    _VideoPhase.paused => Icons.play_arrow_rounded,
    _VideoPhase.error => Icons.refresh_rounded,
  };

  bool get isBusy => this == _VideoPhase.loading;
  bool get isError => this == _VideoPhase.error;
  bool get canToggle => this != _VideoPhase.loading;
}
