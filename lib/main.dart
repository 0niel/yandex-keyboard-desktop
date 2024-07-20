import 'package:flutter/material.dart' hide MenuItem;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:provider/provider.dart';
import 'package:yandex_keyboard_desktop/bloc/text_bloc.dart';
import 'package:yandex_keyboard_desktop/hotkey_service.dart';
import 'package:yandex_keyboard_desktop/platform/platform_service.dart';
import 'package:yandex_keyboard_desktop/widgets/floating_window.dart';

import 'config.dart';

final GlobalKey<FloatingWindowState> floatingWindowKey = GlobalKey<FloatingWindowState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await loadConfig();

  final platformService = getPlatformService();

  final hotkeyConfig = config['hotkey'];
  final key = hotkeyConfig['key'];
  final modifiers = List<String>.from(hotkeyConfig['modifiers']);

  runApp(
    MultiProvider(
      providers: [
        BlocProvider(create: (_) => TextBloc()),
        Provider<PlatformService>(create: (_) => platformService),
      ],
      child: App(hotkeyKey: key, hotkeyModifiers: modifiers),
    ),
  );

  doWhenWindowReady(() {
    final win = appWindow;
    win.minSize = const Size(windowWidth, windowHeight);
    win.size = const Size(windowWidth, windowHeight);
    win.alignment = Alignment.topLeft;
    win.hide();

    platformService.setWindowFlags();
    platformService.initTray();

    if (config['autostart'] == true) {
      platformService.setAutostart();
    }
  });
}

class App extends StatefulWidget {
  const App({super.key, required this.hotkeyKey, required this.hotkeyModifiers});

  final String hotkeyKey;
  final List<String> hotkeyModifiers;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late final HotKeyService hotKeyService;

  @override
  void initState() {
    super.initState();

    hotKeyService = HotKeyService();
    hotKeyService.setHotKey(
      key: widget.hotkeyKey,
      modifier: widget.hotkeyModifiers,
      onHotKeyPressed: () {
        floatingWindowKey.currentState?.showFloatingWindow();
      },
    );
  }

  @override
  void dispose() {
    hotKeyService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      theme: fluent.FluentThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
        brightness: Brightness.light,
      ),
      darkTheme: fluent.FluentThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: FloatingWindow(
        key: floatingWindowKey,
      ),
    );
  }
}
