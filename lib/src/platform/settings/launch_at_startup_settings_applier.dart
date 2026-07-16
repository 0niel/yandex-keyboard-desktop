import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';

abstract interface class LaunchAtStartupAdapter {
  Future<bool> enable();

  Future<bool> disable();
}

final class SystemLaunchAtStartupAdapter implements LaunchAtStartupAdapter {
  const SystemLaunchAtStartupAdapter();

  @override
  Future<bool> enable() => launchAtStartup.enable();

  @override
  Future<bool> disable() => launchAtStartup.disable();
}

final class LaunchAtStartupSettingsApplier implements SettingsRuntimeApplier {
  const LaunchAtStartupSettingsApplier({
    LaunchAtStartupAdapter adapter = const SystemLaunchAtStartupAdapter(),
  }) : _adapter = adapter;

  final LaunchAtStartupAdapter _adapter;

  @override
  Future<void> apply({
    required AppSettings previous,
    required AppSettings next,
  }) async {
    final applied = next.launchAtStartup
        ? await _adapter.enable()
        : await _adapter.disable();
    if (!applied) {
      throw StateError('The launch-at-startup setting was rejected.');
    }
  }
}
