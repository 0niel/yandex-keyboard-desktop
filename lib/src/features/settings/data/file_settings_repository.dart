import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';

typedef Timestamp = DateTime Function();

abstract interface class SettingsRepository {
  Future<AppSettings> load();

  Future<void> save(AppSettings settings);
}

final class FileSettingsRepository implements SettingsRepository {
  FileSettingsRepository({
    required File file,
    AppSettingsCodec codec = const AppSettingsCodec(),
    Timestamp now = DateTime.now,
  })  : _file = file,
        _codec = codec,
        _now = now;

  final File _file;
  final AppSettingsCodec _codec;
  final Timestamp _now;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<AppSettings> load() => _serialize(_load);

  Future<AppSettings> _load() async {
    await _recoverInterruptedWrite();
    if (!await _file.exists()) {
      final defaults = AppSettings.defaults();
      await _save(defaults);
      return defaults;
    }

    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Settings root must be an object.');
      }
      return _codec.decode(decoded);
    } on FormatException {
      await _preserveCorruptFile();
      final defaults = AppSettings.defaults();
      await _save(defaults);
      return defaults;
    }
  }

  @override
  Future<void> save(AppSettings settings) => _serialize(() => _save(settings));

  Future<void> _save(AppSettings settings) async {
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    final backup = File('${_file.path}.backup');
    await temporary.writeAsString(
      jsonEncode(settings.toJson()),
      flush: true,
    );

    if (await backup.exists()) {
      await backup.delete();
    }
    var movedCurrent = false;
    try {
      if (await _file.exists()) {
        await _file.rename(backup.path);
        movedCurrent = true;
      }
      await temporary.rename(_file.path);
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (_) {
      if (!await _file.exists() && movedCurrent && await backup.exists()) {
        await backup.rename(_file.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<void> _recoverInterruptedWrite() async {
    final backup = File('${_file.path}.backup');
    if (!await _file.exists() && await backup.exists()) {
      await backup.rename(_file.path);
    } else if (await _file.exists() && await backup.exists()) {
      await backup.delete();
    }
    final temporary = File('${_file.path}.tmp');
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }

  Future<void> _preserveCorruptFile() async {
    if (!await _file.exists()) {
      return;
    }
    final timestamp = _now().toUtc().toIso8601String().replaceAll(':', '-');
    await _file.rename('${_file.path}.corrupt-$timestamp');
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
