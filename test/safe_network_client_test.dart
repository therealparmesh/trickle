import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/errors.dart';
import 'package:trickle/data/network/safe_network_client.dart';

void main() {
  test('streaming limit stops a response without a content length', () async {
    final adapter = _FakeAdapter((_, _) async {
      return ResponseBody(
        Stream.fromIterable([Uint8List(6), Uint8List(6)]),
        200,
      );
    });
    final client = _client(adapter);

    await expectLater(
      client.get(Uri.parse('https://example.test/feed'), maxBytes: 10),
      throwsA(isA<NetworkException>()),
    );
    client.close();
  });

  test('declared response limit cancels the unread response body', () async {
    final canceled = Completer<void>();
    final adapter = _FakeAdapter((_, cancelFuture) async {
      cancelFuture?.then((_) {
        if (!canceled.isCompleted) canceled.complete();
      });
      return ResponseBody(
        const Stream<Uint8List>.empty(),
        200,
        headers: {
          Headers.contentLengthHeader: ['11'],
        },
      );
    });
    final client = _client(adapter);

    await expectLater(
      client.get(Uri.parse('https://example.test/feed'), maxBytes: 10),
      throwsA(isA<NetworkException>()),
    );
    await canceled.future.timeout(const Duration(seconds: 1));
    client.close();
  });

  test(
    '304 is returned as not modified instead of treated as a redirect',
    () async {
      final adapter = _FakeAdapter((_, _) async {
        return ResponseBody.fromString(
          '',
          HttpStatus.notModified,
          headers: {
            'etag': ['"current"'],
          },
        );
      });
      final client = _client(adapter);

      final response = await client.get(
        Uri.parse('https://example.test/feed'),
        headers: const {'If-None-Match': '"current"'},
      );

      expect(response.statusCode, HttpStatus.notModified);
      expect(response.bytes, isEmpty);
      expect(response.header('etag'), '"current"');
      client.close();
    },
  );

  test('sensitive headers are stripped on a cross-origin redirect', () async {
    final requests = <RequestOptions>[];
    final adapter = _FakeAdapter((options, _) async {
      requests.add(options);
      if (requests.length == 1) {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://cdn.example.test/feed'],
          },
        );
      }
      return ResponseBody.fromString('ok', 200);
    });
    final client = _client(adapter);

    await client.get(
      Uri.parse('https://example.test/feed'),
      headers: const {
        'Authorization': 'Bearer secret',
        'Cookie': 'secret=true',
        'X-Public': 'kept',
      },
    );

    expect(requests, hasLength(2));
    expect(requests.last.headers.containsKey('Authorization'), isFalse);
    expect(requests.last.headers.containsKey('Cookie'), isFalse);
    expect(requests.last.headers['X-Public'], 'kept');
    client.close();
  });

  test(
    'media preflight validates redirects and returns safe headers',
    () async {
      final requests = <RequestOptions>[];
      final adapter = _FakeAdapter((options, _) async {
        requests.add(options);
        if (requests.length == 1) {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://cdn.example.test/audio.mp3'],
            },
          );
        }
        return ResponseBody.fromString('', 206);
      });
      final client = _client(adapter);

      final resource = await client.resolveResource(
        Uri.parse('https://example.test/audio'),
        headers: const {'Authorization': 'Bearer secret', 'X-Public': 'kept'},
      );

      expect(resource.url.toString(), 'https://cdn.example.test/audio.mp3');
      expect(resource.headers, {'X-Public': 'kept'});
      expect(requests, hasLength(2));
      expect(requests.first.headers['Range'], 'bytes=0-0');
      expect(requests.last.headers.containsKey('Authorization'), isFalse);
      client.close();
    },
  );

  test(
    'media preflight rejects an unsafe redirect before requesting it',
    () async {
      final requests = <RequestOptions>[];
      final adapter = _FakeAdapter((options, _) async {
        requests.add(options);
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://127.0.0.1/private'],
          },
        );
      });
      final client = SafeNetworkClient.forTesting(
        Dio()..httpClientAdapter = adapter,
        addressValidator: (uri) async {
          if (uri.host == '127.0.0.1') {
            throw const UnsafeAddressException('blocked');
          }
        },
      );

      await expectLater(
        client.resolveResource(Uri.parse('https://example.test/audio')),
        throwsA(isA<UnsafeAddressException>()),
      );
      expect(requests, hasLength(1));
      client.close();
    },
  );

  test('the absolute request deadline cancels a slow adapter', () async {
    final adapter = _FakeAdapter((_, cancelFuture) async {
      await cancelFuture;
      throw DioException(
        requestOptions: RequestOptions(path: 'https://example.test'),
        type: DioExceptionType.cancel,
      );
    });
    final client = _client(adapter);

    final stopwatch = Stopwatch()..start();
    await expectLater(
      client.get(
        Uri.parse('https://example.test/feed'),
        totalTimeout: const Duration(milliseconds: 40),
      ),
      throwsA(
        isA<NetworkException>().having(
          (error) => error.message,
          'message',
          'The request timed out.',
        ),
      ),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    client.close();
  });

  test('address filtering blocks local targets without overblocking /16s', () {
    for (final raw in const [
      '10.0.0.1',
      '100.64.0.1',
      '127.0.0.1',
      '169.254.10.20',
      '172.31.255.255',
      '192.168.1.1',
      '192.0.2.1',
      '198.18.0.1',
      '198.51.100.1',
      '203.0.113.1',
      '::1',
      'fc00::1',
      'fe80::1',
      'fec0::1',
      '2001:db8::1',
      '::ffff:192.168.1.1',
      '64:ff9b::10.0.0.1',
    ]) {
      expect(
        isPrivateOrReservedAddress(InternetAddress(raw)),
        isTrue,
        reason: raw,
      );
    }

    for (final raw in const [
      '8.8.8.8',
      '192.0.3.1',
      '198.51.99.1',
      '203.0.112.1',
      '2606:4700:4700::1111',
    ]) {
      expect(
        isPrivateOrReservedAddress(InternetAddress(raw)),
        isFalse,
        reason: raw,
      );
    }
  });
}

SafeNetworkClient _client(HttpClientAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return SafeNetworkClient.forTesting(dio, addressValidator: (_) async {});
}

final class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handler);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )
  _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handler(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}
