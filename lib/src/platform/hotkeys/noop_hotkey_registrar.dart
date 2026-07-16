import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';

final class NoOpHotkeyRegistrar implements HotkeyRegistrar {
  const NoOpHotkeyRegistrar();

  @override
  Future<void> replaceProfile({
    required KeyBindingProfile previous,
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  }) async {}

  @override
  Future<void> unregisterAll() async {}
}
