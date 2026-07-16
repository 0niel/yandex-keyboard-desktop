import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/keyboard_input_gateway.dart';

final class WindowsSendInputGateway implements KeyboardInputGateway {
  const WindowsSendInputGateway();

  static const int _keyeventfExtendedKey = 0x0001;
  static const int _keyeventfKeyUp = 0x0002;

  static const Set<int> _extendedVirtualKeys = <int>{
    VIRTUAL_KEY.VK_PRIOR,
    VIRTUAL_KEY.VK_NEXT,
    VIRTUAL_KEY.VK_END,
    VIRTUAL_KEY.VK_HOME,
    VIRTUAL_KEY.VK_LEFT,
    VIRTUAL_KEY.VK_UP,
    VIRTUAL_KEY.VK_RIGHT,
    VIRTUAL_KEY.VK_DOWN,
    VIRTUAL_KEY.VK_INSERT,
    VIRTUAL_KEY.VK_DELETE,
    VIRTUAL_KEY.VK_LWIN,
    VIRTUAL_KEY.VK_RWIN,
    VIRTUAL_KEY.VK_RCONTROL,
    VIRTUAL_KEY.VK_RMENU,
  };

  @override
  int send(List<KeyboardStroke> strokes) {
    final inputs = calloc<INPUT>(strokes.length);
    try {
      for (var index = 0; index < strokes.length; index++) {
        final stroke = strokes[index];
        var flags = 0;
        if (stroke.isKeyUp) flags |= _keyeventfKeyUp;
        if (_extendedVirtualKeys.contains(stroke.virtualKey)) {
          flags |= _keyeventfExtendedKey;
        }
        inputs[index]
          ..type = INPUT_TYPE.INPUT_KEYBOARD
          ..ki.wVk = stroke.virtualKey
          ..ki.wScan = MapVirtualKey(
            stroke.virtualKey,
            MAP_VIRTUAL_KEY_TYPE.MAPVK_VK_TO_VSC,
          )
          ..ki.dwFlags = flags;
      }
      return SendInput(strokes.length, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
  }
}
