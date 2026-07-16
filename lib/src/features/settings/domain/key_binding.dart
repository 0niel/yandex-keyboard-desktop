import 'package:equatable/equatable.dart';

enum ShortcutAction {
  showOverlay,
  emojify,
  rewrite,
  fix,
}

enum KeyModifier {
  control,
  alt,
  shift,
  meta,
}

enum ShortcutPlatform {
  windows,
  linux,
  ios,
}

final class KeyChord extends Equatable {
  KeyChord({
    required String key,
    required Set<KeyModifier> modifiers,
    this.enabled = true,
  })  : key = key.trim(),
        modifiers = Set.unmodifiable(modifiers);

  final String key;
  final Set<KeyModifier> modifiers;
  final bool enabled;

  KeyChord copyWith({
    String? key,
    Set<KeyModifier>? modifiers,
    bool? enabled,
  }) =>
      KeyChord(
        key: key ?? this.key,
        modifiers: modifiers ?? this.modifiers,
        enabled: enabled ?? this.enabled,
      );

  String get signature {
    final modifierNames = modifiers.map((modifier) => modifier.name).toList()
      ..sort();
    return '${modifierNames.join('+')}+${key.toUpperCase()}';
  }

  String format(
    ShortcutPlatform platform, {
    String separator = '+',
    bool upcaseSingleChar = false,
  }) {
    final metaLabel = platform == ShortcutPlatform.windows ? 'Win' : 'Super';
    final parts = <String>[
      if (modifiers.contains(KeyModifier.control)) 'Ctrl',
      if (modifiers.contains(KeyModifier.alt)) 'Alt',
      if (modifiers.contains(KeyModifier.shift)) 'Shift',
      if (modifiers.contains(KeyModifier.meta)) metaLabel,
      upcaseSingleChar && key.length == 1 ? key.toUpperCase() : key,
    ];
    return parts.join(separator);
  }

  Map<String, Object> toJson() => {
        'key': key,
        'modifiers': modifiers.map((modifier) => modifier.name).toList()
          ..sort(),
        'enabled': enabled,
      };

  static KeyChord fromJson(Map<String, dynamic> json) {
    final rawModifiers = json['modifiers'];
    if (json['key'] is! String || rawModifiers is! List<dynamic>) {
      throw const FormatException('Invalid key chord.');
    }
    if (rawModifiers.any((value) => value is! String) ||
        rawModifiers
            .cast<String>()
            .any((value) => _parseModifier(value) == null)) {
      throw const FormatException('Unknown key modifier.');
    }
    return KeyChord(
      key: json['key'] as String,
      modifiers: rawModifiers
          .whereType<String>()
          .map(_parseModifier)
          .whereType<KeyModifier>()
          .toSet(),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
    );
  }

  static KeyModifier? _parseModifier(String value) {
    final normalized = value.toLowerCase().replaceAll(' ', '');
    return switch (normalized) {
      'control' ||
      'ctrl' ||
      'controlleft' ||
      'controlright' =>
        KeyModifier.control,
      'alt' || 'altleft' || 'altright' => KeyModifier.alt,
      'shift' || 'shiftleft' || 'shiftright' => KeyModifier.shift,
      'meta' || 'command' || 'cmd' || 'win' || 'windows' => KeyModifier.meta,
      _ => null,
    };
  }

  @override
  List<Object?> get props => [signature, enabled];
}

final class KeyBindingProfile extends Equatable {
  KeyBindingProfile({
    required this.id,
    required this.name,
    required Map<ShortcutAction, KeyChord> bindings,
  }) : bindings = Map.unmodifiable(bindings) {
    if (id.trim().isEmpty || id.length > 128) {
      throw const FormatException('Invalid keybinding profile id.');
    }
    if (name.trim().isEmpty || name.trim().length > 64) {
      throw const FormatException('Invalid keybinding profile name.');
    }
  }

  final String id;
  final String name;
  final Map<ShortcutAction, KeyChord> bindings;

  KeyBindingProfile copyWith({
    String? id,
    String? name,
    Map<ShortcutAction, KeyChord>? bindings,
  }) =>
      KeyBindingProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        bindings: bindings ?? this.bindings,
      );

  factory KeyBindingProfile.defaults() => KeyBindingProfile(
        id: 'default',
        name: 'Default',
        bindings: {
          ShortcutAction.showOverlay: KeyChord(
            key: 'Space',
            modifiers: {KeyModifier.control, KeyModifier.alt},
          ),
          ShortcutAction.emojify: KeyChord(
            key: 'E',
            modifiers: {KeyModifier.control, KeyModifier.alt},
          ),
          ShortcutAction.rewrite: KeyChord(
            key: 'R',
            modifiers: {KeyModifier.control, KeyModifier.alt},
          ),
          ShortcutAction.fix: KeyChord(
            key: 'F',
            modifiers: {KeyModifier.control, KeyModifier.alt},
          ),
        },
      );

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'bindings': {
          for (final entry in bindings.entries)
            entry.key.name: entry.value.toJson(),
        },
      };

  static KeyBindingProfile fromJson(Map<String, dynamic> json) {
    final rawBindings = json['bindings'];
    if (json['id'] is! String ||
        json['name'] is! String ||
        rawBindings is! Map<String, dynamic>) {
      throw const FormatException('Invalid keybinding profile.');
    }
    for (final entry in rawBindings.entries) {
      if (_parseAction(entry.key) != null &&
          entry.value is! Map<String, dynamic>) {
        throw const FormatException('Invalid keybinding value.');
      }
    }
    if (ShortcutAction.values.any(
      (action) => !rawBindings.containsKey(action.name),
    )) {
      throw const FormatException('Incomplete keybinding profile.');
    }
    return KeyBindingProfile(
      id: (json['id'] as String).trim(),
      name: (json['name'] as String).trim(),
      bindings: {
        for (final entry in rawBindings.entries)
          if (_parseAction(entry.key) case final action?)
            action: KeyChord.fromJson(entry.value as Map<String, dynamic>),
      },
    );
  }

  static ShortcutAction? _parseAction(String value) {
    for (final action in ShortcutAction.values) {
      if (action.name == value) {
        return action;
      }
    }
    return null;
  }

  @override
  List<Object?> get props => [id, name, bindings];
}

