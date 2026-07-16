import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/application/settings_state.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/data/file_settings_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/app_settings.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';

typedef ProfileIdFactory = String Function();

abstract interface class SettingsRuntimeApplier {
  Future<void> apply(
      {required AppSettings previous, required AppSettings next});
}

abstract interface class SettingsDraftPrivacyApplier {
  void applyWithdrawal({
    required AppSettings previousDraft,
    required AppSettings nextDraft,
  });

  void discard({required AppSettings authoritative});
}

final class NoOpSettingsDraftPrivacyApplier
    implements SettingsDraftPrivacyApplier {
  const NoOpSettingsDraftPrivacyApplier();

  @override
  void applyWithdrawal({
    required AppSettings previousDraft,
    required AppSettings nextDraft,
  }) {}

  @override
  void discard({required AppSettings authoritative}) {}
}

final class NoOpSettingsRuntimeApplier implements SettingsRuntimeApplier {
  const NoOpSettingsRuntimeApplier();

  @override
  Future<void> apply({
    required AppSettings previous,
    required AppSettings next,
  }) async {}
}

final class CompositeSettingsRuntimeApplier implements SettingsRuntimeApplier {
  CompositeSettingsRuntimeApplier(Iterable<SettingsRuntimeApplier> appliers)
      : _appliers = List.unmodifiable(appliers);

  final List<SettingsRuntimeApplier> _appliers;

