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

  test('background due calculation respects the selected interval', () async {
    final now = DateTime.utc(2026, 7, 14, 12);
    await settings.setRefreshInterval(RefreshInterval.every6Hours);
    expect(await settings.isBackgroundRefreshDue(now), isTrue);
    await settings.markBackgroundRefresh(now);
    expect(
      await settings.isBackgroundRefreshDue(
        now.add(const Duration(hours: 5, minutes: 59)),
      ),
      isFalse,
    );
    expect(
      await settings.isBackgroundRefreshDue(now.add(const Duration(hours: 6))),
      isTrue,
    );
    await settings.markBackgroundRefresh(now.add(const Duration(days: 1)));
    expect(await settings.isBackgroundRefreshDue(now), isTrue);
    await settings.setRefreshInterval(RefreshInterval.manual);
    expect(
      await settings.isBackgroundRefreshDue(now.add(const Duration(days: 30))),
      isFalse,
    );
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

  test('corrupt auto-delete values use the 24-hour fallback', () async {
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
        AutoDeletePolicy.after24Hours,
      );
    }
  });
}
