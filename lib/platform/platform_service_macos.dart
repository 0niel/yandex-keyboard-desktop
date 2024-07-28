import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:clipboard/clipboard.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'platform_service.dart';

class MacOSPlatformService implements PlatformService {
  int _originalWindowHandle = 0;

  @override
  Future<String> getSelectedText() async {
    if (_originalWindowHandle == 0) {
      _originalWindowHandle = getForegroundWindow();
    }

    await Process.run('osascript', ['-e', 'tell application "System Events" to keystroke "c" using {command down}']);

    await Future.delayed(const Duration(milliseconds: 100));
    return await FlutterClipboard.paste();
  }

  @override
  Future<Size> getScreenSize() async {
    final result = Process.runSync('system_profiler', ['SPDisplaysDataType']);
    final output = result.stdout.toString();
    final match = RegExp(r'Resolution: (\d+) x (\d+)').firstMatch(output);
    if (match != null) {
      final width = int.parse(match.group(1)!);
      final height = int.parse(match.group(2)!);
      return Size(width.toDouble(), height.toDouble());
    }
    return Size.zero;
  }

  @override
  Future<Offset> getCursorPos() async {
    final cursorOffset = await screenRetriever.getCursorScreenPoint();
    return cursorOffset;
  }

  @override
  void replaceSelectedText(String newText) {
    if (_originalWindowHandle != 0) {
      Future.delayed(const Duration(milliseconds: 100), () {
        Process.run('osascript', ['-e', 'tell application "System Events" to keystroke "v" using {command down}']);
      });
    }
  }

  @override
  int getForegroundWindow() {
    final result = Process.runSync('osascript',
        ['-e', 'tell application "System Events" to get the name of the first process whose frontmost is true']);
    if (result.exitCode == 0) {
      // Returning a non-zero handle as a placeholder, macOS does not have window handles like Windows
      return result.stdout.toString().trim().hashCode;
    }
    return 0;
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
