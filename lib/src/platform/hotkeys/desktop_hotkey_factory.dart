import 'package:yandex_keyboard_desktop/src/platform/hotkeys/global_shortcuts_portal_bridge.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_manager_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/noop_hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/wayland_portal_hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/windows_hotkey_registrar.dart';

bool isNativeWaylandSession(Map<String, String> environment) =>
    environment['WAYLAND_DISPLAY']?.isNotEmpty == true &&
    environment['GDK_BACKEND']?.toLowerCase() != 'x11';

HotkeyRegistrar createDesktopHotkeyRegistrar({
  required bool isLinux,
  required bool requiresManualPaste,
  required Map<String, String> environment,
  GlobalShortcutsPortalBridge? portalBridge,
  NativeHotkeyChannel? windowsChannel,
}) {
  if (isLinux && isNativeWaylandSession(environment)) {
    return WaylandPortalHotkeyRegistrar(
      bridge: portalBridge ?? MethodChannelGlobalShortcutsPortalBridge(),
    );
  }
  if (requiresManualPaste) return const NoOpHotkeyRegistrar();
  if (isLinux) return HotKeyManagerRegistrar();
  return WindowsHotkeyRegistrar(channel: windowsChannel);
}
