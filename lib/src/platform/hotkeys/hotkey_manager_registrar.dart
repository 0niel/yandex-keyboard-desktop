import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart' hide KeyModifier;
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_manager_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';

final class HotKeyManagerRegistrar implements HotkeyRegistrar {
  HotKeyManagerRegistrar({HotKeyPlatformGateway? platform})
      : _platform = platform ?? const HotKeyManagerPlatformGateway();

  final HotKeyPlatformGateway _platform;
  final List<_ActiveHotKey> _active = [];
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<void> replaceProfile({
    required KeyBindingProfile previous,
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  }) {
    return _serialize(() => _replace(next, onTriggered));
  }

  Future<void> _replace(
    KeyBindingProfile next,
    void Function(ShortcutAction action) onTriggered,
  ) async {
    final previousActive = List<_ActiveHotKey>.of(_active);
    final nextAttempts = <_ActiveHotKey>[];
    try {
      for (final registration in previousActive) {
        await _platform.unregister(registration.hotKey);
        _active.remove(registration);
      }
      for (final entry in next.bindings.entries) {
        if (!entry.value.enabled) {
          continue;
        }
        final registration = _ActiveHotKey(
          hotKey: _toHotKey(entry.value),
          handler: () => onTriggered(entry.key),
        );
        nextAttempts.add(registration);
        _active.add(registration);
        await _platform.register(registration.hotKey, registration.handler);
      }
    } catch (error) {
      final rollbackErrors = <Object>[];
      for (final registration in nextAttempts.reversed) {
        try {
          await _platform.unregister(registration.hotKey);
          _active.remove(registration);
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      for (final registration in previousActive) {
        if (_active.contains(registration)) {
          continue;
        }
        _active.add(registration);
        try {
          await _platform.register(
            registration.hotKey,
            registration.handler,
          );
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      throw HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.platformError,
        diagnosticCode: rollbackErrors.isEmpty
            ? 'keybinding_registration_failed'
            : 'keybinding_registration_rollback_failed',
        rollbackFailed: rollbackErrors.isNotEmpty,
        cause: error,
      );
    }
  }

  @override
  Future<void> unregisterAll() {
    return _serialize(() async {
      final failures = <Object>[];
      for (final registration in List<_ActiveHotKey>.of(_active)) {
        try {
          await _platform.unregister(registration.hotKey);
          _active.remove(registration);
        } catch (error) {
          failures.add(error);
        }
      }
      if (failures.isNotEmpty) {
        throw HotkeyRegistrationException(
          kind: HotkeyRegistrationFailureKind.platformError,
          diagnosticCode: 'keybinding_unregister_failed',
          rollbackFailed: true,
          cause: failures.first,
        );
      }
    });
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  HotKey _toHotKey(KeyChord chord) => HotKey(
        key: physicalKeyFor(chord.key),
        modifiers: chord.modifiers.map(modifierFor).toList(),
        scope: HotKeyScope.system,
      );

  static PhysicalKeyboardKey physicalKeyFor(String rawKey) {
    final key = rawKey.trim().toUpperCase();
    if (key.length == 1) {
      final code = key.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        return PhysicalKeyboardKey(0x00070004 + code - 65);
      }
      if (code >= 49 && code <= 57) {
        return PhysicalKeyboardKey(0x0007001E + code - 49);
      }
      if (key == '0') {
        return PhysicalKeyboardKey.digit0;
      }
    }
    final functionMatch = RegExp(r'^F([1-9]|1[0-2])$').firstMatch(key);
    if (functionMatch != null) {
      final number = int.parse(functionMatch.group(1)!);
      return PhysicalKeyboardKey(0x0007003A + number - 1);
    }
    return switch (key) {
      'SPACE' => PhysicalKeyboardKey.space,
      'ENTER' => PhysicalKeyboardKey.enter,
      'TAB' => PhysicalKeyboardKey.tab,
      'ESCAPE' || 'ESC' => PhysicalKeyboardKey.escape,
      'DELETE' => PhysicalKeyboardKey.delete,
      'ARROWUP' => PhysicalKeyboardKey.arrowUp,
      'ARROWDOWN' => PhysicalKeyboardKey.arrowDown,
      'ARROWLEFT' => PhysicalKeyboardKey.arrowLeft,
      'ARROWRIGHT' => PhysicalKeyboardKey.arrowRight,
      _ => throw FormatException('Unsupported hotkey: $rawKey'),
    };
  }

  static HotKeyModifier modifierFor(KeyModifier modifier) => switch (modifier) {
        KeyModifier.control => HotKeyModifier.control,
        KeyModifier.alt => HotKeyModifier.alt,
        KeyModifier.shift => HotKeyModifier.shift,
        KeyModifier.meta => HotKeyModifier.meta,
      };
}

final class _ActiveHotKey {
  const _ActiveHotKey({
    required this.hotKey,
    required this.handler,
  });

  final HotKey hotKey;
  final void Function() handler;
}
