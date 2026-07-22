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
  Future<void> _androidActivityTail = Future<void>.value();
  Uri? _androidPlaybackRequest;
  Uri? _loadedUri;
  Uri? _activeRequestUri;
  Timer? _loadTimeout;
  int _sessionGeneration = 0;
  int _progress = 0;
  bool _ready = false;
  bool _videoPlaying = false;
  bool _videoBuffering = false;
  bool _backgroundPresentationRequested = false;
  bool? _androidVideoActive;
  bool _androidPictureInPicture = false;
  bool _webPictureInPicture = false;
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
      unawaited(_setAndroidVideoActive(false));
    }
    _loadTimeout?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgroundPresentationRequested = false;
      return;
    }
    if (state != AppLifecycleState.inactive ||
        !_videoPlaying ||
        _backgroundPresentationRequested ||
        ref.read(videoSessionProvider) == null) {
      return;
    }
    _backgroundPresentationRequested = true;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(
        _sendVideoCommand('picture-in-picture').catchError((Object _) {}),
      );
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
    if (session != null && session.playbackUri != _loadedUri) {
      // Reserve this session before scheduling the load. A controller startup
      // failure must leave a stable retry state instead of scheduling itself
      // again on every rebuild.
      _loadedUri = session.playbackUri;
      final generation = ++_sessionGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(session, generation: generation));
      });
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (session != null && _webPictureInPicture) _player(context, session),
        ExcludeSemantics(
          excluding:
              session?.expanded == true &&
              session?.externalPresentation != true,
          child: widget.child,
        ),
        if (session != null && !_webPictureInPicture) _player(context, session),
      ],
    );
  }

  Widget _player(BuildContext context, VideoSession session) {
    final systemPresentation = _androidPictureInPicture || _webPictureInPicture;
    final expanded = session.expanded || systemPresentation;
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
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: const BorderSide(color: AppConstants.hairline),
                ),
          child: SafeArea(
            top: expanded && !systemPresentation,
            bottom: expanded && !systemPresentation,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final toolbarHeight = expanded
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
                          : (constraints.maxHeight - previewSize.height) / 2,
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
        if (!_ready || _error != null)
          ColoredBox(
            color: AppConstants.background,
            child: _error == null
                ? LoadingView(label: 'Loading video')
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
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        // The WebView stays attached when the player collapses into the
        // persistent Now Playing bar. WebKit can move the same media into
        // system Picture in Picture when the app leaves the foreground.
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
      onMessageReceived: _handleWebVideoState,
    );
    if (controller.platform case final WebKitWebViewController webKit) {
      await _installWebKitPresentationObserver(webKit);
    }
    await controller.setBackgroundColor(AppConstants.background);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onProgress: (progress) {
          if (mounted && ref.read(videoSessionProvider) != null) {
            setState(() => _progress = progress);
          }
        },
        onPageFinished: (url) =>
            unawaited(_finishPageLoad(controller, Uri.tryParse(url))),
        onWebResourceError: (error) {
          if (!mounted || ref.read(videoSessionProvider) == null) {
            return;
          }
          final failedUri = Uri.tryParse(error.url ?? '');
          if (error.isForMainFrame == false || failedUri == null) {
            return;
          }
          if (error.isForMainFrame != true && failedUri != _activeRequestUri) {
            return;
          }
          if (!_isActiveLoadUri(failedUri)) return;
          _fallbackOrShowError();
        },
        onHttpError: (error) {
          if (!mounted || ref.read(videoSessionProvider) == null) return;
          final failedUri = error.request?.uri ?? error.response?.uri;
          if (_isActiveLoadUri(failedUri)) _fallbackOrShowError();
        },
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (!_usingOfficialFallback &&
              controller.platform is AndroidWebViewController &&
              uri != null &&
              _isPlaybackHost(uri.host) &&
              _isCurrentVideo(uri) &&
              _androidPlaybackRequest != uri) {
            _androidPlaybackRequest = uri;
            final generation = _sessionGeneration;
            unawaited(
              _serializeNavigation(() async {
                if (generation != _sessionGeneration ||
                    ref.read(videoSessionProvider) == null) {
                  return;
                }
                await controller.loadRequest(
                  uri,
                  headers: {
                    'Referer':
                        ref
                            .read(videoSessionProvider)
                            ?.playbackUri
                            .toString() ??
                        'https://www.yout-ube.com/',
                  },
                );
              }).catchError((Object _) {
                if (mounted &&
                    generation == _sessionGeneration &&
                    _source == VideoPlaybackSource.privacyWrapper &&
                    _isActiveLoadUri(uri)) {
                  _fallbackOrShowError(generation: generation);
                }
              }),
            );
            return NavigationDecision.prevent;
          }
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

  Future<void> _finishPageLoad(WebViewController controller, Uri? uri) async {
    if (!mounted ||
        ref.read(videoSessionProvider) == null ||
        !_isActivePlaybackUri(uri)) {
      return;
    }
    if (controller.platform is AndroidWebViewController) {
      try {
        // Android cannot install a WKUserScript in every frame. The privacy
        // wrapper redirect and the official fallback both put the playable
        // video in the main document, so observe it once that page is ready.
        await controller.runJavaScript(_videoPresentationObserver);
      } on Object {
        // Foreground playback remains usable if state observation is blocked.
      }
    }
    if (!mounted ||
        ref.read(videoSessionProvider) == null ||
        !_isActivePlaybackUri(uri)) {
      return;
    }
    _loadTimeout?.cancel();
    setState(() {
      _progress = 100;
      _ready = true;
      _videoBuffering = false;
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
    _androidPlaybackRequest = null;
    _resetSystemPresentation();
    unawaited(_setAndroidVideoActive(false));
    _loadTimeout?.cancel();
    if (mounted) {
      setState(() {
        _progress = 0;
        _ready = false;
        _videoPlaying = false;
        _videoBuffering = false;
        _error = null;
      });
    }
    late final WebViewController controller;
    try {
      controller = await (_controllerInitialization ??= _createController());
    } on Object {
      _controllerInitialization = null;
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
    try {
      await ref.read(audioHandlerProvider).activateWebVideoAudioSession();
    } on Object {
      // Foreground video remains usable if the audio session cannot activate.
    }
    if (!_isCurrentSession(session, generation) ||
        _activeRequestUri != requestUri) {
      return;
    }
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
    unawaited(_setAndroidVideoActive(false));
    setState(() {
      _ready = false;
      _videoPlaying = false;
      _videoBuffering = false;
      _error = message;
    });
  }

  Future<void> _close() async {
    final generation = ++_sessionGeneration;
    ref.read(videoSessionProvider.notifier).close();
    _resetSystemPresentation(updateSession: false);
    _loadTimeout?.cancel();
    _loadedUri = null;
    _activeRequestUri = null;
    _ready = false;
    _videoPlaying = false;
    _videoBuffering = false;
    _backgroundPresentationRequested = false;
    _source = VideoPlaybackSource.privacyWrapper;
    _error = null;
    final controller = _controller;
    final stopPlayback = controller == null
        ? Future<void>.value()
        : _serializeNavigation(() async {
            if (generation != _sessionGeneration ||
                ref.read(videoSessionProvider) != null) {
              return;
            }
            try {
              await controller.loadHtmlString(
                '<!doctype html><html><body style="margin:0;background:#06080d"></body></html>',
              );
            } on Object {
              // Removing the platform view also stops playback.
            }
          });
    await Future.wait([_setAndroidVideoActive(false), stopPlayback]);
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
    if (call.method != 'pictureInPictureChanged') return null;
    if (!mounted) return null;
    final active = call.arguments == true;
    if (_androidPictureInPicture != active) {
      setState(() => _androidPictureInPicture = active);
      ref.read(videoSessionProvider.notifier).setExternalPresentation(active);
    }
    return null;
  }

  void _handleWebVideoState(JavaScriptMessage message) {
    if (!mounted || ref.read(videoSessionProvider) == null) return;
    final event = _decodeVideoEvent(message.message);
    if (event == null || !_isActivePlaybackUri(event.sourceUri)) return;
    switch (event.state) {
      case 'pip-start':
        if (_webPictureInPicture) return;
        setState(() => _webPictureInPicture = true);
        ref.read(videoSessionProvider.notifier).setExternalPresentation(true);
      case 'pip-stop':
        if (!_webPictureInPicture) return;
        setState(() => _webPictureInPicture = false);
        ref.read(videoSessionProvider.notifier).setExternalPresentation(false);
      case 'video-playing':
        _updateVideoPlayback(playing: true, buffering: false);
      case 'video-paused' || 'video-ended':
        _updateVideoPlayback(playing: false, buffering: false);
      case 'video-buffering':
        _updateVideoPlayback(playing: _videoPlaying, buffering: true);
      case 'video-ready':
        _updateVideoPlayback(playing: _videoPlaying, buffering: false);
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
      if (state is! String || url is! String) return null;
      final sourceUri = Uri.tryParse(url);
      if (sourceUri == null) return null;
      return _VideoEvent(state, sourceUri);
    } on FormatException {
      return null;
    }
  }

  void _updateVideoPlayback({required bool playing, required bool buffering}) {
    if (!mounted ||
        (_ready &&
            _error == null &&
            _videoPlaying == playing &&
            _videoBuffering == buffering)) {
      return;
    }
    _loadTimeout?.cancel();
    setState(() {
      _ready = true;
      _error = null;
      _videoPlaying = playing;
      _videoBuffering = buffering;
    });
    unawaited(_setAndroidVideoActive(playing));
  }

  Future<void> _toggleVideoPlayback(VideoSession session) async {
    if (_error != null) {
      await _load(session, generation: _sessionGeneration);
      return;
    }
    if (!_ready) return;
    try {
      await _sendVideoCommand(_videoPlaying ? 'pause' : 'play');
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

  Future<void> _serializeNavigation(Future<void> Function() operation) {
    final result = _navigationTail.then((_) => operation());
    _navigationTail = result.catchError((Object _) {});
    return result;
  }

  Future<void> _installWebKitPresentationObserver(
    WebKitWebViewController controller,
  ) async {
    try {
      await _platformChannel.invokeMethod<void>(
        'installWebKitPresentationObserver',
        <String, Object>{
          'webViewIdentifier': controller.webViewIdentifier,
          'source': _videoPresentationObserver,
        },
      );
    } on MissingPluginException {
      // Unsupported hosts keep normal foreground video playback.
    } on PlatformException {
      // Unsupported hosts keep normal foreground video playback.
    }
  }

  void _resetSystemPresentation({bool updateSession = true}) {
    _androidPictureInPicture = false;
    _webPictureInPicture = false;
    if (updateSession) {
      ref.read(videoSessionProvider.notifier).setExternalPresentation(false);
    }
  }

  Future<void> _setAndroidVideoActive(bool active) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_androidVideoActive == active) return;
    _androidVideoActive = active;
    final result = _androidActivityTail.then((_) async {
      try {
        await _platformChannel.invokeMethod<void>('setVideoActive', active);
      } on MissingPluginException {
        // Widget tests and unsupported Android devices have no host channel.
      } on PlatformException {
        // Foreground video remains usable if PiP is unavailable.
      }
    });
    _androidActivityTail = result.catchError((Object _) {});
    await result;
  }

  _VideoPhase get _videoPhase {
    if (_error != null) return _VideoPhase.error;
    if (!_ready) return _VideoPhase.loading;
    if (_videoBuffering) return _VideoPhase.buffering;
    return _videoPlaying ? _VideoPhase.playing : _VideoPhase.paused;
  }
}

const _videoPresentationObserver = r'''
(() => {
  if (window.__trickleVideoObserver) return;
  window.__trickleVideoObserver = true;

  const sendState = (state) => {
    try {
      window.TrickleVideoState.postMessage(JSON.stringify({
        state: state,
        url: window.location.href,
      }));
    } catch (_) {}
  };
  const notify = (active) => {
    sendState(active ? 'pip-start' : 'pip-stop');
  };
  const mode = (video) => {
    if (video.webkitPresentationMode) return video.webkitPresentationMode;
    return document.pictureInPictureElement === video
        ? 'picture-in-picture'
        : 'inline';
  };
  const observe = (video) => {
    if (video.__trickleObserved) return;
    video.__trickleObserved = true;
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    let inPictureInPicture = false;
    let resumeAfterPictureInPicture = false;
    let pauseTimer;

    const update = () => {
      const active = mode(video) === 'picture-in-picture';
      if (active && !inPictureInPicture) {
        clearTimeout(pauseTimer);
        resumeAfterPictureInPicture = !video.paused;
        inPictureInPicture = true;
        notify(true);
        return;
      }
      if (!active && inPictureInPicture) {
        clearTimeout(pauseTimer);
        const shouldResume = resumeAfterPictureInPicture;
        inPictureInPicture = false;
        notify(false);
        if (shouldResume && video.paused) {
          setTimeout(() => video.play().catch(() => {}), 0);
        }
      }
    };
    video.addEventListener('webkitpresentationmodechanged', update);
    video.addEventListener('enterpictureinpicture', update);
    video.addEventListener('leavepictureinpicture', update);
    video.addEventListener('play', () => {
      notifyState('video-playing');
      if (inPictureInPicture) resumeAfterPictureInPicture = true;
    });
    video.addEventListener('pause', () => {
      notifyState(video.ended ? 'video-ended' : 'video-paused');
      if (!inPictureInPicture) return;
      clearTimeout(pauseTimer);
      pauseTimer = setTimeout(() => {
        if (inPictureInPicture && mode(video) === 'picture-in-picture') {
          resumeAfterPictureInPicture = false;
        }
      }, 300);
    });
    video.addEventListener('playing', () => notifyState('video-playing'));
    video.addEventListener('waiting', () => notifyState('video-buffering'));
    video.addEventListener('stalled', () => notifyState('video-buffering'));
    video.addEventListener('canplay', () => notifyState('video-ready'));
    video.addEventListener('ended', () => notifyState('video-ended'));
    video.addEventListener('error', () => notifyState('video-error'));
    notifyState(video.paused ? 'video-paused' : 'video-playing');
  };
  const notifyState = sendState;
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
    document.querySelectorAll('video').forEach((video) => command(video, action));
    document.querySelectorAll('iframe').forEach((frame) => {
      try {
        frame.contentWindow.postMessage({__trickleVideoCommand: action}, '*');
      } catch (_) {}
    });
  };
  window.addEventListener('message', (event) => {
    const action = event.data && event.data.__trickleVideoCommand;
    if (action === 'play' || action === 'pause' ||
        action === 'picture-in-picture') {
      dispatchCommand(action);
    }
  });
  const scan = (root) => {
    if (root instanceof HTMLVideoElement) observe(root);
    if (root.querySelectorAll) root.querySelectorAll('video').forEach(observe);
  };
  scan(document);
  new MutationObserver((changes) => {
    changes.forEach((change) => change.addedNodes.forEach(scan));
  }).observe(document, {childList: true, subtree: true});
})();
''';

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
  const _VideoEvent(this.state, this.sourceUri);

  final String state;
  final Uri sourceUri;
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
