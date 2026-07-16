import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'text-assistant-settings-',
    );
    settingsFile = File('${temporaryDirectory.path}/settings.json');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('creates versioned defaults when settings do not exist', () async {
    final repository = FileSettingsRepository(file: settingsFile);

    final settings = await repository.load();

    expect(settings, AppSettings.defaults());
    final persisted = jsonDecode(await settingsFile.readAsString());
    expect(persisted['schemaVersion'], AppSettings.currentSchemaVersion);
  });

  test('does not consume or overwrite a removed settings schema', () async {
    final removedSource = jsonEncode({
      'hotkey': {
        'key': 'A',
        'modifiers': ['control'],
      },
      'autostart': true,
    });
    await settingsFile.writeAsString(removedSource);
    final repository = FileSettingsRepository(file: settingsFile);

    expect(
      repository.load,
      throwsA(isA<UnsupportedSettingsVersionException>()),
    );
    expect(await settingsFile.readAsString(), removedSource);
  });

  test('preserves corrupt input and recovers with defaults', () async {
    await settingsFile.writeAsString('{');
    final repository = FileSettingsRepository(
      file: settingsFile,
      now: () => DateTime.utc(2026, 7, 13, 10, 30),
    );

    final settings = await repository.load();

    expect(settings, AppSettings.defaults());
    expect(
      await File('${settingsFile.path}.corrupt-2026-07-13T10-30-00.000Z')
          .exists(),
      isTrue,
    );
    expect(await settingsFile.exists(), isTrue);
  });

  test('recovers when a nested binding has the wrong JSON type', () async {
    await settingsFile.writeAsString(jsonEncode({
      'schemaVersion': AppSettings.currentSchemaVersion,
      'activeProfile': {
        'id': 'default',
        'name': 'Default',
        'bindings': {'showOverlay': 'not-an-object'},
      },
    }));
    final repository = FileSettingsRepository(
      file: settingsFile,
      now: () => DateTime.utc(2026, 7, 13, 10, 31),
    );

    final settings = await repository.load();

    expect(settings, AppSettings.defaults());
    expect(
      await File('${settingsFile.path}.corrupt-2026-07-13T10-31-00.000Z')
          .exists(),
      isTrue,
    );
  });

  test('recovers an interrupted write from the backup', () async {
    final backup = File('${settingsFile.path}.backup');
    await backup.writeAsString(jsonEncode(AppSettings.defaults().toJson()));
    await File('${settingsFile.path}.tmp').writeAsString('incomplete');
    final repository = FileSettingsRepository(file: settingsFile);

    final settings = await repository.load();

    expect(settings, AppSettings.defaults());
    expect(await settingsFile.exists(), isTrue);
    expect(await File('${settingsFile.path}.tmp').exists(), isFalse);
  });

  test('preserves a future settings schema without overwriting it', () async {
    final futureSource = jsonEncode({
      'schemaVersion': AppSettings.currentSchemaVersion + 1,
      'future': true,
    });
    await settingsFile.writeAsString(futureSource);
    final repository = FileSettingsRepository(file: settingsFile);

    expect(
      repository.load,
      throwsA(isA<UnsupportedSettingsVersionException>()),
    );
    expect(await settingsFile.readAsString(), futureSource);
  });

  test('serializes overlapping saves in invocation order', () async {
    final repository = FileSettingsRepository(file: settingsFile);
    final first = AppSettings.defaults().copyWith(locale: 'en');
    final second = AppSettings.defaults().copyWith(locale: 'ru');

    await Future.wait([repository.save(first), repository.save(second)]);

    expect((await repository.load()).locale, 'ru');
    expect(await File('${settingsFile.path}.tmp').exists(), isFalse);
    expect(await File('${settingsFile.path}.backup').exists(), isFalse);
  });
}
