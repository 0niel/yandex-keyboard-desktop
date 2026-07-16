import 'dart:io';

import 'package:yandex_keyboard_desktop/src/platform/selection/platform_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/manual_clipboard_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/linux/linux_platform_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/uia_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/win32_uia_process_gateway.dart';

Future<SelectionBackend> createSelectionBackend(
  SelectionPlatformGateway platform,
) async {
  if (platform is LinuxPlatformGateway &&
      !await platform.supportsAutomaticSelectionReplacement()) {
    return ManualClipboardSelectionBackend();
  }
  return PlatformSelectionBackend(
    platform: platform,
    directSelectionReader: Platform.isWindows
        ? UiaSelectionReader(gateway: const Win32UiaProcessGateway())
        : null,
  );
}
