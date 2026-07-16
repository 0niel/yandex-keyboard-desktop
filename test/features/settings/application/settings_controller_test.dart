import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_state.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/settings/text_assistant_settings_applier.dart';

void main() {
  test('loads settings and activates every shortcut profile', () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final registrar = _FakeHotkeyRegistrar();
    final controller = _controller(repository, registrar);

    await controller.initialize();

    expect(controller.state.stage, SettingsStage.ready);
    expect(controller.state.authoritative, AppSettings.defaults());
    expect(registrar.profiles, hasLength(1));
    await controller.close();
  });

  test('blocks save while active profile contains duplicate chords', () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final controller = _controller(repository, _FakeHotkeyRegistrar());
    await controller.initialize();
    final duplicate =
        controller.state.draft!.activeProfile.bindings[ShortcutAction.rewrite]!;

    controller.updateBinding(ShortcutAction.fix, duplicate);

    expect(controller.state.hasBlockingIssues, isTrue);
    expect(await controller.save(), isFalse);
    expect(repository.saveCalls, 0);
    await controller.close();
  });

  test('supports profile CRUD and versioned import export', () async {
    var nextId = 0;
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final controller = _controller(
      repository,
      _FakeHotkeyRegistrar(),
      createProfileId: () => 'profile-${++nextId}',
    );
    await controller.initialize();

    controller.createProfile('Work');
    expect(controller.state.draft!.profiles, hasLength(2));
    controller.renameActiveProfile('Workstation');
    final exported = controller.exportActiveProfile();
    controller.importProfile(exported);
    expect(controller.state.draft!.profiles, hasLength(3));
    expect(controller.state.draft!.activeProfile.name, 'Workstation');
    controller.deleteActiveProfile();
    expect(controller.state.draft!.profiles, hasLength(2));
    controller.resetActiveProfile();
    expect(
      controller.state.draft!.activeProfile.bindings,
      KeyBindingProfile.defaults().bindings,
    );
    await controller.close();
  });

  test('persists and applies a validated draft atomically', () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final registrar = _FakeHotkeyRegistrar();
    final runtime = _FakeRuntimeApplier();
    final controller = _controller(repository, registrar, runtime: runtime);
    await controller.initialize();
    controller.updateGeneral(
      locale: 'ru',
      theme: AppThemePreference.dark,
      launchAtStartup: true,
    );

    expect(await controller.save(), isTrue);

    expect(repository.value.locale, 'ru');
    expect(controller.state.isDirty, isFalse);
    expect(runtime.applied.last.next.theme, AppThemePreference.dark);
    expect(registrar.profiles, hasLength(2));
    await controller.close();
  });

  test('retries authoritative hotkeys without activating an unsaved draft',
      () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final registrar = _FakeHotkeyRegistrar();
    final controller = _controller(repository, registrar);
    await controller.initialize();
    controller.updateGeneral(locale: 'ru');
    registrar.failOnCalls.add(2);

    expect(await controller.retryHotkeyRegistration(), isFalse);
    expect(controller.state.draft!.locale, 'ru');
    expect(controller.state.authoritative!.locale, 'system');
    expect(controller.state.errorCode, 'keybinding_registration_failed');
    registrar.failOnCalls.clear();

    expect(await controller.retryHotkeyRegistration(), isTrue);
    expect(controller.state.draft!.locale, 'ru');
    expect(controller.state.isDirty, isTrue);
    expect(controller.state.errorCode, isNull);
    expect(registrar.profiles.last, AppSettings.defaults().activeProfile);
    await controller.close();
  });

  test('cleans up and remains editable after hotkey rollback failure',
      () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final registrar = _FakeHotkeyRegistrar()
      ..failOnCalls.add(2)
      ..rollbackFailure = true;
    final controller = _controller(repository, registrar);
    await controller.initialize();
    controller.updateGeneral(locale: 'ru');

    expect(await controller.save(), isFalse);

    expect(controller.state.stage, SettingsStage.ready);
    expect(
      controller.state.errorCode,
      'keybinding_registration_rollback_failed',
    );
    expect(controller.canStartTextOperation, isTrue);
    expect(registrar.unregisterCalls, 1);
    controller.updateGeneral(locale: 'en');
    expect(controller.state.draft!.locale, 'en');
    await controller.close();
  });

  test('fails closed when rollback cleanup also fails', () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final registrar = _FakeHotkeyRegistrar()
      ..failOnCalls.add(2)
      ..rollbackFailure = true
      ..failUnregister = true;
    final controller = _controller(repository, registrar);
    await controller.initialize();
    controller.updateGeneral(locale: 'ru');

    expect(await controller.save(), isFalse);

    expect(controller.state.stage, SettingsStage.failure);
    expect(controller.canStartTextOperation, isFalse);
    expect(registrar.unregisterCalls, 1);
    await controller.close();
  });

  test('reconciles runtime to authoritative disk after save failure', () async {
    final original = AppSettings.defaults();
    final repository = _FakeSettingsRepository(original)..failSave = true;
    final registrar = _FakeHotkeyRegistrar();
    final runtime = _FakeRuntimeApplier();
    final controller = _controller(repository, registrar, runtime: runtime);
    await controller.initialize();
    controller.updateGeneral(locale: 'ru');

    expect(await controller.save(), isFalse);

    expect(controller.state.errorCode, 'settings_save_failed');
    expect(controller.state.authoritative, original);
    expect(controller.state.draft, original);
    expect(registrar.profiles.last, original.activeProfile);
    expect(runtime.applied.last.next, original);
    await controller.close();
  });

  test('restores runtime even when hotkey reconciliation fails', () async {
    final original = AppSettings.defaults();
    final repository = _FakeSettingsRepository(original)..failSave = true;
    final registrar = _FakeHotkeyRegistrar()..failOnCalls.add(3);
    final runtime = _FakeRuntimeApplier();
    final controller = _controller(repository, registrar, runtime: runtime);
    await controller.initialize();
    controller.updateGeneral(
      clipboardPolicy: ClipboardPolicy.keepReplacement,
    );

    expect(await controller.save(), isFalse);

    expect(controller.state.errorCode, 'settings_reconciliation_failed');
    expect(controller.state.authoritative, original);
    expect(controller.state.draft, original);
    expect(runtime.applied.last.next, original);
    await controller.close();
  });

  test('composite runtime apply invokes every seam before reporting failure',
      () async {
    final settings = AppSettings.defaults();
    final first = _FakeRuntimeApplier()..fail = true;
    final privacyCritical = _FakeRuntimeApplier();
    final composite = CompositeSettingsRuntimeApplier([
      first,
      privacyCritical,
    ]);

    await expectLater(
      composite.apply(previous: settings, next: settings),
      throwsStateError,
    );

    expect(first.applied, hasLength(1));
    expect(privacyCritical.applied, hasLength(1));
  });

  test('rejects oversized imports without mutating the draft', () async {
    final controller = _controller(
      _FakeSettingsRepository(AppSettings.defaults()),
      _FakeHotkeyRegistrar(),
    );
    await controller.initialize();
    final before = controller.state.draft;

    expect(
      () => controller.importProfile(
        List.filled(SettingsController.maxImportBytes + 1, 'x').join(),
      ),
      throwsFormatException,
    );
    expect(controller.state.draft, before);
    await controller.close();
  });

  test(
      'keeps settings recoverable and unregisters hotkeys on startup apply failure',
      () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final registrar = _FakeHotkeyRegistrar();
    final runtime = _FakeRuntimeApplier()..fail = true;
    final controller = _controller(repository, registrar, runtime: runtime);

    await controller.initialize();

    expect(controller.state.stage, SettingsStage.ready);
    expect(controller.state.draft, AppSettings.defaults());
    expect(controller.state.errorCode, 'settings_runtime_apply_failed');
    expect(registrar.unregisterCalls, 1);
    await controller.close();
  });

  test('keeps a conflicting startup profile editable with survivors live',
      () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final registrar = _FakeHotkeyRegistrar()..failRegistration = true;
    final controller = _controller(repository, registrar);

    await controller.initialize();

    expect(controller.state.stage, SettingsStage.ready);
    expect(controller.state.draft, AppSettings.defaults());
    expect(controller.state.errorCode, 'keybinding_registration_failed');
    expect(registrar.unregisterCalls, 0);
    controller.updateBinding(
      ShortcutAction.showOverlay,
      KeyChord(key: 'K', modifiers: {KeyModifier.control, KeyModifier.alt}),
    );
    expect(
      controller
          .state.draft!.activeProfile.bindings[ShortcutAction.showOverlay]!.key,
      'K',
    );
    await controller.close();
  });

  test('hydrates runtime policy before registering global callbacks', () async {
    final events = <String>[];
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final registrar = _FakeHotkeyRegistrar(events: events);
    final runtime = _FakeRuntimeApplier(events: events);
    final controller = _controller(repository, registrar, runtime: runtime);

    await controller.initialize();

    expect(events, ['runtime', 'hotkeys']);
    await controller.close();
  });

  test('rejects overlapping saves and edits while a transaction is active',
      () async {
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final runtime = _FakeRuntimeApplier();
    final controller = _controller(
      repository,
      _FakeHotkeyRegistrar(),
      runtime: runtime,
    );
    await controller.initialize();
    controller.updateGeneral(locale: 'ru');
    runtime.gate = Completer<void>();
    runtime.started = Completer<void>();

    final firstSave = controller.save();
    await runtime.started!.future;
    expect(controller.canStartTextOperation, isFalse);
    controller.updateGeneral(locale: 'en');

    expect(await controller.save(), isFalse);
    expect(controller.state.draft!.locale, 'ru');
    runtime.gate!.complete();
    expect(await firstSave, isTrue);
    expect(controller.canStartTextOperation, isTrue);
    expect(repository.value.locale, 'ru');
    await controller.close();
  });

  test('privacy withdrawal is immediate and discard explicitly restores it',
      () async {
    final enabled = AppSettings.defaults().copyWith(
      historyEnabled: true,
      diagnosticsEnabled: true,
    );
    final provider = MutableTextAssistantRuntimePolicyProvider();
    final applier = TextAssistantSettingsApplier(policyProvider: provider);
    final controller = _controller(
      _FakeSettingsRepository(enabled),
      _FakeHotkeyRegistrar(),
      runtime: applier,
      draftPrivacy: applier,
    );
    await controller.initialize();
    final initialGeneration = provider.current.privacyConsentGeneration;

    controller.updateGeneral(historyEnabled: false);

    expect(provider.current.historyEnabled, isFalse);
    expect(provider.current.diagnosticsEnabled, isTrue);
    expect(
      provider.current.privacyConsentGeneration,
      initialGeneration + 1,
    );
    expect(controller.state.authoritative!.historyEnabled, isTrue);

    controller.discardChanges();

    expect(provider.current.historyEnabled, isTrue);
    expect(controller.state.draft, enabled);
    expect(
      provider.current.privacyConsentGeneration,
      initialGeneration + 2,
    );
    await controller.close();
  });

  test('privacy enablement waits for save and withdrawal survives save',
      () async {
    final provider = MutableTextAssistantRuntimePolicyProvider();
    final applier = TextAssistantSettingsApplier(policyProvider: provider);
    final repository = _FakeSettingsRepository(AppSettings.defaults());
    final controller = _controller(
      repository,
      _FakeHotkeyRegistrar(),
      runtime: applier,
      draftPrivacy: applier,
    );
    await controller.initialize();

    controller.updateGeneral(historyEnabled: true);
    expect(provider.current.historyEnabled, isFalse);
    expect(await controller.save(), isTrue);
    expect(provider.current.historyEnabled, isTrue);

    controller.updateGeneral(historyEnabled: false);
    expect(provider.current.historyEnabled, isFalse);
    expect(await controller.save(), isTrue);
    expect(repository.value.historyEnabled, isFalse);
    expect(provider.current.historyEnabled, isFalse);
    await controller.close();
  });

  test('failed privacy save rolls runtime back to persisted consent', () async {
    final enabled = AppSettings.defaults().copyWith(historyEnabled: true);
    final provider = MutableTextAssistantRuntimePolicyProvider();
    final applier = TextAssistantSettingsApplier(policyProvider: provider);
    final repository = _FakeSettingsRepository(enabled)..failSave = true;
    final controller = _controller(
      repository,
      _FakeHotkeyRegistrar(),
      runtime: applier,
      draftPrivacy: applier,
    );
    await controller.initialize();

    controller.updateGeneral(historyEnabled: false);
    expect(provider.current.historyEnabled, isFalse);

    expect(await controller.save(), isFalse);

    expect(provider.current.historyEnabled, isTrue);
    expect(controller.state.draft, enabled);
    await controller.close();
  });
}

