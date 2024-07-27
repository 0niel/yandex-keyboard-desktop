import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:clipboard/clipboard.dart';
import 'package:flutter/painting.dart' as painting;
import 'package:flutter/rendering.dart';

import 'platform_service.dart';
import 'package:win32/win32.dart';
import 'package:screen_retriever/screen_retriever.dart';

final user32 = DynamicLibrary.open('user32.dll');
final GetCursorPos =
    user32.lookupFunction<Uint8 Function(Pointer<POINT> lpPoint), int Function(Pointer<POINT> lpPoint)>('GetCursorPos');
final GetSystemMetrics =
    user32.lookupFunction<Int32 Function(Int32 nIndex), int Function(int nIndex)>('GetSystemMetrics');
final SetWindowLongPtr = user32.lookupFunction<IntPtr Function(IntPtr hWnd, Int32 nIndex, IntPtr dwNewLong),
    int Function(int hWnd, int nIndex, int dwNewLong)>('SetWindowLongPtrW');
final GetWindowLongPtr =
    user32.lookupFunction<IntPtr Function(IntPtr hWnd, Int32 nIndex), int Function(int hWnd, int nIndex)>(
        'GetWindowLongPtrW');
final SetForegroundWindow =
    user32.lookupFunction<Int32 Function(IntPtr hWnd), int Function(int hWnd)>('SetForegroundWindow');
final GetForegroundWindow = user32.lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final keybd_event = user32.lookupFunction<Void Function(Uint8 bVk, Uint8 bScan, Uint32 dwFlags, IntPtr dwExtraInfo),
    void Function(int bVk, int bScan, int dwFlags, int dwExtraInfo)>('keybd_event');
final SetLayeredWindowAttributes = user32.lookupFunction<
    Int32 Function(IntPtr hwnd, Uint32 crKey, Uint8 bAlpha, Uint32 dwFlags),
    int Function(int hwnd, int crKey, int bAlpha, int dwFlags)>('SetLayeredWindowAttributes');
final SetWindowPos = user32.lookupFunction<
    Int32 Function(IntPtr hWnd, IntPtr hWndInsertAfter, Int32 X, Int32 Y, Int32 cx, Int32 cy, Uint32 uFlags),
    int Function(int hWnd, int hWndInsertAfter, int X, int Y, int cx, int cy, int uFlags)>('SetWindowPos');

final findWindowA = user32.lookupFunction<IntPtr Function(Pointer<Utf8> lpClassName, Pointer<Utf8> lpWindowName),
    int Function(Pointer<Utf8> lpClassName, Pointer<Utf8> lpWindowName)>('FindWindowA');

class WindowsPlatformService implements PlatformService {
  /// The handle of the original window that was focused before showing the
  /// floating window.
  int _originalWindowHandle = 0;

  @override
  void setWindowFlags() {
    const gwlExstyle = -20;
    const gwlStyle = -16;
    const wsPopup = 0x80000000;
    const wsExLayered = 0x00080000;
    const wsExToolwindow = 0x00000080;
    const wsExTopmost = 0x00000008;
    const lwaColorkey = 0x00000001;
    const swpNosize = 0x0001;
    const swpNomove = 0x0002;
    const swpNoactivate = 0x0010;
    const swpShowwindow = 0x0040;

    final hwnd = findWindowA('FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf8(), nullptr);

    // Set the window style to popup, removing any borders or shadows
    SetWindowLongPtr(hwnd, gwlStyle, wsPopup);

    // Set extended window styles to make the window layered and topmost
    final currentExStyle = GetWindowLongPtr(hwnd, gwlExstyle);
    final newExStyle = currentExStyle | wsExLayered | wsExToolwindow | wsExTopmost;
    SetWindowLongPtr(hwnd, gwlExstyle, newExStyle);
    SetLayeredWindowAttributes(hwnd, 0, 255, lwaColorkey); // Set the transparency level to fully opaque
    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, swpNosize | swpNomove | swpNoactivate);
  }

  @override
  Future<String> getSelectedText() async {
    if (_originalWindowHandle == 0) {
      _originalWindowHandle = GetForegroundWindow();
    }
    SetForegroundWindow(_originalWindowHandle);

    keybd_event(0x11, 0, 0, 0); // Ctrl down
    keybd_event(0x43, 0, 0, 0); // C down
    keybd_event(0x43, 0, 2, 0); // C up
    keybd_event(0x11, 0, 2, 0); // Ctrl up

    await Future.delayed(const Duration(milliseconds: 100));
    return await FlutterClipboard.paste();
  }

  @override
  Future<painting.Size> getScreenSize() {
    final int screenWidth = GetSystemMetrics(0); // SM_CXSCREEN = 0
    final int screenHeight = GetSystemMetrics(1); // SM_CYSCREEN = 1
    return Future.value(painting.Size(screenWidth.toDouble(), screenHeight.toDouble()));
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
        // Move current window to background (hide)
        SetForegroundWindow(_originalWindowHandle);

        keybd_event(0x11, 0, 0, 0); // Ctrl down
        keybd_event(0x56, 0, 0, 0); // V down
        keybd_event(0x56, 0, 2, 0); // V up
        keybd_event(0x11, 0, 2, 0); // Ctrl up
      });
    }
  }

  @override
  int getForegroundWindow() {
    return GetForegroundWindow();
  }

  @override
  void setOriginalForegroundWindow(int handle) {
    _originalWindowHandle = handle;
  }

  @override
  Future<int> getFlutterWindowHandle() async {
    final flutterWindow = findWindowA('FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf8(), nullptr);
    return flutterWindow;
  }
}
