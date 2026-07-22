import 'dart:async';

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

class _VideoPlayerHostState extends ConsumerState<VideoPlayerHost> {
  static const _platformChannel = MethodChannel('com.parmscript.trickle/video');

  WebViewController? _controller;
  Future<WebViewController>? _controllerInitialization;
  Uri? _androidPlaybackRequest;
  Uri? _loadedUri;
  Uri? _activeRequestUri;
  Timer? _loadTimeout;
  int _progress = 0;
  bool _ready = false;
  bool _androidPictureInPicture = false;
  bool _webPictureInPicture = false;
  VideoPlaybackSource _source = VideoPlaybackSource.privacyWrapper;
  String? _error;

  bool get _usingOfficialFallback =>
      _source == VideoPlaybackSource.officialYouTube;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.android) {
      _platformChannel.setMethodCallHandler(_handlePlatformCall);
    }
  }

  @override
  void dispose() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      _platformChannel.setMethodCallHandler(null);
      unawaited(_setAndroidVideoActive(false));
    }
    _loadTimeout?.cancel();
    super.dispose();
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(session));
      });
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (session != null && _webPictureInPicture) _player(context, session),
        ExcludeSemantics(
          excluding: session?.expanded == true,
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
                final previewWidth = expanded
                    ? constraints.maxWidth
                    : (constraints.maxWidth * 0.38).clamp(116.0, 180.0);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: 0,
                      top: toolbarHeight,
                      right: expanded ? 0 : constraints.maxWidth - previewWidth,
                      bottom: 0,
                      child: IgnorePointer(
                        ignoring: !expanded,
                        child: ColoredBox(
                          color: Colors.black,
                          child: _webContent(session),
                        ),
                      ),
                    ),
                    if (systemPresentation)
                      const SizedBox.shrink()
                    else if (expanded)
                      _expandedToolbar(context, session, toolbarHeight)
                    else
                      _miniControls(context, session, previewWidth),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _webContent(VideoSession session) {
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
                ? LoadingView(
                    label: _usingOfficialFallback
                        ? 'Loading from YouTube'
                        : 'Loading video',
                  )
                : _VideoError(
                    message: _error!,
                    onRetry: () => _load(session),
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
                  tooltip: 'Minimize video',
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
    return Row(
      children: [
        SizedBox(
          width: previewWidth,
          child: Semantics(
            button: true,
            label: 'Expand video',
            child: InkWell(
              onTap: () => ref.read(videoSessionProvider.notifier).expand(),
            ),
          ),
        ),
        Expanded(
          child: InkWell(
            onTap: () => ref.read(videoSessionProvider.notifier).expand(),
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                session.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(height: 1.2),
              ),
            ),
          ),
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
        // Inline WebKit video is suspended when iOS backgrounds the app.
        // System presentation provides the supported fullscreen/PiP path.
        allowsInlineMediaPlayback: false,
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
        onPageFinished: (url) {
          final uri = Uri.tryParse(url);
          if (mounted &&
              ref.read(videoSessionProvider) != null &&
              _isActivePlaybackUri(uri)) {
            _loadTimeout?.cancel();
            unawaited(_setAndroidVideoActive(true));
            setState(() {
              _progress = 100;
              _ready = true;
              _error = null;
            });
          }
        },
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
          if (!request.isMainFrame) return NavigationDecision.navigate;
          if (!_usingOfficialFallback &&
              controller.platform is AndroidWebViewController &&
              uri != null &&
              _isPlaybackHost(uri.host) &&
              _isCurrentVideo(uri) &&
              _androidPlaybackRequest != uri) {
            _androidPlaybackRequest = uri;
            unawaited(
              controller.loadRequest(
                uri,
                headers: {
                  'Referer':
                      ref.read(videoSessionProvider)?.playbackUri.toString() ??
                      'https://www.yout-ube.com/',
                },
              ),
            );
            return NavigationDecision.prevent;
          }
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

  Future<void> _load(
    VideoSession session, {
    VideoPlaybackSource source = VideoPlaybackSource.privacyWrapper,
  }) async {
    final requestUri = session.playbackUriFor(source);
    if (requestUri == null) {
      _showLoadError('Couldn’t load this video.');
      return;
    }
    final sessionUri = session.playbackUri;
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
        _error = null;
      });
    }
    late final WebViewController controller;
    try {
      controller = await (_controllerInitialization ??= _createController());
    } on Object {
      _controllerInitialization = null;
      if (mounted && ref.read(videoSessionProvider) != null) {
        _showLoadError('Couldn’t start the video player.');
      }
      return;
    }
    if (!mounted ||
        ref.read(videoSessionProvider)?.playbackUri != sessionUri ||
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
    if (!mounted ||
        ref.read(videoSessionProvider)?.playbackUri != sessionUri ||
        _activeRequestUri != requestUri) {
      return;
    }
    _loadTimeout = Timer(AppConstants.videoSourceLoadTimeout, () {
      if (mounted && !_ready && ref.read(videoSessionProvider) != null) {
        _fallbackOrShowError(timedOut: true);
      }
    });
    try {
      await controller.loadRequest(requestUri);
    } on Object {
      if (mounted &&
          ref.read(videoSessionProvider) != null &&
          _activeRequestUri == requestUri) {
        _fallbackOrShowError();
      }
    }
  }

  void _fallbackOrShowError({bool timedOut = false}) {
    if (!mounted) return;
    _loadTimeout?.cancel();
    final session = ref.read(videoSessionProvider);
    final fallback = _source.fallbackAfterFailure;
    if (fallback != null && session != null) {
      unawaited(_load(session, source: fallback));
      return;
    }
    _showLoadError(
      timedOut
          ? 'YouTube took too long to load this video.'
          : 'Couldn’t load this video from YouTube.',
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

  void _showLoadError(String message) {
    if (!mounted) return;
    _loadTimeout?.cancel();
    unawaited(_setAndroidVideoActive(false));
    setState(() {
      _ready = false;
      _error = message;
    });
  }

  Future<void> _close() async {
    ref.read(videoSessionProvider.notifier).close();
    _resetSystemPresentation(updateSession: false);
    await _setAndroidVideoActive(false);
    _loadTimeout?.cancel();
    _loadedUri = null;
    _activeRequestUri = null;
    _ready = false;
    _source = VideoPlaybackSource.privacyWrapper;
    _error = null;
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.loadHtmlString(
        '<!doctype html><html><body style="margin:0;background:#06080d"></body></html>',
      );
    } on Object {
      // Removing the platform view also stops playback.
    }
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
    final active = switch (message.message) {
      'pip-start' => true,
      'pip-stop' => false,
      _ => null,
    };
    if (active == null || _webPictureInPicture == active) return;
    setState(() => _webPictureInPicture = active);
    ref.read(videoSessionProvider.notifier).setExternalPresentation(active);
  }

  Future<void> _installWebKitPresentationObserver(
    WebKitWebViewController controller,
  ) async {
    try {
      await _platformChannel.invokeMethod<void>(
        'installWebKitPresentationObserver',
        <String, Object>{
          'webViewIdentifier': controller.webViewIdentifier,
          'source': _webKitPresentationObserver,
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
    try {
      await _platformChannel.invokeMethod<void>('setVideoActive', active);
    } on MissingPluginException {
      // Widget tests and unsupported Android devices have no host channel.
    } on PlatformException {
      // Foreground video remains usable if PiP is unavailable.
    }
  }
}

const _webKitPresentationObserver = r'''
(() => {
  if (window.__tricklePresentationObserver) return;
  window.__tricklePresentationObserver = true;

  const notify = (active) => {
    try {
      window.TrickleVideoState.postMessage(active ? 'pip-start' : 'pip-stop');
    } catch (_) {}
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
      if (inPictureInPicture) resumeAfterPictureInPicture = true;
    });
    video.addEventListener('pause', () => {
      if (!inPictureInPicture) return;
      clearTimeout(pauseTimer);
      pauseTimer = setTimeout(() => {
        if (inPictureInPicture && mode(video) === 'picture-in-picture') {
          resumeAfterPictureInPicture = false;
        }
      }, 300);
    });
  };
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
