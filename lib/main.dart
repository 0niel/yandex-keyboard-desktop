// © 2024 Oniel. Thanks to Yandex for their awesome API. 😊✨🚀

// ignore_for_file: constant_identifier_names
import 'dart:io';
import 'package:clipboard/clipboard.dart';
import 'package:flutter/material.dart' hide MenuItem;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:flutter/painting.dart' as painting;
import 'dart:ffi';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:win32/win32.dart';
import 'package:yandex_keyboard_desktop/bloc/text_bloc.dart';
import 'package:yandex_keyboard_desktop/bloc/text_event.dart';
import 'package:yandex_keyboard_desktop/bloc/text_state.dart';
import 'package:logger/logger.dart';
import 'package:yandex_keyboard_desktop/loading_animation.dart';
import 'options_widget.dart';

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

final class POINT extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

var logger = Logger();

const double windowWidth = 300;
const double windowHeight = 45;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await hotKeyManager.unregisterAll();

  runApp(
    BlocProvider(
      create: (_) => TextBloc(),
      child: const MyApp(),
    ),
  );
  doWhenWindowReady(() {
    final win = appWindow;
    win.minSize = const painting.Size(windowWidth, windowHeight);
    win.size = const painting.Size(windowWidth, windowHeight);
    win.alignment = Alignment.topLeft;
    win.hide();

    // Set window flags for always on top and no taskbar entry
    setWindowFlags();

    // Initialize system tray
    initTray();
  });
}

void setWindowFlags() {
  const GWL_EXSTYLE = -20;
  const GWL_STYLE = -16;
  const WS_POPUP = 0x80000000;
  const WS_EX_LAYERED = 0x00080000;
  const WS_EX_TOOLWINDOW = 0x00000080;
  const WS_EX_TOPMOST = 0x00000008;
  const LWA_COLORKEY = 0x00000001;
  const SWP_NOSIZE = 0x0001;
  const SWP_NOMOVE = 0x0002;
  const SWP_NOACTIVATE = 0x0010;
  const SWP_SHOWWINDOW = 0x0040;

  final hwnd = appWindow.handle;
  logger.d("Window handle: $hwnd");

  // Set the window style to popup, removing any borders or shadows
  SetWindowLongPtr(hwnd!, GWL_STYLE, WS_POPUP);

  // Set extended window styles to make the window layered and topmost
  final currentExStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  final newExStyle = currentExStyle | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, newExStyle);
  SetLayeredWindowAttributes(hwnd, 0, 255, LWA_COLORKEY); // Set the transparency level to fully opaque
  SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
}

