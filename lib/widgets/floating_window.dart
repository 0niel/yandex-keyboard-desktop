import 'dart:async';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:clipboard/clipboard.dart';
import 'package:flutter/material.dart' hide MenuItem;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import 'package:yandex_keyboard_desktop/bloc/text_bloc.dart';
import 'package:yandex_keyboard_desktop/bloc/text_event.dart';
import 'package:yandex_keyboard_desktop/bloc/text_processing_type.dart';
import 'package:yandex_keyboard_desktop/bloc/text_state.dart';
import 'package:yandex_keyboard_desktop/platform/platform_service.dart';
import 'package:yandex_keyboard_desktop/widgets/loading_animation.dart';
import 'package:yandex_keyboard_desktop/widgets/options_widget.dart';

const double windowWidth = 312;
const double windowHeight = 45;

class FloatingWindow extends StatefulWidget {
  const FloatingWindow({super.key});

  @override
  State<StatefulWidget> createState() => FloatingWindowState();
}

class FloatingWindowState extends State<FloatingWindow> {
  Timer? _focusCheckTimer;

  @override
  void initState() {
    super.initState();
    _startFocusCheck();
  }

  @override
  void dispose() {
    _focusCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _processClipboardText(BuildContext context, TextProcessingType type) async {
    final platformService = Provider.of<PlatformService>(context, listen: false);
    final text = await platformService.getSelectedText();
    if (text.isNotEmpty) {
      BlocProvider.of<TextBloc>(context).add(ProcessTextEvent(text, type));
    }
  }

  void showFloatingWindow() async {
    final platformService = Provider.of<PlatformService>(context, listen: false);
    platformService.setOriginalForegroundWindow(platformService.getForegroundWindow());
    final text = await platformService.getSelectedText();
    if (text.isNotEmpty) {
      final cursorPos = await platformService.getCursorPos();
      _showWindowAtCursor(cursorPos, text);
    }
  }

  void _showWindowAtCursor(Offset cursorPos, String clipboardText) {
    final platformService = Provider.of<PlatformService>(context, listen: false);
    final win = appWindow;
    int left = cursorPos.dx.toInt();
    int top = cursorPos.dy.toInt();

    final screenSize = platformService.getScreenSize();

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

    platformService.setWindowFlags();
    win.show();
  }

  void _startFocusCheck() {
    _focusCheckTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      final platformService = Provider.of<PlatformService>(context, listen: false);
      final hwnd = platformService.getForegroundWindow();
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
                Provider.of<PlatformService>(context, listen: false).replaceSelectedText(state.processedText);
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
}
