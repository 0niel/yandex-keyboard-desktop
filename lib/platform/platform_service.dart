import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:yandex_keyboard_desktop/platform/platform_service_windows.dart';

abstract class PlatformService {
  void setWindowFlags();
  void setAutostart();
  void initTray();
  Future<String> getSelectedText();
  Size getScreenSize();
  Future<Offset> getCursorPos();
  void replaceSelectedText(String newText);
  int getForegroundWindow();
  void setOriginalForegroundWindow(
    int handle,
  );
}

PlatformService getPlatformService() {
  if (Platform.isWindows) {
    return WindowsPlatformService();
  } else {
    throw UnsupportedError('Unsupported platform');
  }
}