void initTray() async {
  await trayManager.setIcon(
    Platform.isWindows ? 'images/tray_icon.ico' : 'images/tray_icon.png',
  );
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      title: 'Fluent UI Example',
      theme: fluent.FluentThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
        brightness: Brightness.light,
      ),
      darkTheme: fluent.FluentThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<StatefulWidget> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TrayListener {
  HotKey? _hotKey;
  final FocusNode _focusNode = FocusNode();

  /// The handle of the original window that was focused before showing the
  /// floating window.
  int _hWndOriginal = 0;

  @override
  void initState() {
    trayManager.addListener(this);
    super.initState();
    _setHotKey();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    hotKeyManager.unregister(_hotKey!);
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _setHotKey() async {
    _hotKey = HotKey(
      key: PhysicalKeyboardKey.keyR,
      modifiers: [HotKeyModifier.control],
    );
    await hotKeyManager.register(
      _hotKey!,
      keyDownHandler: (hotKey) {
        logger.i("Hotkey pressed");
        _showFloatingWindow();
      },
    );
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) {
      appWindow.hide();
    }
  }

  Future<String> _getSelectedText() async {
    String selectedText = '';
    if (Platform.isWindows) {
      // Simulate Ctrl+C to copy the selected text to clipboard
      final hForeWnd = GetForegroundWindow();
      SetForegroundWindow(hForeWnd);

      keybd_event(0x11, 0, 0, 0); // Ctrl down
      keybd_event(0x43, 0, 0, 0); // C down
      keybd_event(0x43, 0, 2, 0); // C up
      keybd_event(0x11, 0, 2, 0); // Ctrl up

      await Future.delayed(const Duration(milliseconds: 100));
      selectedText = await FlutterClipboard.paste();
    } else if (Platform.isLinux) {
      final result = await Process.run('xclip', ['-o', '-selection', 'primary']);
      if (result.exitCode == 0) {
        selectedText = result.stdout.toString().trim();
      }
    }
    return selectedText;
  }

  painting.Size _getScreenSize() {
    final int screenWidth = GetSystemMetrics(0); // SM_CXSCREEN = 0
    final int screenHeight = GetSystemMetrics(1); // SM_CYSCREEN = 1
    return painting.Size(screenWidth.toDouble(), screenHeight.toDouble());
  }

  Future<void> _processClipboardText(BuildContext context, String type) async {
    final text = await _getSelectedText();
    logger.d("Processing selected text: $text");
    if (text.isNotEmpty) {
      BlocProvider.of<TextBloc>(context).add(ProcessTextEvent(text, type));
    }
  }

  Future<Offset> _getCursorPos() async {
    final cursorOffset = await screenRetriever.getCursorScreenPoint();
    logger.d("Cursor position retrieved: $cursorOffset");
    return cursorOffset;
  }

  void _showFloatingWindow() async {
    logger.i("Showing floating window");
    _hWndOriginal = GetForegroundWindow(); // Save the handle of the original focused window
    logger.d("Original window handle: $_hWndOriginal");
    final text = await _getSelectedText();
    if (text.isNotEmpty) {
      final cursorPos = await _getCursorPos();
      logger.d("Cursor position: (${cursorPos.dx}, ${cursorPos.dy})");
      _showWindowAtCursor(cursorPos, text);
    } else {
      logger.e("No text selected");
    }
  }

  void _showWindowAtCursor(Offset cursorPos, String clipboardText) {
    final win = appWindow;
    int left = cursorPos.dx.toInt();
    int top = cursorPos.dy.toInt();

    final screenSize = _getScreenSize();

    logger.d("Screen size: (${screenSize.width}, ${screenSize.height})");
    logger.d("Initial window position: (left: $left, top: $top)");

    if (left + windowWidth > screenSize.width) {
      left = (screenSize.width - windowWidth).toInt();
    }
    if (top + windowHeight > screenSize.height) {
      top = (screenSize.height - windowHeight).toInt();
    }

    if (left < 0) {
      left = 0;
    }
    if (top < 0) {
      top = 0;
    }

    logger.d("Adjusted window position: (left: $left, top: $top)");

    win
      ..alignment = Alignment.topLeft
      ..position = Offset(left.toDouble(), top.toDouble());

    SetWindowPos(win.handle!, HWND_TOPMOST, left, top, windowWidth.toInt(), windowHeight.toInt(),
        SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE | SET_WINDOW_POS_FLAGS.SWP_SHOWWINDOW | SET_WINDOW_POS_FLAGS.SWP_NOSIZE);
  }

  void _replaceSelectedText(String newText) {
    if (Platform.isWindows) {
      // Simulate Ctrl+V to paste the text from clipboard
      if (_hWndOriginal != 0) {
        Future.delayed(const Duration(milliseconds: 100), () {
          SetForegroundWindow(_hWndOriginal);

          keybd_event(0x11, 0, 0, 0); // Ctrl down
          keybd_event(0x56, 0, 0, 0); // V down
          keybd_event(0x56, 0, 2, 0); // V up
          keybd_event(0x11, 0, 2, 0); // Ctrl up
        });
      } else {
        logger.e("Original window handle is 0, cannot paste.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        focusNode: _focusNode,
        child: BlocListener<TextBloc, TextState>(
          listener: (context, state) {
            if (state is TextProcessed) {
              logger.i("Text processed successfully");
              FlutterClipboard.copy(state.processedText).then((value) {
                Future.delayed(const Duration(milliseconds: 100), () {
                  appWindow.hide();
                  _replaceSelectedText(state.processedText);
                });
              });
            } else if (state is TextError) {
              logger.e("Text processing error: ${state.error}");
              appWindow.hide();
            }
          },
          child: BlocBuilder<TextBloc, TextState>(
            builder: (context, state) {
              if (state is TextProcessing) {
                return const Center(child: LoadingAnimation());
              } else if (state is TextProcessed) {
                // add clear
                BlocProvider.of<TextBloc>(context).add(const ClearTextEvent());
                return const Center(child: LoadingAnimation());
              } else if (state is TextError) {
                return Center(child: Text(state.error));
              } else {
                return Center(
                  child: OptionsWidget(
                    logger: logger,
                    processClipboardText: _processClipboardText,
                  ),
                );
              }
            },
          ),
        ),
      ),
    );
  }

  @override
  void onTrayIconMouseDown() {
    logger.i('Tray icon mouse down');
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      appWindow.show();
    } else if (menuItem.key == 'exit_app') {
      trayManager.destroy();
      appWindow.close();
    }
  }
}
