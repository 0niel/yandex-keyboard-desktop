import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as flutter_acrylic;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yandex_keyboard_desktop/bloc/text_bloc.dart';
import 'package:yandex_keyboard_desktop/config_manager.dart';
import 'package:yandex_keyboard_desktop/config_window.dart';
import 'package:yandex_keyboard_desktop/hotkey_service.dart';
import 'package:yandex_keyboard_desktop/platform/platform_service.dart';
import 'package:yandex_keyboard_desktop/tray_manager.dart';
import 'package:yandex_keyboard_desktop/widgets/floating_window.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:yandex_keyboard_desktop/window_service.dart';

final GlobalKey<FloatingWindowState> floatingWindowKey = GlobalKey<FloatingWindowState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await flutter_acrylic.Window.initialize();
  if (defaultTargetPlatform == TargetPlatform.windows) {
    await flutter_acrylic.Window.hideWindowControls();
  }
  await flutter_acrylic.Window.setEffect(effect: flutter_acrylic.WindowEffect.transparent);

  await windowManager.ensureInitialized();

  final config = await ConfigManager.loadConfig();

  final platformService = getPlatformService();

  final hotkeyConfig = config['hotkey'];
  final key = hotkeyConfig['key'];
  final modifiers = List<String>.from(hotkeyConfig['modifiers']);

  WindowOptions windowOptions = const WindowOptions(
    size: Size(windowWidth, windowHeight),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    alwaysOnTop: true,
  );

  final windowService = WindowService(); // Инициализируйте WindowService

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowService.initializeWindow(); // Используйте метод WindowService для инициализации окна

    PackageInfo packageInfo = await PackageInfo.fromPlatform();

    launchAtStartup.setup(
      appName: packageInfo.appName,
      appPath: Platform.resolvedExecutable,
      // Set packageName parameter to support MSIX.
      packageName: packageInfo.packageName,
    );
    if (config['autostart'] == true) {
      launchAtStartup.enable();
    } else {
      launchAtStartup.disable();
    }
  });

  runApp(
    MultiProvider(
      providers: [
        BlocProvider(create: (_) => TextBloc()),
        Provider<PlatformService>(create: (_) => platformService),
      ],
      child: App(hotkeyKey: key, hotkeyModifiers: modifiers),
    ),
  );
}

class App extends StatefulWidget {
  const App({
    super.key,
    required this.hotkeyKey,
    required this.hotkeyModifiers,
  });

  final String hotkeyKey;
  final List<String> hotkeyModifiers;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with TrayListener {
  late final HotKeyService hotKeyService;

  @override
  void initState() {
    super.initState();

    trayManager.addListener(this);

    hotKeyService = HotKeyService();
    hotKeyService.setHotKey(
      key: widget.hotkeyKey,
      modifiers: widget.hotkeyModifiers,
      onHotKeyPressed: () {
        floatingWindowKey.currentState?.showFloatingWindow();
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _initializeTray();
  }

  Future<void> _initializeTray() async {
    final showWindowLabel = AppLocalizations.of(context)?.showWindow ?? "Show Window";
    final exitAppLabel = AppLocalizations.of(context)?.exitApp ?? "Exit App";
    final configLabel = AppLocalizations.of(context)?.config ?? "Config";
    await initTray(showWindowLabel, configLabel, exitAppLabel);
  }

  @override
  void dispose() {
    hotKeyService.dispose();
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      windowManager.show();
    } else if (menuItem.key == 'config') {
      _openConfigWindow();
    } else if (menuItem.key == 'exit_app') {
      trayManager.destroy();
      windowManager.close();
    }
  }

  void _openConfigWindow() async {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setAsFrameless();
    await windowManager.setHasShadow(true);
    await windowManager.setSize(const Size(600, 400));
    await windowManager.center();
    await windowManager.show();

    navigatorKey.currentState?.push(
      fluent.FluentPageRoute(
        builder: (context) => const ConfigWindow(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return fluent.FluentApp(
      navigatorKey: navigatorKey,
      color: Colors.white,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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
