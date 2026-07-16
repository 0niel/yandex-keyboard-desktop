import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';

void main() {
  group('KeyChord.format', () {
    test('joins modifiers and key with the given separator', () {
      final chord = KeyChord(
        key: 'R',
        modifiers: {KeyModifier.control, KeyModifier.alt},
      );

      expect(
        chord.format(ShortcutPlatform.windows),
        'Ctrl+Alt+R',
      );
      expect(
        chord.format(ShortcutPlatform.linux, separator: ' + '),
        'Ctrl + Alt + R',
      );
    });

    test('labels the meta modifier per platform', () {
      final chord = KeyChord(key: 'K', modifiers: {KeyModifier.meta});

      expect(chord.format(ShortcutPlatform.windows), 'Win+K');
      expect(chord.format(ShortcutPlatform.linux), 'Super+K');
      expect(chord.format(ShortcutPlatform.ios), 'Super+K');
    });

    test('optionally upper-cases a single-character key', () {
      final chord = KeyChord(key: 'r', modifiers: {KeyModifier.control});

      expect(chord.format(ShortcutPlatform.windows), 'Ctrl+r');
      expect(
        chord.format(ShortcutPlatform.windows, upcaseSingleChar: true),
        'Ctrl+R',
      );
    });

    test('leaves multi-character keys untouched when upcasing', () {
      final chord = KeyChord(key: 'Space', modifiers: {KeyModifier.alt});

      expect(
        chord.format(ShortcutPlatform.windows, upcaseSingleChar: true),
        'Alt+Space',
      );
    });
  });

  group('KeyBindingValidator', () {
    test('reports duplicate shortcuts for every affected action', () {
      final duplicate = KeyChord(
        key: 'K',
        modifiers: {KeyModifier.control},
      );
      final defaults = KeyBindingProfile.defaults();
      final profile = defaults.copyWith(
        id: 'test',
        name: 'Test',
        bindings: {
          ...defaults.bindings,
          ShortcutAction.showOverlay: duplicate,
          ShortcutAction.fix: duplicate,
        },
      );

      final issues = const KeyBindingValidator().validate(
        profile,
        platform: ShortcutPlatform.windows,
      );

      expect(
        issues.where((issue) => issue.kind == KeyBindingIssueKind.duplicate),
        hasLength(2),
      );
    });

    test('rejects reserved Windows shortcuts', () {
      final defaults = KeyBindingProfile.defaults();
      final profile = defaults.copyWith(
        id: 'test',
        name: 'Test',
        bindings: {
          ...defaults.bindings,
          ShortcutAction.showOverlay: KeyChord(
            key: 'Delete',
            modifiers: {KeyModifier.control, KeyModifier.alt},
          ),
        },
      );

      final issues = const KeyBindingValidator().validate(
        profile,
        platform: ShortcutPlatform.windows,
      );

      expect(
        issues.single.kind,
        KeyBindingIssueKind.reserved,
      );
    });

    test('explains that iOS has no desktop-style global shortcuts', () {
      final issues = const KeyBindingValidator().validate(
        KeyBindingProfile.defaults(),
        platform: ShortcutPlatform.ios,
      );

      expect(
        issues,
        everyElement(
          isA<KeyBindingIssue>().having(
            (issue) => issue.kind,
            'kind',
            KeyBindingIssueKind.unsupportedPlatform,
          ),
        ),
      );
    });

    test('rejects keys that the platform registrar cannot represent', () {
      final defaults = KeyBindingProfile.defaults();
      final profile = defaults.copyWith(bindings: {
        ...defaults.bindings,
        ShortcutAction.showOverlay: KeyChord(
          key: 'HyperKey',
          modifiers: {KeyModifier.control},
        ),
      });

      final issues = const KeyBindingValidator().validate(
        profile,
        platform: ShortcutPlatform.windows,
      );

      expect(
        issues.single.kind,
        KeyBindingIssueKind.unsupportedKey,
      );
    });

    test('rejects blank and oversized profile names', () {
      expect(
        () => KeyBindingProfile.defaults().copyWith(name: '   '),
        throwsFormatException,
      );
      expect(
        () => KeyBindingProfile.defaults().copyWith(
          name: List.filled(65, 'x').join(),
        ),
        throwsFormatException,
      );
    });
  });

  group('AppSettingsCodec', () {
    test('rejects every removed settings schema', () {
      final codec = AppSettingsCodec();
      for (final source in <Map<String, dynamic>>[
        {
          'hotkey': {
            'key': 'A',
            'modifiers': ['control'],
          },
          'autostart': true,
        },
        {
          'schemaVersion': 2,
          'activeProfile': KeyBindingProfile.defaults().toJson(),
        },
      ]) {
        expect(
          () => codec.decode(source),
          throwsA(isA<UnsupportedSettingsVersionException>()),
        );
      }
    });

    test('round-trips schema 3 settings and runtime policies', () {
      final original = AppSettings.defaults();

      final decoded = const AppSettingsCodec().decode(original.toJson());

      expect(decoded, original);
    });

    test('rejects malformed fields in the current schema', () {
      final base = AppSettings.defaults().toJson();
      final malformed = <Map<String, dynamic>>[
        {...base, 'locale': 'unsupported'},
        {
          ...base,
          'profiles': ['not-a-profile-map']
        },
        {...base, 'theme': 'blue'},
        {...base, 'launchAtStartup': 1},
        {...base, 'activeProfileId': false},
        {...base, 'defaultAction': 'showOverlay'},
        {...base, 'clipboardPolicy': 'discard'},
        {...base, 'requestTimeoutMilliseconds': '15000'},
        {...base, 'retryAttempts': 2.0},
        {...base, 'historyEnabled': null},
        {...base, 'diagnosticsEnabled': 'false'},
      ];

      for (final source in malformed) {
        expect(
          () => const AppSettingsCodec().decode(source),
          throwsFormatException,
        );
      }
      expect(
        () => AppSettings.defaults().copyWith(
          defaultAction: ShortcutAction.showOverlay,
        ),
        throwsFormatException,
      );
    });

    test('rejects unknown modifiers and incomplete imported profiles', () {
      expect(
        () => KeyChord.fromJson({
          'key': 'K',
          'modifiers': ['hyper'],
        }),
        throwsFormatException,
      );
      expect(
        () => KeyBindingProfile.fromJson({
          'id': 'partial',
          'name': 'Partial',
          'bindings': {
            'showOverlay': KeyBindingProfile.defaults()
                .bindings[ShortcutAction.showOverlay]!
                .toJson(),
          },
        }),
        throwsFormatException,
      );
    });

    test('preserves unsupported future schemas as a typed failure', () {
      expect(
        () => const AppSettingsCodec().decode({
          'schemaVersion': 99,
        }),
        throwsA(isA<UnsupportedSettingsVersionException>()),
      );
    });

    test('describes an unsupported schema version', () {
      expect(
        const UnsupportedSettingsVersionException(99).toString(),
        'Unsupported settings schema version: 99',
      );
    });
  });
}
