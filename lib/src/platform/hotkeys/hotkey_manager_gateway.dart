import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

abstract interface class HotKeyPlatformGateway {
  Future<void> register(HotKey hotKey, VoidCallback handler);

  Future<void> unregister(HotKey hotKey);
}

final class HotKeyManagerPlatformGateway implements HotKeyPlatformGateway {
  const HotKeyManagerPlatformGateway({bool? isNativeWayland})
      : _isNativeWaylandOverride = isNativeWayland;

  final bool? _isNativeWaylandOverride;

  @override
  Future<void> register(HotKey hotKey, VoidCallback handler) {
    if (_isNativeWayland) {
      throw PlatformException(
        code: 'linux_wayland_global_shortcuts_portal_required',
        message: 'Wayland shortcuts require an approved '
            'GlobalShortcuts portal session.',
      );
    }
    return hotKeyManager.register(
      hotKey,
      keyDownHandler: (_) => handler(),
    );
  }

  @override
  Future<void> unregister(HotKey hotKey) => _isNativeWayland
      ? Future<void>.value()
      : hotKeyManager.unregister(hotKey);

  bool get _isNativeWayland =>
      _isNativeWaylandOverride ??
      (Platform.isLinux &&
          Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty == true &&
          Platform.environment['GDK_BACKEND'] != 'x11');
}
