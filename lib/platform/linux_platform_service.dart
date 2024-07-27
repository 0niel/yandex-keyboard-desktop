import 'dart:async';
import 'dart:io';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:flutter/painting.dart' as painting;
import 'package:flutter/rendering.dart';
import 'platform_service.dart';

class LinuxPlatformService implements PlatformService {
  int _originalWindowHandle = 0;

  @override
  void setWindowFlags() {
    // appWindow
    //   ..alignment = Alignment.topRight
    //   ..show();
  }

  @override
  Future<String> getSelectedText() async {
    final result = await Process.run('xclip', ['-selection', 'clipboard', '-o']);
    return result.stdout;
  }

  @override
  Future<painting.Size> getScreenSize() async {
    final primaryScreen = await screenRetriever.getPrimaryDisplay();
    return painting.Size(primaryScreen.size.width, primaryScreen.size.height);
  }

  @override
  Future<Offset> getCursorPos() async {
    final cursorOffset = await screenRetriever.getCursorScreenPoint();
    return cursorOffset;
  }

  @override
  void replaceSelectedText(String newText) async {
    final process = await Process.start('xclip', ['-selection', 'clipboard']);
    process.stdin.write(newText);
    await process.stdin.close();
    await process.exitCode;
    await Process.run('xdotool', ['key', '--clearmodifiers', 'ctrl+v']);
  }

  @override
  int getForegroundWindow() {
    final result = Process.runSync('xdotool', ['getactivewindow']);
    return int.parse(result.stdout);
  }

  @override
  void setOriginalForegroundWindow(int handle) {
    _originalWindowHandle = handle;
  }

  @override
  Future<int> getFlutterWindowHandle() async {
    return 0;
  }
}
