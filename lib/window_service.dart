import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

const double windowWidth = 325;
const double windowHeight = 50;

class WindowService {
  static Future<void> initializeWindow() async {
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    await windowManager.setSize(const Size(windowWidth, windowHeight));
    await windowManager.setAlwaysOnTop(true);
  }
}
