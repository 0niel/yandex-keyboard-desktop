import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:clipboard/clipboard.dart';
import 'package:flutter/material.dart' hide MenuItem;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:flutter/painting.dart' as painting;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:win32/win32.dart';
import 'package:yandex_keyboard_desktop/bloc/text_bloc.dart';
import 'package:yandex_keyboard_desktop/bloc/text_event.dart';
import 'package:yandex_keyboard_desktop/bloc/text_processing_type.dart';
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

const double windowWidth = 312;
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

  final hwnd = appWindow.handle;

  // Set the window style to popup, removing any borders or shadows
  SetWindowLongPtr(hwnd!, gwlStyle, wsPopup);

  // Set extended window styles to make the window layered and topmost
  final currentExStyle = GetWindowLongPtr(hwnd, gwlExstyle);
  final newExStyle = currentExStyle | wsExLayered | wsExToolwindow | wsExTopmost;
  SetWindowLongPtr(hwnd, gwlExstyle, newExStyle);
  SetLayeredWindowAttributes(hwnd, 0, 255, lwaColorkey); // Set the transparency level to fully opaque
  SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, swpNosize | swpNomove | swpNoactivate);
}

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

  /// The handle of the original window that was focused before showing the
  /// floating window.
  int _hWndOriginal = 0;

  Timer? _focusCheckTimer;

  @override
  void initState() {
    trayManager.addListener(this);
    super.initState();
    _setHotKey();
    _startFocusCheck();
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    hotKeyManager.unregister(_hotKey!);
    _focusCheckTimer?.cancel();
    super.dispose();
  }

  /// Registers the hotkey to show the floating window.
  void _setHotKey() async {
    _hotKey = HotKey(
      key: PhysicalKeyboardKey.keyR,
      modifiers: [HotKeyModifier.control],
    );
    await hotKeyManager.register(
      _hotKey!,
      keyDownHandler: (hotKey) {
        _showFloatingWindow();
      },
    );
  }

  /// Retrieves the selected text by simulating Ctrl+C on Windows or using xclip on Linux.
  Future<String> _getSelectedText() async {
    String selectedText = '';
    if (Platform.isWindows) {
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

  /// Gets the screen size using the system metrics.
  painting.Size _getScreenSize() {
    final int screenWidth = GetSystemMetrics(0); // SM_CXSCREEN = 0
    final int screenHeight = GetSystemMetrics(1); // SM_CYSCREEN = 1
    return painting.Size(screenWidth.toDouble(), screenHeight.toDouble());
  }

  /// Processes the clipboard text by dispatching a ProcessTextEvent to the TextBloc.
  Future<void> _processClipboardText(BuildContext context, TextProcessingType type) async {
    final text = await _getSelectedText();
    if (text.isNotEmpty) {
      BlocProvider.of<TextBloc>(context).add(ProcessTextEvent(text, type));
    }
  }

  /// Retrieves the cursor position using the screen retriever package.
  Future<Offset> _getCursorPos() async {
    final cursorOffset = await screenRetriever.getCursorScreenPoint();
    return cursorOffset;
  }

  /// Shows the floating window at the cursor position if text is selected.
  void _showFloatingWindow() async {
    _hWndOriginal = GetForegroundWindow(); // Save the handle of the original focused window
    final text = await _getSelectedText();
    if (text.isNotEmpty) {
      final cursorPos = await _getCursorPos();
      _showWindowAtCursor(cursorPos, text);
    }
  }

  /// Positions and shows the floating window at the specified cursor position.
  void _showWindowAtCursor(Offset cursorPos, String clipboardText) {
    final win = appWindow;
    int left = cursorPos.dx.toInt();
    int top = cursorPos.dy.toInt();

    final screenSize = _getScreenSize();

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

    win
      ..alignment = Alignment.topLeft
      ..position = Offset(left.toDouble(), top.toDouble());

    SetWindowPos(win.handle!, HWND_TOPMOST, left, top, windowWidth.toInt(), windowHeight.toInt(),
        SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE | SET_WINDOW_POS_FLAGS.SWP_SHOWWINDOW | SET_WINDOW_POS_FLAGS.SWP_NOSIZE);
  }

  /// Replaces the selected text with the new text by simulating Ctrl+V.
  void _replaceSelectedText(String newText) {
    if (Platform.isWindows) {
      if (_hWndOriginal != 0) {
        Future.delayed(const Duration(milliseconds: 100), () {
          SetForegroundWindow(_hWndOriginal);

          keybd_event(0x11, 0, 0, 0); // Ctrl down
          keybd_event(0x56, 0, 0, 0); // V down
          keybd_event(0x56, 0, 2, 0); // V up
          keybd_event(0x11, 0, 2, 0); // Ctrl up
        });
      }
    }
  }

  /// Starts a periodic timer to check if the focus has changed to another window.
  void _startFocusCheck() {
    _focusCheckTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      final hwnd = GetForegroundWindow();
      if (hwnd != appWindow.handle && hwnd != 0) {
        final state = BlocProvider.of<TextBloc>(context).state;
        if (state is! TextProcessing) {
          appWindow.hide();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: BlocListener<TextBloc, TextState>(
        listener: (context, state) {
          if (state is TextProcessed) {
            FlutterClipboard.copy(state.processedText).then((value) {
              Future.delayed(const Duration(milliseconds: 100), () {
                appWindow.hide();
                _replaceSelectedText(state.processedText);
              });
            });
          } else if (state is TextError) {
            appWindow.hide();
          }
        },
        child: BlocBuilder<TextBloc, TextState>(
          builder: (context, state) {
            if (state is TextProcessing) {
              return const Center(child: LoadingAnimation());
            } else if (state is TextProcessed) {
              BlocProvider.of<TextBloc>(context).add(ClearTextEvent());
              return const Center(child: LoadingAnimation());
            } else if (state is TextError) {
              return Center(child: Text(state.error));
            } else {
              return Center(
                child: OptionsWidget(
                  processClipboardText: _processClipboardText,
                ),
              );
            }
          },
        ),
      ),
    );
  }

  @override
  void onTrayIconMouseDown() {
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
