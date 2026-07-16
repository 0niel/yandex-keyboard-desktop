import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/windows_hotkey_registrar.dart';

void main() {
  KeyBindingProfile profile(Map<ShortcutAction, KeyChord> bindings) =>
      KeyBindingProfile(id: 'p', name: 'P', bindings: bindings);

  group('windowsVirtualKeyFor', () {
    test('maps letters, digits, function and named keys', () {
      expect(windowsVirtualKeyFor('R'), 0x52);
      expect(windowsVirtualKeyFor('e'), 0x45);
      expect(windowsVirtualKeyFor('0'), 0x30);
      expect(windowsVirtualKeyFor('9'), 0x39);
      expect(windowsVirtualKeyFor('F1'), 0x70);
      expect(windowsVirtualKeyFor('F12'), 0x7B);
      expect(windowsVirtualKeyFor('Space'), 0x20);
      expect(windowsVirtualKeyFor('Escape'), 0x1B);
      expect(windowsVirtualKeyFor('ArrowLeft'), 0x25);
    });

    test('rejects unsupported keys', () {
      expect(() => windowsVirtualKeyFor('HyperKey'), throwsFormatException);
    });
  });

  test('modifier bitmask matches the RegisterHotKey contract', () {
    expect(
      windowsModifiersFor(KeyChord(
        key: 'K',
        modifiers: {KeyModifier.control, KeyModifier.alt},
      )),
      0x0003,
    );
    expect(
      windowsModifiersFor(KeyChord(
        key: 'K',
        modifiers: {KeyModifier.shift, KeyModifier.meta},
      )),
      0x000C,
    );
  });

  test('registers enabled bindings and dispatches triggers by id', () async {
    final channel = _FakeNativeHotkeyChannel();
    final registrar = WindowsHotkeyRegistrar(channel: channel);
    final triggered = <ShortcutAction>[];

    await registrar.replaceProfile(
      previous: profile(const {}),
      next: profile({
        ShortcutAction.rewrite: KeyChord(
          key: 'R',
          modifiers: {KeyModifier.control, KeyModifier.alt},
        ),
        ShortcutAction.fix: KeyChord(
          key: 'F',
          modifiers: {KeyModifier.control, KeyModifier.alt},
          enabled: false,
        ),
      }),
      onTriggered: triggered.add,
    );

    expect(channel.registered.values.single, (modifiers: 0x0003, key: 0x52));
    channel.fire(channel.registered.keys.single);
    channel.fire(9999);
    expect(triggered, [ShortcutAction.rewrite]);
  });

  test('replacement unregisters the previous profile first', () async {
    final channel = _FakeNativeHotkeyChannel();
    final registrar = WindowsHotkeyRegistrar(channel: channel);

    await registrar.replaceProfile(
      previous: profile(const {}),
      next: profile({
        ShortcutAction.rewrite: KeyChord(
          key: 'R',
          modifiers: {KeyModifier.control},
        ),
      }),
      onTriggered: (_) {},
    );
    final firstId = channel.registered.keys.single;

    await registrar.replaceProfile(
      previous: profile(const {}),
      next: profile({
        ShortcutAction.emojify: KeyChord(
          key: 'E',
          modifiers: {KeyModifier.control},
        ),
      }),
      onTriggered: (_) {},
    );

    expect(channel.registered.keys, isNot(contains(firstId)));
    expect(channel.registered.values.single.key, 0x45);
  });

  test('a chord held elsewhere is reported while the rest stay live', () async {
    final channel = _FakeNativeHotkeyChannel();
    final registrar = WindowsHotkeyRegistrar(channel: channel);
    final triggered = <ShortcutAction>[];

    channel.rejectKeys.add(0x45);
    await expectLater(
      registrar.replaceProfile(
        previous: profile(const {}),
        next: profile({
          ShortcutAction.emojify: KeyChord(
            key: 'E',
            modifiers: {KeyModifier.control},
          ),
          ShortcutAction.rewrite: KeyChord(
            key: 'R',
            modifiers: {KeyModifier.control},
          ),
        }),
        onTriggered: triggered.add,
      ),
      throwsA(
        isA<HotkeyRegistrationException>()
            .having(
          (error) => error.kind,
          'kind',
          HotkeyRegistrationFailureKind.conflict,
        )
            .having(
          (error) => error.failedActions,
          'failedActions',
          [ShortcutAction.emojify],
        ),
      ),
    );

    expect(channel.registered.values.single.key, 0x52);
    channel.fire(channel.registered.keys.single);
    expect(triggered, [ShortcutAction.rewrite]);
  });

  test('unregisterAll releases every active hotkey', () async {
    final channel = _FakeNativeHotkeyChannel();
    final registrar = WindowsHotkeyRegistrar(channel: channel);

    await registrar.replaceProfile(
      previous: profile(const {}),
      next: KeyBindingProfile.defaults(),
      onTriggered: (_) {},
    );
    expect(channel.registered, hasLength(4));

    await registrar.unregisterAll();
    expect(channel.registered, isEmpty);
  });

  test('close detaches the trigger handler and releases hotkeys', () async {
    final channel = _FakeNativeHotkeyChannel();
    final registrar = WindowsHotkeyRegistrar(channel: channel);

    await registrar.replaceProfile(
      previous: profile(const {}),
      next: KeyBindingProfile.defaults(),
      onTriggered: (_) {},
    );
    await registrar.close();

    expect(channel.handler, isNull);
    expect(channel.releasedAll, isTrue);
  });
}

final class _FakeNativeHotkeyChannel implements NativeHotkeyChannel {
  final Map<int, ({int modifiers, int key})> registered = {};
  final Set<int> rejectKeys = {};
  void Function(int id)? handler;
  bool releasedAll = false;

  void fire(int id) => handler?.call(id);

  @override
  Future<bool> register({
    required int id,
    required int modifiers,
    required int key,
  }) async {
    if (rejectKeys.contains(key)) return false;
    registered[id] = (modifiers: modifiers, key: key);
    return true;
  }

  @override
  Future<bool> unregister({required int id}) async {
    registered.remove(id);
    return true;
  }

  @override
  Future<bool> unregisterAll() async {
    releasedAll = true;
    registered.clear();
    return true;
  }

  @override
  set onHotKey(void Function(int id)? value) => handler = value;
}