  @override
  Future<void> apply({
    required AppSettings previous,
    required AppSettings next,
  }) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final applier in _appliers) {
      try {
        await applier.apply(previous: previous, next: next);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}

final class SettingsController extends Cubit<SettingsState> {
  SettingsController({
    required SettingsRepository repository,
    required HotkeyRegistrar hotkeyRegistrar,
    required ShortcutPlatform platform,
    required void Function(ShortcutAction action) onShortcutTriggered,
    SettingsRuntimeApplier runtimeApplier = const NoOpSettingsRuntimeApplier(),
    SettingsDraftPrivacyApplier draftPrivacyApplier =
        const NoOpSettingsDraftPrivacyApplier(),
    KeyBindingValidator validator = const KeyBindingValidator(),
    ProfileIdFactory? createProfileId,
  })  : _repository = repository,
        _hotkeyRegistrar = hotkeyRegistrar,
        _platform = platform,
        _onShortcutTriggered = onShortcutTriggered,
        _runtimeApplier = runtimeApplier,
        _draftPrivacyApplier = draftPrivacyApplier,
        _validator = validator,
        _createProfileId = createProfileId ??
            (() => 'profile-${DateTime.now().microsecondsSinceEpoch}'),
        super(const SettingsState());

  static const maxImportBytes = 64 * 1024;

  final SettingsRepository _repository;
  final HotkeyRegistrar _hotkeyRegistrar;
  final ShortcutPlatform _platform;
  final void Function(ShortcutAction action) _onShortcutTriggered;
  final SettingsRuntimeApplier _runtimeApplier;
  final SettingsDraftPrivacyApplier _draftPrivacyApplier;
  final KeyBindingValidator _validator;
  final ProfileIdFactory _createProfileId;
  bool _saveInProgress = false;

  bool get canStartTextOperation =>
      !_saveInProgress && state.stage == SettingsStage.ready;

  Future<void> initialize() async {
    emit(const SettingsState(stage: SettingsStage.loading));
    AppSettings? loaded;
    try {
      final settings = await _repository.load();
      loaded = settings;
      await _runtimeApplier.apply(previous: settings, next: settings);
      await _hotkeyRegistrar.replaceProfile(
        previous: settings.activeProfile,
        next: settings.activeProfile,
        onTriggered: _onShortcutTriggered,
      );
      _emitDraft(settings, authoritative: settings);
    } on UnsupportedSettingsVersionException {
      emit(const SettingsState(
        stage: SettingsStage.failure,
        errorCode: 'settings_unsupported_version',
      ));
    } on HotkeyRegistrationException catch (error) {
      if (loaded == null) {
        emit(SettingsState(
          stage: SettingsStage.failure,
          errorCode: error.diagnosticCode,
        ));
        return;
      }
      if (error.kind == HotkeyRegistrationFailureKind.conflict) {
        _emitDraft(
          loaded,
          authoritative: loaded,
          errorCode: error.diagnosticCode,
          conflictedShortcuts: error.failedActions,
        );
        return;
      }
      try {
        await _hotkeyRegistrar.unregisterAll();
        _emitDraft(
          loaded,
          authoritative: loaded,
          errorCode: error.diagnosticCode,
        );
      } catch (_) {
        emit(SettingsState(
          stage: SettingsStage.failure,
          authoritative: loaded,
          draft: loaded,
          issues: _issuesFor(loaded),
          errorCode: 'settings_initialization_rollback_failed',
        ));
      }
    } catch (_) {
      if (loaded == null) {
        emit(const SettingsState(
          stage: SettingsStage.failure,
          errorCode: 'settings_load_failed',
        ));
        return;
      }
      try {
        await _hotkeyRegistrar.unregisterAll();
        _emitDraft(
          loaded,
          authoritative: loaded,
          errorCode: 'settings_runtime_apply_failed',
        );
      } catch (_) {
        emit(SettingsState(
          stage: SettingsStage.failure,
          authoritative: loaded,
          draft: loaded,
          issues: _issuesFor(loaded),
          errorCode: 'settings_initialization_rollback_failed',
        ));
      }
    }
  }

  void updateGeneral({
    String? locale,
    AppThemePreference? theme,
    bool? launchAtStartup,
    ShortcutAction? defaultAction,
    ClipboardPolicy? clipboardPolicy,
    int? requestTimeoutMilliseconds,
    int? retryAttempts,
    bool? historyEnabled,
    bool? diagnosticsEnabled,
  }) {
    if (!_canMutate) return;
    final draft = state.draft;
    if (draft == null) return;
    final nextDraft = draft.copyWith(
      locale: locale,
      theme: theme,
      launchAtStartup: launchAtStartup,
      defaultAction: defaultAction,
      clipboardPolicy: clipboardPolicy,
      requestTimeoutMilliseconds: requestTimeoutMilliseconds,
      retryAttempts: retryAttempts,
      historyEnabled: historyEnabled,
      diagnosticsEnabled: diagnosticsEnabled,
    );
    _draftPrivacyApplier.applyWithdrawal(
      previousDraft: draft,
      nextDraft: nextDraft,
    );
    _emitDraft(nextDraft);
  }

  void updateBinding(ShortcutAction action, KeyChord chord) {
    if (!_canMutate) return;
    final draft = state.draft;
    if (draft == null) return;
    final profile = draft.activeProfile.copyWith(bindings: {
      ...draft.activeProfile.bindings,
      action: chord,
    });
    _replaceProfile(profile);
  }

  void resetBinding(ShortcutAction action) {
    updateBinding(
      action,
      KeyBindingProfile.defaults().bindings[action]!,
    );
  }

  void createProfile(String name) {
    if (!_canMutate) return;
    final draft = state.draft;
    if (draft == null) return;
    final profile = KeyBindingProfile.defaults().copyWith(
      id: _createUniqueProfileId(draft),
      name: _normalizeProfileName(name),
    );
    _emitDraft(draft.copyWith(
      profiles: [...draft.profiles, profile],
      activeProfileId: profile.id,
    ));
  }

  void duplicateActiveProfile(String name) {
    if (!_canMutate) return;
    final draft = state.draft;
    if (draft == null) return;
    final profile = draft.activeProfile.copyWith(
      id: _createUniqueProfileId(draft),
      name: _normalizeProfileName(name),
    );
    _emitDraft(draft.copyWith(
      profiles: [...draft.profiles, profile],
      activeProfileId: profile.id,
    ));
  }

  void renameActiveProfile(String name) {
    if (!_canMutate) return;
    final draft = state.draft;
    if (draft == null) return;
    _replaceProfile(draft.activeProfile.copyWith(
      name: _normalizeProfileName(name),
    ));
  }

  void deleteActiveProfile() {
    if (!_canMutate) return;
    final draft = state.draft;
    if (draft == null || draft.profiles.length == 1) return;
    final remaining = draft.profiles
        .where((profile) => profile.id != draft.activeProfileId)
        .toList();
    _emitDraft(draft.copyWith(
      profiles: remaining,
      activeProfileId: remaining.first.id,
    ));
  }

  void selectProfile(String profileId) {
    if (!_canMutate) return;
    final draft = state.draft;
    if (draft == null ||
        !draft.profiles.any((profile) => profile.id == profileId)) {
      return;
    }
    _emitDraft(draft.copyWith(activeProfileId: profileId));
  }

  void resetActiveProfile() {
    if (!_canMutate) return;
    final draft = state.draft;
    if (draft == null) return;
    _replaceProfile(KeyBindingProfile.defaults().copyWith(
      id: draft.activeProfile.id,
      name: draft.activeProfile.name,
    ));
  }

  String exportActiveProfile() {
    final profile = state.draft?.activeProfile;
    if (profile == null) {
      throw StateError('Settings are not loaded.');
    }
    return const JsonEncoder.withIndent('  ').convert({
      'type': 'yandex-keyboard-keybinding-profile',
      'schemaVersion': 1,
      'profile': profile.toJson(),
    });
  }

  void importProfile(String source) {
    if (!_canMutate) {
      throw StateError('Settings cannot be edited while saving.');
    }
    if (utf8.encode(source).length > maxImportBytes) {
      throw const FormatException('Imported profile is too large.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['type'] != 'yandex-keyboard-keybinding-profile' ||
        decoded['schemaVersion'] != 1 ||
        decoded['profile'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid profile export.');
    }
    final draft = state.draft;
    if (draft == null) {
      throw StateError('Settings are not loaded.');
    }
    final imported = KeyBindingProfile.fromJson(
      decoded['profile'] as Map<String, dynamic>,
    );
    final issues = _validator.validate(imported, platform: _platform).where(
          (issue) => issue.kind != KeyBindingIssueKind.unsupportedPlatform,
        );
    if (issues.isNotEmpty) {
      throw const FormatException('Imported profile is invalid.');
    }
    final profile = imported.copyWith(id: _createUniqueProfileId(draft));
    _emitDraft(draft.copyWith(
      profiles: [...draft.profiles, profile],
      activeProfileId: profile.id,
    ));
  }

  Future<bool> save() {
    if (_saveInProgress) return Future<bool>.value(false);
    _saveInProgress = true;
    return _save().whenComplete(() => _saveInProgress = false);
  }

  Future<void> suspendGlobalHotkeys() async {
    try {
      await _hotkeyRegistrar.unregisterAll();
    } catch (_) {}
  }

  Future<void> resumeGlobalHotkeys() async {
    final authoritative = state.authoritative;
    if (authoritative == null) return;
    try {
      await _hotkeyRegistrar.replaceProfile(
        previous: authoritative.activeProfile,
        next: authoritative.activeProfile,
        onTriggered: _onShortcutTriggered,
      );
    } catch (_) {}
  }

  Future<bool> retryHotkeyRegistration() async {
    if (_saveInProgress || state.stage != SettingsStage.ready) return false;
    final authoritative = state.authoritative;
    final draft = state.draft;
    if (authoritative == null || draft == null) return false;
    _saveInProgress = true;
    try {
      await _hotkeyRegistrar.replaceProfile(
        previous: authoritative.activeProfile,
        next: authoritative.activeProfile,
        onTriggered: _onShortcutTriggered,
      );
      _emitDraft(draft, authoritative: authoritative);
      return true;
    } on HotkeyRegistrationException catch (error) {
      _emitDraft(
        draft,
        authoritative: authoritative,
        errorCode: error.diagnosticCode,
        conflictedShortcuts: error.failedActions,
      );
      return false;
    } catch (_) {
      _emitDraft(
        draft,
        authoritative: authoritative,
        errorCode: 'keybinding_registration_failed',
      );
      return false;
    } finally {
      _saveInProgress = false;
    }
  }

  Future<bool> _save() async {
    final authoritative = state.authoritative;
    final draft = state.draft;
    if (authoritative == null || draft == null || state.hasBlockingIssues) {
      return false;
    }
    emit(SettingsState(
      stage: SettingsStage.saving,
      authoritative: authoritative,
      draft: draft,
      issues: state.issues,
    ));
    try {
      HotkeyRegistrationException? conflict;
      try {
        await _hotkeyRegistrar.replaceProfile(
          previous: authoritative.activeProfile,
          next: draft.activeProfile,
          onTriggered: _onShortcutTriggered,
        );
      } on HotkeyRegistrationException catch (error) {
        if (error.kind != HotkeyRegistrationFailureKind.conflict ||
            error.rollbackFailed) {
          rethrow;
        }
        conflict = error;
      }
      await _runtimeApplier.apply(previous: authoritative, next: draft);
      await _repository.save(draft);
      final persisted = await _repository.load();
      _emitDraft(
        persisted,
        authoritative: persisted,
        errorCode: conflict?.diagnosticCode,
        conflictedShortcuts: conflict?.failedActions ?? const [],
      );
      return true;
    } on HotkeyRegistrationException catch (error) {
      if (error.rollbackFailed) {
        try {
          await _hotkeyRegistrar.unregisterAll();
        } catch (_) {
          emit(SettingsState(
            stage: SettingsStage.failure,
            authoritative: authoritative,
            draft: draft,
            issues: state.issues,
            errorCode: error.diagnosticCode,
          ));
          return false;
        }
        _emitDraft(
          draft,
          authoritative: authoritative,
          errorCode: error.diagnosticCode,
        );
        return false;
      }
      _emitDraft(
        draft,
        authoritative: authoritative,
        errorCode: error.diagnosticCode,
        conflictedShortcuts: error.failedActions,
      );
      return false;
    } catch (_) {
      await _reconcileAfterSaveFailure(
        authoritative: authoritative,
        attempted: draft,
      );
      return false;
    }
  }

  Future<void> _reconcileAfterSaveFailure({
    required AppSettings authoritative,
    required AppSettings attempted,
  }) async {
    try {
      final persisted = await _repository.load();
      Object? reconciliationError;
      try {
        await _hotkeyRegistrar.replaceProfile(
          previous: attempted.activeProfile,
          next: persisted.activeProfile,
          onTriggered: _onShortcutTriggered,
        );
      } catch (error) {
        reconciliationError = error;
      }
      try {
        await _runtimeApplier.apply(previous: attempted, next: persisted);
      } catch (error) {
        reconciliationError ??= error;
      }
      if (reconciliationError != null) {
        emit(SettingsState(
          stage: SettingsStage.failure,
          authoritative: persisted,
          draft: persisted,
          issues: _issuesFor(persisted),
          errorCode: 'settings_reconciliation_failed',
        ));
        return;
      }
      _emitDraft(
        persisted,
        authoritative: persisted,
        errorCode: 'settings_save_failed',
      );
    } catch (_) {
      emit(SettingsState(
        stage: SettingsStage.failure,
        authoritative: authoritative,
        draft: attempted,
        issues: _issuesFor(attempted),
        errorCode: 'settings_reconciliation_failed',
      ));
    }
  }

  void discardChanges() {
    if (!_canMutate) return;
    final authoritative = state.authoritative;
    if (authoritative != null) {
      _draftPrivacyApplier.discard(authoritative: authoritative);
      _emitDraft(authoritative, authoritative: authoritative);
    }
  }

  void _replaceProfile(KeyBindingProfile replacement) {
    final draft = state.draft;
    if (draft == null) return;
    _emitDraft(draft.copyWith(
      profiles: [
        for (final profile in draft.profiles)
          if (profile.id == replacement.id) replacement else profile,
      ],
    ));
  }

  void _emitDraft(
    AppSettings draft, {
    AppSettings? authoritative,
    String? errorCode,
    List<ShortcutAction> conflictedShortcuts = const [],
  }) {
    emit(SettingsState(
      stage: SettingsStage.ready,
      authoritative: authoritative ?? state.authoritative,
      draft: draft,
      issues: _issuesFor(draft),
      errorCode: errorCode,
      conflictedShortcuts: conflictedShortcuts,
    ));
  }

  List<ProfileKeyBindingIssue> _issuesFor(AppSettings settings) => [
        for (final profile in settings.profiles)
          for (final issue in _validator.validate(profile, platform: _platform))
            ProfileKeyBindingIssue(profileId: profile.id, issue: issue),
      ];

  String _createUniqueProfileId(AppSettings settings) {
    for (var attempt = 0; attempt < 100; attempt++) {
      final candidate = _createProfileId();
      if (!settings.profiles.any((profile) => profile.id == candidate)) {
        return candidate;
      }
    }
    throw StateError('Could not create a unique profile id.');
  }

  String _normalizeProfileName(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 64) {
      throw const FormatException('Invalid profile name.');
    }
    return normalized;
  }

  bool get _canMutate => !_saveInProgress && state.stage == SettingsStage.ready;
}
