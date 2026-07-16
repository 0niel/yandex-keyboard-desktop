import 'dart:io';

import 'package:yandex_keyboard_desktop/src/platform/linux/linux_platform_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_platform_gateway.dart';

final class PlatformRuntime {
  const PlatformRuntime({
    required this.selection,
    required this.overlay,
  });

  final SelectionPlatformGateway selection;
  final OverlayWindowGateway overlay;
}

PlatformRuntime createPlatformRuntime() {
  if (Platform.isWindows) {
    final gateway = WindowsPlatformGateway();
    return PlatformRuntime(selection: gateway, overlay: gateway);
  }
  if (Platform.isLinux) {
    final gateway = LinuxPlatformGateway();
    return PlatformRuntime(selection: gateway, overlay: gateway);
  }
  throw UnsupportedError('Unsupported platform');
}
