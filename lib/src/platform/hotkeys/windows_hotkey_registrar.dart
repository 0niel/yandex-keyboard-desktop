import 'dart:async';

import 'package:flutter/services.dart';
import 'package:yandex_keyboard_desktop/src/app/diagnostic_log.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';

abstract interface class NativeHotkeyChannel {
  Future<bool> register({
    required int id,
    required int modifiers,
    required int key,
  });

  Future<bool> unregister({required int id});

  Future<bool> unregisterAll();

  set onHotKey(void Function(int id)? handler);
}

final class MethodChannelNativeHotkeys implements NativeHotkeyChannel {
  MethodChannelNativeHotkeys({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('ykd/native_hotkeys') {
    _channel.setMethodCallHandler(_handleCall);
  }

  final MethodChannel _channel;
  void Function(int id)? _onHotKey;

  @override
  set onHotKey(void Function(int id)? handler) => _onHotKey = handler;

  Future<Object?> _handleCall(MethodCall call) async {
    diag('native channel call: ${call.method} (${call.arguments})');
    if (call.method == 'onHotKey' && call.arguments is int) {
      _onHotKey?.call(call.arguments as int);
    }
    return null;
  }

  @override
  Future<bool> register({
    required int id,
    required int modifiers,
    required int key,
  }) async {
    return await _channel.invokeMethod<bool>('register', <String, int>{
          'id': id,
          'modifiers': modifiers,
          'key': key,
        }) ==
        true;
  }

  @override
  Future<bool> unregister({required int id}) async {
    return await _channel
            .invokeMethod<bool>('unregister', <String, int>{'id': id}) ==
        true;
  }

  @override
  Future<bool> unregisterAll() async {
    return await _channel.invokeMethod<bool>('unregisterAll') == true;
  }
}

int windowsModifiersFor(KeyChord chord) {
  var modifiers = 0;
  if (chord.modifiers.contains(KeyModifier.alt)) modifiers |= 0x0001;
  if (chord.modifiers.contains(KeyModifier.control)) modifiers |= 0x0002;
  if (chord.modifiers.contains(KeyModifier.shift)) modifiers |= 0x0004;
  if (chord.modifiers.contains(KeyModifier.meta)) modifiers |= 0x0008;
  return modifiers;
}

int windowsVirtualKeyFor(String rawKey) {
  final key = rawKey.trim().toUpperCase();
  if (key.length == 1) {
    final code = key.codeUnitAt(0);
    if (code >= 65 && code <= 90) return code;
    if (code >= 48 && code <= 57) return code;
  }
  final functionMatch = RegExp(r'^F([1-9]|1[0-2])$').firstMatch(key);
  if (functionMatch != null) {
    return 0x70 + int.parse(functionMatch.group(1)!) - 1;
  }
  return switch (key) {
    'SPACE' => 0x20,
    'ENTER' => 0x0D,
    'TAB' => 0x09,
    'ESCAPE' || 'ESC' => 0x1B,
    'DELETE' => 0x2E,
    'ARROWUP' => 0x26,
    'ARROWDOWN' => 0x28,
    'ARROWLEFT' => 0x25,
    'ARROWRIGHT' => 0x27,
    _ => throw FormatException('Unsupported hotkey: $rawKey'),
  };
}

final class WindowsHotkeyRegistrar
    implements HotkeyRegistrar, HotkeyRegistrarLifecycle {
  WindowsHotkeyRegistrar({NativeHotkeyChannel? channel})
      : _channel = channel ?? MethodChannelNativeHotkeys() {
    _channel.onHotKey = _dispatch;
  }

  final NativeHotkeyChannel _channel;
  final List<_ActiveHotkey> _active = [];
  Future<void> _operationTail = Future<void>.value();
  int _nextId = 1;

  void _dispatch(int id) {
    for (final registration in _active) {
      if (registration.id == id) {
        diag('native WM_HOTKEY id=$id -> ${registration.action.name}');
        registration.onTriggered(registration.action);
        return;
      }
    }
    diag('native WM_HOTKEY id=$id -> no matching registration');
  }

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
    final previousActive = List<_ActiveHotkey>.of(_active);
    final conflicts = <ShortcutAction>[];
    Object? platformError;
    for (final registration in previousActive) {
      try {
        await _channel.unregister(id: registration.id);
      } catch (error) {
        platformError = error;
      }
      _active.remove(registration);
    }
    for (final entry in next.bindings.entries) {
      if (!entry.value.enabled) continue;
      final registration = _ActiveHotkey(
        id: _nextId++,
        action: entry.key,
        modifiers: windowsModifiersFor(entry.value),
        key: windowsVirtualKeyFor(entry.value.key),
        onTriggered: onTriggered,
      );
      var registered = false;
      try {
        registered = await _channel.register(
          id: registration.id,
          modifiers: registration.modifiers,
          key: registration.key,
        );
      } catch (error) {
        platformError = error;
      }
      diag('native register ${entry.key.name} '
          '(id=${registration.id}, mod=0x${registration.modifiers.toRadixString(16)}, '
          'vk=0x${registration.key.toRadixString(16)}) -> $registered');
      if (registered) {
        _active.add(registration);
      } else {
        conflicts.add(entry.key);
      }
    }
    if (platformError != null) {
      throw HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.platformError,
        diagnosticCode: 'keybinding_registration_failed',
        failedActions: conflicts,
        cause: platformError,
      );
    }
    if (conflicts.isNotEmpty) {
      throw HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.conflict,
        diagnosticCode: 'keybinding_registration_conflict',
        failedActions: conflicts,
      );
    }
  }

  @override
  Future<void> unregisterAll() {
    return _serialize(() async {
      final failures = <Object>[];
      for (final registration in List<_ActiveHotkey>.of(_active)) {
        try {
          await _channel.unregister(id: registration.id);
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

  @override
  Future<void> close() async {
    _channel.onHotKey = null;
    await _channel.unregisterAll();
    _active.clear();
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }
}

final class _ActiveHotkey {
  const _ActiveHotkey({
    required this.id,
    required this.action,
    required this.modifiers,
    required this.key,
    required this.onTriggered,
  });

  final int id;
  final ShortcutAction action;
  final int modifiers;
  final int key;
  final void Function(ShortcutAction action) onTriggered;
}
