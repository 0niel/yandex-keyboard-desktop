import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

class HotKeyService {
  HotKey? _hotKey;

  static const Map<String, PhysicalKeyboardKey> _keyMap = {
    'A': PhysicalKeyboardKey.keyA,
    'B': PhysicalKeyboardKey.keyB,
    'C': PhysicalKeyboardKey.keyC,
    'D': PhysicalKeyboardKey.keyD,
    'E': PhysicalKeyboardKey.keyE,
    'F': PhysicalKeyboardKey.keyF,
    'G': PhysicalKeyboardKey.keyG,
    'H': PhysicalKeyboardKey.keyH,
    'I': PhysicalKeyboardKey.keyI,
    'J': PhysicalKeyboardKey.keyJ,
    'K': PhysicalKeyboardKey.keyK,
    'L': PhysicalKeyboardKey.keyL,
    'M': PhysicalKeyboardKey.keyM,
    'N': PhysicalKeyboardKey.keyN,
    'O': PhysicalKeyboardKey.keyO,
    'P': PhysicalKeyboardKey.keyP,
    'Q': PhysicalKeyboardKey.keyQ,
    'R': PhysicalKeyboardKey.keyR,
    'S': PhysicalKeyboardKey.keyS,
    'T': PhysicalKeyboardKey.keyT,
    'U': PhysicalKeyboardKey.keyU,
    'V': PhysicalKeyboardKey.keyV,
    'W': PhysicalKeyboardKey.keyW,
    'X': PhysicalKeyboardKey.keyX,
    'Y': PhysicalKeyboardKey.keyY,
    'Z': PhysicalKeyboardKey.keyZ,
    '1': PhysicalKeyboardKey.digit1,
    '2': PhysicalKeyboardKey.digit2,
    '3': PhysicalKeyboardKey.digit3,
    '4': PhysicalKeyboardKey.digit4,
    '5': PhysicalKeyboardKey.digit5,
    '6': PhysicalKeyboardKey.digit6,
    '7': PhysicalKeyboardKey.digit7,
    '8': PhysicalKeyboardKey.digit8,
    '9': PhysicalKeyboardKey.digit9,
    '0': PhysicalKeyboardKey.digit0,
  };

  static const Map<String, HotKeyModifier> _modifierMap = {
    'control': HotKeyModifier.control,
    'control left': HotKeyModifier.control,
    'control right': HotKeyModifier.control,
    'shift': HotKeyModifier.shift,
    'shift left': HotKeyModifier.shift,
    'shift right': HotKeyModifier.shift,
    'alt': HotKeyModifier.alt,
    'alt left': HotKeyModifier.alt,
    'alt right': HotKeyModifier.alt,
    'meta': HotKeyModifier.meta,
    'meta left': HotKeyModifier.meta,
    'meta right': HotKeyModifier.meta,
  };

  static const Map<String, String> _modifierToStringMap = {
    'Control': 'Ctrl',
    'Shift': 'Shift',
    'Alt': 'Alt',
    'Meta': 'Cmd',
  };

  static const Map<String, IconData> _modifierIconMap = {
    'control': FontAwesomeIcons.keyboard,
    'control left': FontAwesomeIcons.keyboard,
    'control right': FontAwesomeIcons.keyboard,
    'shift': FontAwesomeIcons.arrowUp,
    'shift left': FontAwesomeIcons.arrowUp,
    'shift right': FontAwesomeIcons.arrowUp,
    'alt': FontAwesomeIcons.arrowsAlt,
    'alt left': FontAwesomeIcons.arrowsAlt,
    'alt right': FontAwesomeIcons.arrowsAlt,
    'meta': FontAwesomeIcons.apple,
    'meta left': FontAwesomeIcons.apple,
    'meta right': FontAwesomeIcons.apple,
  };

  void setHotKey({
    required String key,
    required List<String> modifiers,
    required VoidCallback onHotKeyPressed,
  }) async {
    _hotKey = HotKey(
      key: getPhysicalKey(key),
      modifiers: modifiers.map((mod) => getModifierKey(mod)).toList(),
    );
    await hotKeyManager.register(
      _hotKey!,
      keyDownHandler: (hotKey) {
        onHotKeyPressed();
      },
    );
  }

  static PhysicalKeyboardKey getPhysicalKey(String key) {
    return _keyMap[key.toUpperCase()] ?? PhysicalKeyboardKey.keyR;
  }

  static HotKeyModifier getModifierKey(String mod) {
    return _modifierMap[mod.toLowerCase()] ?? HotKeyModifier.control;
  }

  static String mapKeyToString(String key) {
    return key;
  }

  static String mapModifierToString(String modifier) {
    return _modifierToStringMap[modifier] ?? modifier;
  }

  static Widget mapModifierToIcon(String modifier) {
    final icon = _modifierIconMap[modifier.toLowerCase()];
    return icon != null ? Icon(icon, size: 16) : Text(modifier, style: const TextStyle(fontSize: 16));
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
