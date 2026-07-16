import 'package:flutter/foundation.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';

ShortcutPlatform currentShortcutPlatform([TargetPlatform? platform]) {
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.windows:
      return ShortcutPlatform.windows;
    case TargetPlatform.linux:
      return ShortcutPlatform.linux;
    default:
      return ShortcutPlatform.ios;
  }
}
