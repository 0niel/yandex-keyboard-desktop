import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart' hide KeyModifier;
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_manager_gateway.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_manager_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';

void main() {
  test('fails closed before calling Keybinder on native Wayland', () async {
    const platform = HotKeyManagerPlatformGateway(isNativeWayland: true);
    final hotKey = HotKey(
      key: PhysicalKeyboardKey.keyR,
      modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );

    expect(
      () => platform.register(hotKey, () {}),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'linux_wayland_global_shortcuts_portal_required',
        ),
      ),
    );
    await platform.unregister(hotKey);
  });

  test('registers every enabled action with its own callback', () async {
    final platform = _FakeHotKeyPlatform();
    final registrar = HotKeyManagerRegistrar(platform: platform);
    final triggered = <ShortcutAction>[];
    final profile = KeyBindingProfile.defaults();

    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: triggered.add,
    );

    expect(platform.active, hasLength(4));
    for (final handler in platform.active.values) {
      handler();
    }
    expect(triggered.toSet(), ShortcutAction.values.toSet());
  });

  test('does not register disabled bindings', () async {
    final platform = _FakeHotKeyPlatform();
    final registrar = HotKeyManagerRegistrar(platform: platform);
    final defaults = KeyBindingProfile.defaults();
    final next = defaults.copyWith(bindings: {
      ...defaults.bindings,
      ShortcutAction.emojify:
          defaults.bindings[ShortcutAction.emojify]!.copyWith(enabled: false),
    });

    await registrar.replaceProfile(
      previous: defaults,
      next: next,
      onTriggered: (_) {},
    );

    expect(platform.active, hasLength(3));
  });

  test('rolls the complete previous profile back after registration failure',
      () async {
    final platform = _FakeHotKeyPlatform();
    final registrar = HotKeyManagerRegistrar(platform: platform);
    final defaults = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: defaults,
      next: defaults,
      onTriggered: (_) {},
    );
    final originalSignatures = platform.active.keys.toSet();
    platform.failRegistrationCall = platform.registrationCalls + 2;
    final changed = defaults.copyWith(bindings: {
      ...defaults.bindings,
      ShortcutAction.showOverlay: KeyChord(
        key: 'F8',
        modifiers: {KeyModifier.control, KeyModifier.shift},
      ),
    });

    await expectLater(
      registrar.replaceProfile(
        previous: defaults,
        next: changed,
        onTriggered: (_) {},
      ),
      throwsA(
        isA<HotkeyRegistrationException>().having(
          (error) => error.rollbackFailed,
          'rollbackFailed',
          isFalse,
        ),
      ),
    );

    expect(platform.active.keys.toSet(), originalSignatures);
  });

  test('rejects unknown physical keys instead of remapping to R', () {
    expect(
      () => HotKeyManagerRegistrar.physicalKeyFor('HyperKey'),
      throwsFormatException,
    );
  });

  test('keeps a failed rollback unregister tracked for later cleanup',
      () async {
    final platform = _FakeHotKeyPlatform();
    final registrar = HotKeyManagerRegistrar(platform: platform);
    final defaults = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: defaults,
      next: defaults,
      onTriggered: (_) {},
    );
    final changed = defaults.copyWith(bindings: {
      ...defaults.bindings,
      ShortcutAction.showOverlay: KeyChord(
        key: 'F8',
        modifiers: {KeyModifier.control, KeyModifier.shift},
      ),
    });
    platform.failRegistrationCall = platform.registrationCalls + 2;
    platform.failUnregisterKeyOnce = PhysicalKeyboardKey.f8;

    await expectLater(
      registrar.replaceProfile(
        previous: defaults,
        next: changed,
        onTriggered: (_) {},
      ),
      throwsA(
        isA<HotkeyRegistrationException>().having(
          (error) => error.rollbackFailed,
          'rollbackFailed',
          isTrue,
        ),
      ),
    );

    expect(platform.active, hasLength(5));
    await registrar.unregisterAll();
    expect(platform.active, isEmpty);
  });

  test('cleans up a registration that throws after the OS accepted it',
      () async {
    final platform = _FakeHotKeyPlatform();
    final registrar = HotKeyManagerRegistrar(platform: platform);
    final defaults = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: defaults,
      next: defaults,
      onTriggered: (_) {},
    );
    final original = platform.active.keys.toSet();
    platform.failAfterRegistrationCall = platform.registrationCalls + 1;

    await expectLater(
      registrar.replaceProfile(
        previous: defaults,
        next: defaults,
        onTriggered: (_) {},
      ),
      throwsA(isA<HotkeyRegistrationException>()),
    );

    expect(platform.active.keys.toSet(), original);
  });
}

final class _FakeHotKeyPlatform implements HotKeyPlatformGateway {
  final Map<String, VoidCallback> active = {};
  int registrationCalls = 0;
  int? failRegistrationCall;
  int? failAfterRegistrationCall;
  PhysicalKeyboardKey? failUnregisterKeyOnce;

  @override
  Future<void> register(HotKey hotKey, VoidCallback handler) async {
    registrationCalls++;
    if (registrationCalls == failRegistrationCall) {
      throw StateError('registration conflict');
    }
    active[_signature(hotKey)] = handler;
    if (registrationCalls == failAfterRegistrationCall) {
      throw StateError('registration reported late failure');
    }
  }

  @override
  Future<void> unregister(HotKey hotKey) async {
    if (hotKey.key == failUnregisterKeyOnce) {
      failUnregisterKeyOnce = null;
      throw StateError('unregister failed');
    }
    active.remove(_signature(hotKey));
  }

  String _signature(HotKey hotKey) {
    final modifiers = hotKey.modifiers?.map((value) => value.name).toList()
      ?..sort();
    return '${modifiers?.join('+')}:${hotKey.key}';
  }
}
