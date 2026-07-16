import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';

String formatXdgShortcut(KeyChord chord) {
  const modifierOrder = <KeyModifier>[
    KeyModifier.control,
    KeyModifier.alt,
    KeyModifier.shift,
    KeyModifier.meta,
  ];
  const modifierNames = <KeyModifier, String>{
    KeyModifier.control: 'CTRL',
    KeyModifier.alt: 'ALT',
    KeyModifier.shift: 'SHIFT',
    KeyModifier.meta: 'LOGO',
  };
  final parts = <String>[
    for (final modifier in modifierOrder)
      if (chord.modifiers.contains(modifier)) modifierNames[modifier]!,
    _xdgKeysym(chord.key),
  ];
  return parts.join('+');
}

String _xdgKeysym(String rawKey) {
  final key = rawKey.trim();
  final normalized = key.toUpperCase();
  if (RegExp(r'^[A-Z]$').hasMatch(normalized)) {
    return normalized.toLowerCase();
  }
  if (RegExp(r'^[0-9]$').hasMatch(normalized) ||
      RegExp(r'^F([1-9]|1[0-2])$').hasMatch(normalized)) {
    return normalized;
  }
  return switch (normalized) {
    'SPACE' => 'space',
    'ENTER' => 'Return',
    'TAB' => 'Tab',
    'ESC' || 'ESCAPE' => 'Escape',
    'DELETE' => 'Delete',
    'ARROWUP' => 'Up',
    'ARROWDOWN' => 'Down',
    'ARROWLEFT' => 'Left',
    'ARROWRIGHT' => 'Right',
    _ => throw FormatException('Unsupported XDG shortcut key: $rawKey'),
  };
}
