import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:tray_manager/tray_manager.dart';

class TrayManager with TrayListener {
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
