import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../core/url_identity.dart';

const _maxMediaRedirects = 10;

final class NetworkDocument {
  const NetworkDocument({
    required this.url,
    required this.statusCode,
    required this.bytes,
    required this.headers,
  });

  final Uri url;
  final int statusCode;
  final Uint8List bytes;
  final Map<String, String> headers;

  String get text {
    if (bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }

  String? header(String name) => headers[name.toLowerCase()];
}

final class NetworkResource {
  const NetworkResource({required this.url, required this.headers});

  final Uri url;
  final Map<String, String> headers;
}

final class SafeNetworkClient {
  SafeNetworkClient._(this._dio, [this._addressValidator]);

  final Dio _dio;
  final Future<void> Function(Uri uri)? _addressValidator;

  factory SafeNetworkClient.forTesting(
    Dio dio, {
    required Future<void> Function(Uri uri) addressValidator,
  }) {
    return SafeNetworkClient._(dio, addressValidator);
  }

  static Future<SafeNetworkClient> create() async {
    final package = await PackageInfo.fromPlatform();
    final dio = Dio(
      BaseOptions(
        connectTimeout: AppConstants.networkConnectionTimeout,
        receiveTimeout: AppConstants.contentRequestTimeout,
        sendTimeout: AppConstants.networkConnectionTimeout,
        headers: {
          'User-Agent':
              'trickle/${package.version} (${Platform.operatingSystem}; podcast and RSS reader)',
          'Accept':
              'application/rss+xml, application/atom+xml, application/feed+json, application/json, text/xml, application/xml, text/html;q=0.8, */*;q=0.2',
        },
      ),
    );
    final httpClient = HttpClient();
    // The pinned connection factory connects to the validated origin address
    // directly; it does not implement HTTP proxy tunneling.
    httpClient.findProxy = (_) => 'DIRECT';
    httpClient.connectionFactory = (uri, proxyHost, proxyPort) async {
      final addresses = await InternetAddress.lookup(
        uri.host,
      ).timeout(AppConstants.networkConnectionTimeout);
      if (addresses.isEmpty || addresses.any(isPrivateOrReservedAddress)) {
        throw const SocketException('Unsafe server address');
      }
      // Retain explicit nonstandard ports and defensively supply HTTPS's
      // standard port if a platform omits it from the factory URI.
      final port = uri.port > 0 ? uri.port : 443;
      // Connect only to addresses from the validated lookup, trying the next
      // public address when a host's first IPv4/IPv6 route is unavailable.
      var canceled = false;
      ConnectionTask<Socket>? active;
      Socket? connected;
      final socket = () async {
        Object? lastError;
        for (final address in addresses) {
          if (canceled) {
            throw const SocketException('Connection attempt canceled');
          }
          try {
            active = await Socket.startConnect(address, port);
            final rawSocket = await active!.socket;
            connected = rawSocket;
            if (canceled) {
              rawSocket.destroy();
              throw const SocketException('Connection attempt canceled');
            }
            // A custom HttpClient connectionFactory must perform TLS itself
            // for direct HTTPS connections. Upgrade the pinned raw socket
            // using the original hostname for SNI and certificate checks.
            return await SecureSocket.secure(rawSocket, host: uri.host);
          } on Object catch (error) {
            connected?.destroy();
            connected = null;
            lastError = error;
          }
        }
        throw SocketException(
          'Could not connect to any resolved server address: $lastError',
        );
      }();
      return ConnectionTask.fromSocket(socket, () {
        canceled = true;
        active?.cancel();
        connected?.destroy();
      });
    };
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => httpClient,
    );
    return SafeNetworkClient._(dio);
  }

