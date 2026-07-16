import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/platform/settings/launch_at_startup_settings_applier.dart';

void main() {
  test('enables startup from the next settings snapshot', () async {
    final adapter = _FakeLaunchAtStartupAdapter();
    final applier = LaunchAtStartupSettingsApplier(adapter: adapter);

    await applier.apply(
      previous: AppSettings.defaults(),
      next: AppSettings.defaults().copyWith(launchAtStartup: true),
    );

    expect(adapter.enableCalls, 1);
    expect(adapter.disableCalls, 0);
  });

  test('surfaces rejected platform changes', () async {
    final adapter = _FakeLaunchAtStartupAdapter()..result = false;
    final applier = LaunchAtStartupSettingsApplier(adapter: adapter);

    expect(
      () => applier.apply(
        previous: AppSettings.defaults(),
        next: AppSettings.defaults(),
      ),
      throwsStateError,
    );
  });
}

final class _FakeLaunchAtStartupAdapter implements LaunchAtStartupAdapter {
  bool result = true;
  int enableCalls = 0;
  int disableCalls = 0;

  @override
  Future<bool> enable() async {
    enableCalls++;
    return result;
  }

  @override
  Future<bool> disable() async {
    disableCalls++;
    return result;
  }
}
