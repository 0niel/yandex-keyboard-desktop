import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

class HotKeyService {
  HotKey? _hotKey;

  void setHotKey({required String key, required List<String> modifier, required VoidCallback onHotKeyPressed}) async {
    _hotKey = HotKey(
      key: getPhysicalKey(key),
      modifiers: [for (var mod in modifier) getModifierKey(mod)],
    );
    await hotKeyManager.register(
      _hotKey!,
      keyDownHandler: (hotKey) {
        onHotKeyPressed();
      },
    );
  }

  HotKeyModifier getModifierKey(String mod) {
    switch (mod) {
      case 'Control':
        return HotKeyModifier.control;
      case 'Shift':
        return HotKeyModifier.shift;
      case 'Alt':
        return HotKeyModifier.alt;
      case 'Meta':
        return HotKeyModifier.meta;
      default:
        return HotKeyModifier.control;
    }
  }

  PhysicalKeyboardKey getPhysicalKey(String key) {
    switch (key.toUpperCase()) {
      case 'A':
        return PhysicalKeyboardKey.keyA;
      case 'B':
        return PhysicalKeyboardKey.keyB;
      case 'C':
        return PhysicalKeyboardKey.keyC;
      case 'D':
        return PhysicalKeyboardKey.keyD;
      case 'E':
        return PhysicalKeyboardKey.keyE;
      case 'F':
        return PhysicalKeyboardKey.keyF;
      case 'G':
        return PhysicalKeyboardKey.keyG;
      case 'H':
        return PhysicalKeyboardKey.keyH;
      case 'I':
        return PhysicalKeyboardKey.keyI;
      case 'J':
        return PhysicalKeyboardKey.keyJ;
      case 'K':
        return PhysicalKeyboardKey.keyK;
      case 'L':
        return PhysicalKeyboardKey.keyL;
      case 'M':
        return PhysicalKeyboardKey.keyM;
      case 'N':
        return PhysicalKeyboardKey.keyN;
      case 'O':
        return PhysicalKeyboardKey.keyO;
      case 'P':
        return PhysicalKeyboardKey.keyP;
      case 'Q':
        return PhysicalKeyboardKey.keyQ;
      case 'R':
        return PhysicalKeyboardKey.keyR;
      case 'S':
        return PhysicalKeyboardKey.keyS;
      case 'T':
        return PhysicalKeyboardKey.keyT;
      case 'U':
        return PhysicalKeyboardKey.keyU;
      case 'V':
        return PhysicalKeyboardKey.keyV;
      case 'W':
        return PhysicalKeyboardKey.keyW;
      case 'X':
        return PhysicalKeyboardKey.keyX;
      case 'Y':
        return PhysicalKeyboardKey.keyY;
      case 'Z':
        return PhysicalKeyboardKey.keyZ;
      case '1':
        return PhysicalKeyboardKey.digit1;
      case '2':
        return PhysicalKeyboardKey.digit2;
      case '3':
        return PhysicalKeyboardKey.digit3;
      case '4':
        return PhysicalKeyboardKey.digit4;
      case '5':
        return PhysicalKeyboardKey.digit5;
      case '6':
        return PhysicalKeyboardKey.digit6;
      case '7':
        return PhysicalKeyboardKey.digit7;
      case '8':
        return PhysicalKeyboardKey.digit8;
      case '9':
        return PhysicalKeyboardKey.digit9;
      case '0':
        return PhysicalKeyboardKey.digit0;
      default:
        return PhysicalKeyboardKey.keyR;
    }
  }

  void unregisterHotKey() async {
    if (_hotKey != null) {
      await hotKeyManager.unregister(_hotKey!);
    }
  }

  void dispose() {
    unregisterHotKey();
  }
}
