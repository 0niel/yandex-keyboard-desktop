import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:clipboard/clipboard.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'platform_service.dart';

class MacOSPlatformService implements PlatformService {
  int _originalWindowHandle = 0;

  @override
  void setWindowFlags() {}

  @override
  void setAutostart() async {
    if (Platform.isMacOS || !kDebugMode) {
      final appPath = Platform.resolvedExecutable;
      final autoStartPath = '${Platform.environment['HOME']}/Library/LaunchAgents/com.myapp.autostart.plist';
      final plistContent = '''
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>com.myapp.autostart</string>
        <key>ProgramArguments</key>
        <array>
          <string>$appPath</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
      </dict>
      </plist>
      ''';

      final file = File(autoStartPath);
      await file.writeAsString(plistContent);

      await Process.run('launchctl', ['load', autoStartPath]);
    }
  }

  @override
  void initTray() async {
    await trayManager.setIcon('assets/app_icon.ico');
    Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show_window',
          label: 'Show Window',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit_app',
          label: 'Exit App',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

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
  Size getScreenSize() {
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
}
