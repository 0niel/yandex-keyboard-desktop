import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

const double windowWidth = 325;
const double windowHeight = 50;

class WindowService with WindowListener {
  WindowService() {
    windowManager.addListener(this);
  }

  void dispose() {
    windowManager.removeListener(this);
  }

  Future<void> initializeWindow() async {
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(false);
    await windowManager.setSize(const Size(windowWidth, windowHeight));
    await windowManager.setAlwaysOnTop(true);
  }

  @override
  void onWindowClose() async {
    await initializeWindow();
    await windowManager.hide();
  }
}