  Future<NetworkDocument> get(
    Uri requested, {
    int maxBytes = 10 * 1024 * 1024,
    Map<String, String> headers = const {},
    Duration totalTimeout = AppConstants.contentRequestTimeout,
  }) async {
    if (maxBytes <= 0 || totalTimeout <= Duration.zero) {
      throw ArgumentError('Limits and timeout must be positive.');
    }
    final stopwatch = Stopwatch()..start();
    var current = normalizeHttps(requested);
    var requestHeaders = Map<String, String>.of(headers);
    for (var redirects = 0; redirects <= 5; redirects++) {
      final dnsBudget = _remaining(totalTimeout, stopwatch);
      final validator = _addressValidator;
      if (validator == null) {
        await _validatePublicHttps(current, dnsBudget);
      } else {
        await validator(current).timeout(dnsBudget);
      }
      final cancelToken = CancelToken();
      var deadlineExpired = false;
      final timer = Timer(_remaining(totalTimeout, stopwatch), () {
        deadlineExpired = true;
        cancelToken.cancel('request deadline exceeded');
      });
      try {
        final response = await _dio.get<ResponseBody>(
          current.toString(),
          cancelToken: cancelToken,
          options: Options(
            headers: requestHeaders,
            responseType: ResponseType.stream,
            followRedirects: false,
            receiveDataWhenStatusError: true,
            validateStatus: (status) => status != null,
          ),
        );
        final status = response.statusCode ?? 0;
        final flattenedHeaders = <String, String>{
          for (final entry in response.headers.map.entries)
            entry.key.toLowerCase(): entry.value.join(', '),
        };
        if (status == HttpStatus.notModified) {
          cancelToken.cancel('not modified body is not needed');
          return NetworkDocument(
            url: current,
            statusCode: status,
            bytes: Uint8List(0),
            headers: flattenedHeaders,
          );
        }
        if (status >= 300 && status < 400) {
          final location = response.headers.value('location');
          if (location == null) {
            throw const NetworkException(
              'The server returned an invalid redirect.',
            );
          }
          if (redirects == 5) {
            throw const NetworkException(
              'The server redirected too many times.',
            );
          }
          cancelToken.cancel('redirect body is not needed');
          final next = normalizeHttps(current.resolve(location));
          if (!sameOrigin(current, next)) {
            requestHeaders = Map<String, String>.of(requestHeaders)
              ..removeWhere(
                (name, _) => const {
                  'authorization',
                  'cookie',
                  'proxy-authorization',
                }.contains(name.toLowerCase()),
              );
          }
          current = next;
          continue;
        }
        if (status < 200 || status >= 300) {
          cancelToken.cancel('error body is not needed');
          throw NetworkException('The server returned HTTP $status.');
        }
        final contentLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        );
        if (contentLength != null && contentLength > maxBytes) {
          cancelToken.cancel('response limit exceeded');
          throw const NetworkException(
            'The response is too large to open safely.',
          );
        }
        final body = response.data;
        if (body == null) {
          throw const NetworkException(
            'The server returned an empty response.',
          );
        }
        final builder = BytesBuilder(copy: false);
        var received = 0;
        await for (final chunk in body.stream) {
          received += chunk.length;
          if (received > maxBytes) {
            cancelToken.cancel('response limit exceeded');
            throw const NetworkException(
              'The response is too large to open safely.',
            );
          }
          builder.add(chunk);
        }
        return NetworkDocument(
          url: current,
          statusCode: status,
          bytes: builder.takeBytes(),
          headers: flattenedHeaders,
        );
      } on DioException catch (error) {
        if (deadlineExpired) {
          throw const NetworkException('The request timed out.');
        }
        throw NetworkException(_dioMessage(error));
      } finally {
        timer.cancel();
      }
    }
    throw const NetworkException('The server redirected too many times.');
  }

  /// Resolves a media redirect chain without buffering its body.
  ///
  /// Native playback and download clients receive the validated final URL and
  /// only the headers that remain safe after cross-origin redirects.
  Future<NetworkResource> resolveResource(
    Uri requested, {
    Map<String, String> headers = const {},
    Duration totalTimeout = AppConstants.interactiveRequestTimeout,
  }) async {
    if (totalTimeout <= Duration.zero) {
      throw ArgumentError.value(totalTimeout, 'totalTimeout');
    }
    final stopwatch = Stopwatch()..start();
    var current = normalizeHttps(requested);
    var requestHeaders = Map<String, String>.of(headers)
      ..removeWhere((name, _) => name.toLowerCase() == 'range');
    for (var redirects = 0; redirects <= _maxMediaRedirects; redirects++) {
      final dnsBudget = _remaining(totalTimeout, stopwatch);
      final validator = _addressValidator;
      if (validator == null) {
        await _validatePublicHttps(current, dnsBudget);
      } else {
        await validator(current).timeout(dnsBudget);
      }
      final cancelToken = CancelToken();
      var deadlineExpired = false;
      final timer = Timer(_remaining(totalTimeout, stopwatch), () {
        deadlineExpired = true;
        cancelToken.cancel('request deadline exceeded');
      });
      try {
        final response = await _dio.get<ResponseBody>(
          current.toString(),
          cancelToken: cancelToken,
          options: Options(
            headers: {...requestHeaders, 'Range': 'bytes=0-0'},
            responseType: ResponseType.stream,
            followRedirects: false,
            receiveDataWhenStatusError: true,
            validateStatus: (status) => status != null,
          ),
        );
        final status = response.statusCode ?? 0;
        if (status >= 300 && status < 400) {
          final location = response.headers.value('location');
          if (location == null) {
            throw const NetworkException(
              'The media server returned an invalid redirect.',
            );
          }
          if (redirects == _maxMediaRedirects) {
            throw const NetworkException(
              'The media server redirected too many times.',
            );
          }
          cancelToken.cancel('redirect body is not needed');
          final next = normalizeHttps(current.resolve(location));
          if (!sameOrigin(current, next)) {
            requestHeaders = Map<String, String>.of(requestHeaders)
              ..removeWhere(
                (name, _) => const {
                  'authorization',
                  'cookie',
                  'proxy-authorization',
                }.contains(name.toLowerCase()),
              );
          }
          current = next;
          continue;
        }
        cancelToken.cancel('media preflight body is not needed');
        if (status < 200 || status >= 300) {
          throw NetworkException('The media server returned HTTP $status.');
        }
        return NetworkResource(
          url: current,
          headers: Map<String, String>.unmodifiable(requestHeaders),
        );
      } on DioException catch (error) {
        if (deadlineExpired) {
          throw const NetworkException('The media request timed out.');
        }
        throw NetworkException(_dioMessage(error));
      } finally {
        timer.cancel();
      }
    }
    throw const NetworkException('The media server redirected too many times.');
  }

  Uri normalizeHttps(Uri input) {
    var uri = input;
    if (!uri.hasScheme) uri = Uri.parse('https://${uri.toString()}');
    if (uri.scheme == 'http') uri = uri.replace(scheme: 'https');
    if (uri.scheme != 'https') {
      throw const UnsafeAddressException(
        'Only secure HTTPS feeds are supported.',
      );
    }
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const UnsafeAddressException('That address is not valid.');
    }
    return uri;
  }

  Future<Uri> validatePublicAddress(
    Uri input, {
    Duration timeout = AppConstants.networkConnectionTimeout,
  }) async {
    final uri = normalizeHttps(input);
    await _validatePublicHttps(uri, timeout);
    return uri;
  }

  Duration _remaining(Duration total, Stopwatch stopwatch) {
    final remaining = total - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      throw const NetworkException('The request timed out.');
    }
    return remaining;
  }

  Future<void> _validatePublicHttps(Uri uri, Duration remaining) async {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const UnsafeAddressException(
        'Only secure public HTTPS addresses are supported.',
      );
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost')) {
      throw const UnsafeAddressException(
        'Local network addresses are blocked.',
      );
    }
    List<InternetAddress> addresses;
    try {
      final timeout = remaining < AppConstants.networkConnectionTimeout
          ? remaining
          : AppConstants.networkConnectionTimeout;
      addresses = await InternetAddress.lookup(host).timeout(timeout);
    } on TimeoutException {
      throw const NetworkException('The request timed out.');
    } on Object {
      throw const NetworkException('The server address couldn’t be resolved.');
    }
    if (addresses.isEmpty || addresses.any(isPrivateOrReservedAddress)) {
      throw const UnsafeAddressException(
        'Private or reserved network addresses are blocked.',
      );
    }
  }

  String _dioMessage(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout => 'The request timed out.',
      DioExceptionType.connectionError => 'Couldn’t connect to the server.',
      DioExceptionType.badCertificate =>
        'The server certificate is not trusted.',
      _ => 'The network request failed.',
    };
  }

  void close() => _dio.close(force: true);
}