SettingsController _controller(
  _FakeSettingsRepository repository,
  _FakeHotkeyRegistrar registrar, {
  SettingsRuntimeApplier? runtime,
  SettingsDraftPrivacyApplier? draftPrivacy,
  ProfileIdFactory? createProfileId,
}) =>
    SettingsController(
      repository: repository,
      hotkeyRegistrar: registrar,
      platform: ShortcutPlatform.windows,
      onShortcutTriggered: (_) {},
      runtimeApplier: runtime ?? _FakeRuntimeApplier(),
      draftPrivacyApplier:
          draftPrivacy ?? const NoOpSettingsDraftPrivacyApplier(),
      createProfileId: createProfileId,
    );

final class _FakeSettingsRepository implements SettingsRepository {
  _FakeSettingsRepository(this.value);

  AppSettings value;
  bool failSave = false;
  int saveCalls = 0;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async {
    saveCalls++;
    if (failSave) throw StateError('disk full');
    value = settings;
  }
}

final class _FakeHotkeyRegistrar implements HotkeyRegistrar {
  _FakeHotkeyRegistrar({this.events});

  final List<KeyBindingProfile> profiles = [];
  final List<String>? events;
  final Set<int> failOnCalls = {};
  int unregisterCalls = 0;
  int replaceCalls = 0;
  bool failRegistration = false;
  bool rollbackFailure = false;
  bool failUnregister = false;

  @override
  Future<void> replaceProfile({
    required KeyBindingProfile previous,
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  }) async {
    replaceCalls++;
    events?.add('hotkeys');
    if (failRegistration || failOnCalls.contains(replaceCalls)) {
      throw HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.conflict,
        diagnosticCode: rollbackFailure
            ? 'keybinding_registration_rollback_failed'
            : 'keybinding_registration_failed',
        rollbackFailed: rollbackFailure,
      );
    }
    profiles.add(next);
  }

  @override
  Future<void> unregisterAll() async {
    unregisterCalls++;
    if (failUnregister) throw StateError('unregister failed');
  }
}

final class _FakeRuntimeApplier implements SettingsRuntimeApplier {
  _FakeRuntimeApplier({this.events});

  final List<({AppSettings previous, AppSettings next})> applied = [];
  final List<String>? events;
  bool fail = false;
  Completer<void>? gate;
  Completer<void>? started;

  @override
  Future<void> apply({
    required AppSettings previous,
    required AppSettings next,
  }) async {
    applied.add((previous: previous, next: next));
    events?.add('runtime');
    started?.complete();
    if (fail) throw StateError('runtime apply failed');
    await gate?.future;
  }
}
