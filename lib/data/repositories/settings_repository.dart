import '../../core/constants.dart';
import '../database/app_database.dart';

final class SettingsRepository {
  SettingsRepository(this._database);

  final AppDatabase _database;

  static const _speedKey = 'playback_speed';
  static const _silenceKey = 'silence_trim';
  static const _voiceBoostKey = 'voice_boost';
  static const _autoDeleteKey = 'auto_delete';
  static const _refreshKey = 'refresh_interval';
  static const _remoteImagesKey = 'remote_images';
  static const _lastBackgroundRefreshKey = 'last_background_refresh';

  Stream<int> watchSpeed() => _watch(_speedKey).map(_parseSpeed);

  int _parseSpeed(String? value) {
    final parsed = int.tryParse(value ?? '');
    return AppConstants.allowedSpeeds.contains(parsed)
        ? parsed!
        : AppConstants.defaultSpeed;
  }

  Future<int> speed() async => _parseSpeed(await _read(_speedKey));

  Future<void> setSpeed(int value) async {
    if (!AppConstants.allowedSpeeds.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Unsupported playback speed');
    }
    await _write(_speedKey, '$value');
  }

  Stream<bool> watchSilenceTrim() => _watchBool(_silenceKey, false);
  Future<bool> silenceTrim() => _readBool(_silenceKey, false);
  Future<void> setSilenceTrim(bool value) => _write(_silenceKey, '$value');

  Stream<bool> watchVoiceBoost() => _watchBool(_voiceBoostKey, false);
  Future<bool> voiceBoost() => _readBool(_voiceBoostKey, false);
  Future<void> setVoiceBoost(bool value) => _write(_voiceBoostKey, '$value');

  Stream<AutoDeletePolicy> watchAutoDelete() {
    return _watch(_autoDeleteKey).map((value) {
      final index = int.tryParse(value ?? '');
      if (index == null ||
          index < 0 ||
          index >= AutoDeletePolicy.values.length) {
        return AutoDeletePolicy.after24Hours;
      }
      return AutoDeletePolicy.values[index];
    });
  }

  Future<void> setAutoDelete(AutoDeletePolicy value) {
    return _write(_autoDeleteKey, '${value.index}');
  }

  Stream<RefreshInterval> watchRefreshInterval() =>
      _watch(_refreshKey).map(_parseRefreshInterval);

  Future<void> setRefreshInterval(RefreshInterval value) {
    return _write(_refreshKey, value.name);
  }

  Stream<bool> watchRemoteImages() => _watchBool(_remoteImagesKey, true);
  Future<void> setRemoteImages(bool value) =>
      _write(_remoteImagesKey, '$value');

  RefreshInterval _parseRefreshInterval(String? value) {
    return RefreshInterval.values.firstWhere(
      (interval) => interval.name == value,
      orElse: () => RefreshInterval.every6Hours,
    );
  }

  Future<RefreshInterval> _refreshInterval() async =>
      _parseRefreshInterval(await _read(_refreshKey));

  Future<bool> isBackgroundRefreshDue(DateTime now) async {
    final interval = await _refreshInterval();
    if (interval == RefreshInterval.manual) return false;
    final raw = await _read(_lastBackgroundRefreshKey);
    final previous = raw == null ? null : DateTime.tryParse(raw);
    return previous == null ||
        previous.isAfter(now) ||
        now.difference(previous) >= interval.duration;
  }

  Future<void> markBackgroundRefresh(DateTime at) {
    return _write(_lastBackgroundRefreshKey, at.toUtc().toIso8601String());
  }

  Stream<String?> _watch(String key) {
    return (_database.select(_database.appSettings)
          ..where((row) => row.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  Stream<bool> _watchBool(String key, bool fallback) {
    return _watch(key).map((value) => _parseBool(value, fallback));
  }

  Future<String?> _read(String key) async {
    final row = await (_database.select(
      _database.appSettings,
    )..where((candidate) => candidate.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<bool> _readBool(String key, bool fallback) async {
    return _parseBool(await _read(key), fallback);
  }

  bool _parseBool(String? value, bool fallback) {
    return switch (value) {
      'true' => true,
      'false' => false,
      _ => fallback,
    };
  }

  Future<void> _write(String key, String value) {
    return _database
        .into(_database.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: key,
            value: value,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }
}
