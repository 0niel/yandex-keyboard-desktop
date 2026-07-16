import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/xdg_shortcut_formatter.dart';

void main() {
  test('uses the XDG modifier order and LOGO name', () {
    expect(
      formatXdgShortcut(KeyChord(
        key: 'R',
        modifiers: {
          KeyModifier.meta,
          KeyModifier.shift,
          KeyModifier.control,
          KeyModifier.alt,
        },
      )),
      'CTRL+ALT+SHIFT+LOGO+r',
    );
  });

  test('maps every named application key to an XKB keysym', () {
    const expected = {
      'Space': 'space',
      'Enter': 'Return',
      'Tab': 'Tab',
      'Esc': 'Escape',
      'Escape': 'Escape',
      'Delete': 'Delete',
      'ArrowUp': 'Up',
      'ArrowDown': 'Down',
      'ArrowLeft': 'Left',
      'ArrowRight': 'Right',
      'F12': 'F12',
      '7': '7',
    };

    for (final entry in expected.entries) {
      expect(
        formatXdgShortcut(KeyChord(key: entry.key, modifiers: const {})),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('rejects unsupported key names instead of guessing', () {
    expect(
      () => formatXdgShortcut(
        KeyChord(key: 'HyperKey', modifiers: {KeyModifier.control}),
      ),
      throwsFormatException,
    );
  });
}