/// Returns whether [address] must not be contacted by feed-controlled URLs.
///
/// This is public so the exact SSRF boundary can be regression tested without
/// performing real DNS requests.
bool isPrivateOrReservedAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return _isPrivateIpv4(bytes);
  }
  if (bytes.length != 16) return true;

  final allZero = bytes.every((value) => value == 0);
  final loopback =
      bytes.take(15).every((value) => value == 0) && bytes[15] == 1;
  if (allZero || loopback) return true;

  final ipv4Compatible = bytes.take(12).every((value) => value == 0);
  if (ipv4Compatible) return true;
  final mappedIpv4 =
      bytes.take(10).every((value) => value == 0) &&
      bytes[10] == 0xFF &&
      bytes[11] == 0xFF;
  if (mappedIpv4) return _isPrivateIpv4(bytes.sublist(12));

  final uniqueLocal = (bytes[0] & 0xFE) == 0xFC;
  final linkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80;
  final siteLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0xC0;
  final multicast = bytes[0] == 0xFF;
  final documentation =
      bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0D &&
      bytes[3] == 0xB8;
  final teredo =
      bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0;
  if (uniqueLocal ||
      linkLocal ||
      siteLocal ||
      multicast ||
      documentation ||
      teredo) {
    return true;
  }

  final wellKnownNat64 =
      bytes[0] == 0x00 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xFF &&
      bytes[3] == 0x9B &&
      bytes.sublist(4, 12).every((value) => value == 0);
  final localNat64 =
      bytes[0] == 0x00 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xFF &&
      bytes[3] == 0x9B &&
      bytes[4] == 0 &&
      bytes[5] == 1;
  if (wellKnownNat64 || localNat64) {
    return _isPrivateIpv4(bytes.sublist(12));
  }
  return false;
}

bool _isPrivateIpv4(List<int> bytes) {
  final a = bytes[0];
  final b = bytes[1];
  final c = bytes[2];
  if (a == 0 || a == 10 || a == 127 || a >= 224) return true;
  if (a == 100 && b >= 64 && b <= 127) return true;
  if (a == 169 && b == 254) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  if (a == 192 && b == 0 && (c == 0 || c == 2)) return true;
  if (a == 192 && b == 88 && c == 99) return true;
  if (a == 198 && (b == 18 || b == 19)) return true;
  if (a == 198 && b == 51 && c == 100) return true;
  if (a == 203 && b == 0 && c == 113) return true;
  return false;
}
