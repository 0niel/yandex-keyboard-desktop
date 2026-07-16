import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

typedef TrayMenuPublisher = Future<void> Function(
  String showWindowLabel,
  String settingsLabel,
  String exitAppLabel,
);

final class SerialTrayMenuPublisher {
  SerialTrayMenuPublisher(this._publish);

  final TrayMenuPublisher _publish;
  Future<void> _tail = Future<void>.value();

  Future<void> publish(
    String showWindowLabel,
    String settingsLabel,
    String exitAppLabel,
  ) {
    final publication = _tail.then(
      (_) => _publish(showWindowLabel, settingsLabel, exitAppLabel),
    );
    _tail = publication.then<void>((_) {}, onError: (_) {});
    return publication;
  }
}

final class SystemTrayController {
  const SystemTrayController._();

  static final SerialTrayMenuPublisher _publisher =
      SerialTrayMenuPublisher(_publish);

  static bool get isAvailable => !(Platform.isLinux &&
      Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty == true &&
      Platform.environment['GDK_BACKEND'] != 'x11');

  static Future<void> initialize(
    String showWindowLabel,
    String settingsLabel,
    String exitAppLabel,
  ) =>
      _publisher.publish(showWindowLabel, settingsLabel, exitAppLabel);

  static Future<void> _publish(
    String showWindowLabel,
    String settingsLabel,
    String exitAppLabel,
  ) async {
    if (!isAvailable) {
      return;
    }
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/brand/app_icon.ico'
          : 'assets/brand/app_icon.png',
    );
    final menu = Menu(
      items: [
        MenuItem(key: 'show_window', label: showWindowLabel),
        MenuItem(key: 'config', label: settingsLabel),
        MenuItem.separator(),
        MenuItem(key: 'exit_app', label: exitAppLabel),
      ],
    );
    await trayManager.setContextMenu(menu);
  }
}
