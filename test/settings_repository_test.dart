import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/data/database/app_database.dart';
import 'package:trickle/data/repositories/settings_repository.dart';

void main() {
  late AppDatabase database;
  late SettingsRepository settings;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsRepository(database);
  });

  tearDown(() => database.close());

  test(
    'global speed defaults to 1x and persists only allowed values',
    () async {
      expect(await settings.speed(), 100);
      await settings.setSpeed(175);
      expect(await settings.speed(), 175);
      expect(() => settings.setSpeed(110), throwsArgumentError);
    },
  );

  test('refresh interval defaults and persists', () async {
    expect(await settings.refreshInterval(), RefreshInterval.every4Hours);
    await settings.setRefreshInterval(RefreshInterval.every8Hours);
    expect(await settings.refreshInterval(), RefreshInterval.every8Hours);
    await database
        .into(database.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: 'refresh_interval',
            value: 'invalid',
            updatedAt: DateTime.utc(2026, 7, 19),
          ),
        );
    expect(await settings.refreshInterval(), RefreshInterval.every4Hours);
  });

  test(
    'corrupt stored speed never escapes the supported global values',
    () async {
      await database
          .into(database.appSettings)
          .insert(
            AppSettingsCompanion.insert(
              key: 'playback_speed',
              value: '999',
              updatedAt: DateTime.utc(2026, 7, 14),
            ),
          );
      expect(await settings.watchSpeed().first, AppConstants.defaultSpeed);
      expect(await settings.speed(), AppConstants.defaultSpeed);
    },
  );

  test('corrupt auto-delete values use the 1-day fallback', () async {
    Future<void> store(String value) => database
        .into(database.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: 'auto_delete',
            value: value,
            updatedAt: DateTime.utc(2026, 7, 14),
          ),
        );

    for (final value in const ['-1', '999', 'not-a-number']) {
      await store(value);
      expect(
        await settings.watchAutoDelete().first,
        AutoDeletePolicy.after1Day,
      );
    }
  });
}