enum KeyBindingIssueKind {
  missingBinding,
  missingKey,
  missingModifier,
  unsupportedKey,
  duplicate,
  reserved,
  unsupportedPlatform,
}

final class KeyBindingIssue extends Equatable {
  const KeyBindingIssue({
    required this.kind,
    required this.action,
    required this.diagnosticCode,
  });

  final KeyBindingIssueKind kind;
  final ShortcutAction action;
  final String diagnosticCode;

  @override
  List<Object?> get props => [kind, action, diagnosticCode];
}

final class KeyBindingValidator {
  const KeyBindingValidator();

  List<KeyBindingIssue> validate(
    KeyBindingProfile profile, {
    required ShortcutPlatform platform,
  }) {
    final issues = <KeyBindingIssue>[];
    final signatureOwners = <String, List<ShortcutAction>>{};

    for (final action in ShortcutAction.values) {
      final chord = profile.bindings[action];
      if (chord == null) {
        issues.add(KeyBindingIssue(
          kind: KeyBindingIssueKind.missingBinding,
          action: action,
          diagnosticCode: 'keybinding_action_missing',
        ));
        continue;
      }
      if (!chord.enabled) {
        continue;
      }
      if (platform == ShortcutPlatform.ios) {
        issues.add(KeyBindingIssue(
          kind: KeyBindingIssueKind.unsupportedPlatform,
          action: action,
          diagnosticCode: 'keybinding_global_shortcut_unavailable_ios',
        ));
        continue;
      }
      if (chord.key.isEmpty) {
        issues.add(KeyBindingIssue(
          kind: KeyBindingIssueKind.missingKey,
          action: action,
          diagnosticCode: 'keybinding_key_required',
        ));
      }
      if (chord.key.isNotEmpty && !isSupportedKey(chord.key)) {
        issues.add(KeyBindingIssue(
          kind: KeyBindingIssueKind.unsupportedKey,
          action: action,
          diagnosticCode: 'keybinding_key_unsupported',
        ));
      }
      if (chord.modifiers.isEmpty) {
        issues.add(KeyBindingIssue(
          kind: KeyBindingIssueKind.missingModifier,
          action: action,
          diagnosticCode: 'keybinding_modifier_required',
        ));
      }
      if (_isReserved(chord, platform)) {
        issues.add(KeyBindingIssue(
          kind: KeyBindingIssueKind.reserved,
          action: action,
          diagnosticCode: 'keybinding_reserved_by_system',
        ));
      }
      signatureOwners.putIfAbsent(chord.signature, () => []).add(action);
    }

    for (final owners in signatureOwners.values.where(
      (owners) => owners.length > 1,
    )) {
      for (final action in owners) {
        issues.add(KeyBindingIssue(
          kind: KeyBindingIssueKind.duplicate,
          action: action,
          diagnosticCode: 'keybinding_duplicate',
        ));
      }
    }
    return issues;
  }

  static bool isSupportedKey(String rawKey) {
    final key = rawKey.trim().toUpperCase();
    if (RegExp(r'^[A-Z0-9]$').hasMatch(key) ||
        RegExp(r'^F([1-9]|1[0-2])$').hasMatch(key)) {
      return true;
    }
    return const {
      'SPACE',
      'ENTER',
      'TAB',
      'ESCAPE',
      'ESC',
      'DELETE',
      'ARROWUP',
      'ARROWDOWN',
      'ARROWLEFT',
      'ARROWRIGHT',
    }.contains(key);
  }

  bool _isReserved(KeyChord chord, ShortcutPlatform platform) {
    final key = chord.key.toUpperCase();
    if (platform == ShortcutPlatform.windows) {
      return key == 'F12' ||
          (key == 'DELETE' &&
              chord.modifiers.containsAll({
                KeyModifier.control,
                KeyModifier.alt,
              })) ||
          (key == 'L' && chord.modifiers.contains(KeyModifier.meta));
    }
    return platform == ShortcutPlatform.linux &&
        ((key == 'F2' && chord.modifiers.contains(KeyModifier.alt)) ||
            (key == 'L' && chord.modifiers.contains(KeyModifier.meta)));
  }
}
