import 'package:tray_manager/tray_manager.dart';

Future<void> initTray(String showWindowLabel, String configLabel, String exitAppLabel) async {
  await trayManager.setIcon('assets/app_icon.ico');
  Menu menu = Menu(
    items: [
      MenuItem(
        key: 'show_window',
        label: showWindowLabel,
      ),
      MenuItem(
        key: 'config',
        label: configLabel,
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'exit_app',
        label: exitAppLabel,
      ),
    ],
  );
  await trayManager.setContextMenu(menu);
}
