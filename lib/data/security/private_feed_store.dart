import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

final class PrivateFeedSecret {
  const PrivateFeedSecret({required this.url, required this.headers});

  final Uri url;
  final Map<String, String> headers;

  Map<String, Object?> toJson() => {'url': url.toString(), 'headers': headers};

  factory PrivateFeedSecret.fromJson(Map<String, Object?> json) {
    final rawHeaders = json['headers'] as Map<String, Object?>? ?? const {};
    return PrivateFeedSecret(
      url: Uri.parse(json['url'] as String),
      headers: rawHeaders.map((key, value) => MapEntry(key, value.toString())),
    );
  }
}

final class PrivateFeedStore {
  PrivateFeedStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const _prefix = 'private-feed:';
  static const _mediaPrefix = 'private-media:';
  final FlutterSecureStorage _storage;
  final Uuid _uuid = const Uuid();

  Future<String> save(PrivateFeedSecret secret, {String? existingId}) async {
    final id = existingId ?? _uuid.v4();
    await _storage.write(
      key: '$_prefix$id',
      value: jsonEncode(secret.toJson()),
    );
    return id;
  }

  Future<PrivateFeedSecret?> read(String id) async {
    final raw = await _storage.read(key: '$_prefix$id');
    if (raw == null) return null;
    return PrivateFeedSecret.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
  }

  Future<void> delete(String id) => _storage.delete(key: '$_prefix$id');

  Future<void> saveMediaUrl(String episodeId, Uri url) {
    return _storage.write(
      key: '$_mediaPrefix$episodeId',
      value: url.toString(),
    );
  }

  Future<Uri?> readMediaUrl(String episodeId) async {
    final value = await _storage.read(key: '$_mediaPrefix$episodeId');
    return value == null ? null : Uri.tryParse(value);
  }

  Future<void> deleteMediaUrl(String episodeId) {
    return _storage.delete(key: '$_mediaPrefix$episodeId');
  }

  Future<void> clearStaleInstallData() async {
    final values = await _storage.readAll();
    for (final key in values.keys) {
      if (key.startsWith(_prefix) || key.startsWith(_mediaPrefix)) {
        await _storage.delete(key: key);
      }
    }
  }
}
