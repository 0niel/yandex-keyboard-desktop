import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:yandex_keyboard_desktop/platform/linux_platform_service.dart';
import 'package:yandex_keyboard_desktop/platform/platform_service_windows.dart';

abstract class PlatformService {
  void setWindowFlags();
  Future<String> getSelectedText();
  Future<Size> getScreenSize();
  Future<Offset> getCursorPos();
  void replaceSelectedText(String newText);
  int getForegroundWindow();
  void setOriginalForegroundWindow(
    int handle,
  );
  Future<int> getFlutterWindowHandle();
}

PlatformService getPlatformService() {
  if (Platform.isWindows) {
    return WindowsPlatformService();
  } else if (Platform.isLinux) {
    return LinuxPlatformService();
  } else {
    throw UnsupportedError('Unsupported platform');
  }
}
