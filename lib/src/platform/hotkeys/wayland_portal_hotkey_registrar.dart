import 'dart:async';

import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/global_shortcuts_portal_bridge.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_runtime_state.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/xdg_shortcut_formatter.dart';

typedef PortalShortcutDescriptionProvider = String Function(
  ShortcutAction action,
);

final class WaylandPortalHotkeyRegistrar
    implements HotkeyRegistrar, HotkeyRegistrarLifecycle, HotkeyRuntimeSource {
  WaylandPortalHotkeyRegistrar({
    required GlobalShortcutsPortalBridge bridge,
    PortalShortcutDescriptionProvider descriptionProvider = _defaultDescription,
  })  : _bridge = bridge,
        _descriptionProvider = descriptionProvider {
    _eventSubscription = _bridge.events.listen(
      _handleEvent,
      onError: _handleEventError,
    );
  }

  final GlobalShortcutsPortalBridge _bridge;
  final PortalShortcutDescriptionProvider _descriptionProvider;
  final StreamController<HotkeyRuntimeState> _states =
      StreamController<HotkeyRuntimeState>.broadcast(sync: true);
  late final StreamSubscription<GlobalShortcutsPortalEvent> _eventSubscription;
  Future<void> _operationTail = Future<void>.value();
  HotkeyRuntimeState _state = HotkeyRuntimeState.inactive();
  int _nextGeneration = 0;
  int _authorityEpoch = 0;
  int? _activeGeneration;
  int? _provisionalGeneration;
  KeyBindingProfile? _activeProfile;
  void Function(ShortcutAction action)? _activeCallback;
  Map<String, ShortcutAction> _activeActions = const {};
  final Set<String> _pressedShortcutIds = {};
  bool _closing = false;
  bool _closed = false;

  @override
  HotkeyRuntimeState get state => _state;

  @override
  Stream<HotkeyRuntimeState> get states => _states.stream;

  @override
  Future<void> replaceProfile({
    required KeyBindingProfile previous,
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  }) {
    if (_closing || _closed) {
      return Future<void>.error(StateError('Hotkey registrar is closed.'));
    }
    return _serialize(
      () => _replaceProfile(next: next, onTriggered: onTriggered),
    );
  }

  Future<void> _replaceProfile({
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  }) async {
    final previousState = _state;
    final authorityEpoch = _authorityEpoch;
    final requestedActions = <String, ShortcutAction>{};
    final requestedBindings = <ShortcutAction, HotkeyRuntimeBinding>{};
    final definitions = <PortalShortcutDefinition>[];
    try {
      for (final action in ShortcutAction.values) {
        final chord = next.bindings[action];
        if (chord == null || !chord.enabled) continue;
        final preferredTrigger = formatXdgShortcut(chord);
        final id = action.name;
        requestedActions[id] = action;
        requestedBindings[action] = HotkeyRuntimeBinding(
          action: action,
          desiredTrigger: preferredTrigger,
        );
        definitions.add(PortalShortcutDefinition(
          id: id,
          description: _descriptionProvider(action),
          preferredTrigger: preferredTrigger,
        ));
      }
    } catch (error) {
      throw HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.unsupported,
        diagnosticCode: 'wayland_global_shortcuts_invalid_profile',
        cause: error,
      );
    }

    if (definitions.isEmpty) {
      await _bridge.cancelPendingRequest();
      await _bridge.closeSessions();
      _activeGeneration = null;
      _activeProfile = null;
      _activeCallback = null;
      _activeActions = const {};
      _pressedShortcutIds.clear();
      _emit(HotkeyRuntimeState(
        phase: HotkeyRuntimePhase.inactive,
        portalVersion: _state.portalVersion,
        bindings: const {},
      ));
      return;
    }

    GlobalShortcutsCapability capability;
    try {
      capability = await _bridge.getCapability();
    } catch (error) {
      _restoreOrExposeFailure(
        previousState,
        'wayland_global_shortcuts_capability_failed',
      );
      throw HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.platformError,
        diagnosticCode: 'wayland_global_shortcuts_capability_failed',
        cause: error,
      );
    }
    if (!capability.available) {
      _revoke(
        HotkeyRuntimePhase.unavailable,
        'wayland_global_shortcuts_unavailable',
        portalVersion: capability.version,
      );
      throw const HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.unsupported,
        diagnosticCode: 'wayland_global_shortcuts_unavailable',
      );
    }
    final generation = ++_nextGeneration;

    _emit(HotkeyRuntimeState(
      phase: HotkeyRuntimePhase.binding,
      portalVersion: capability.version,
      generation: generation,
      bindings: requestedBindings,
    ));

    PortalCandidateSession? candidate;
    try {
      candidate = await _bridge.createCandidate(
        generation: generation,
        shortcuts: definitions,
      );
      if (candidate.generation != generation) {
        throw const FormatException('Candidate generation mismatch.');
      }
      final result = await _bridge.bindCandidate(candidate);
      switch (result.status) {
        case PortalBindStatus.cancelled:
          throw const _PortalRegistrationFailure(
            kind: HotkeyRegistrationFailureKind.permissionDenied,
            diagnosticCode: 'wayland_global_shortcuts_cancelled',
          );
        case PortalBindStatus.failed:
          throw _PortalRegistrationFailure(
            kind: HotkeyRegistrationFailureKind.platformError,
            diagnosticCode: result.diagnosticCode?.isNotEmpty == true
                ? result.diagnosticCode!
                : 'wayland_global_shortcuts_bind_failed',
          );
        case PortalBindStatus.success:
          break;
      }
      final actualById = _validateExactBindings(
        requestedIds: requestedActions.keys.toSet(),
        bindings: result.bindings,
      );
      if (_authorityEpoch != authorityEpoch) {
        throw const _PortalRegistrationFailure(
          kind: HotkeyRegistrationFailureKind.platformError,
          diagnosticCode: 'wayland_global_shortcuts_revoked_during_binding',
        );
      }
      _provisionalGeneration = generation;
      await _bridge.commitCandidate(candidate);
      if (_authorityEpoch != authorityEpoch) {
        throw const _PortalRegistrationFailure(
          kind: HotkeyRegistrationFailureKind.platformError,
          diagnosticCode: 'wayland_global_shortcuts_revoked_during_binding',
        );
      }

      _activeGeneration = generation;
      _provisionalGeneration = null;
      _activeProfile = next;
      _activeCallback = onTriggered;
      _activeActions = Map.unmodifiable(requestedActions);
      _pressedShortcutIds.clear();
      _emit(HotkeyRuntimeState(
        phase: HotkeyRuntimePhase.active,
        portalVersion: capability.version,
        generation: generation,
        bindings: {
          for (final entry in requestedBindings.entries)
            entry.key: HotkeyRuntimeBinding(
              action: entry.key,
              desiredTrigger: entry.value.desiredTrigger,
              actualTriggerDescription:
                  actualById[entry.key.name]?.triggerDescription,
            ),
        },
      ));
    } on _PortalRegistrationFailure catch (error) {
      if (_provisionalGeneration == generation) _provisionalGeneration = null;
      await _discardBestEffort(candidate);
      _restoreOrExposeFailure(previousState, error.diagnosticCode);
      throw HotkeyRegistrationException(
        kind: error.kind,
        diagnosticCode: error.diagnosticCode,
      );
    } on FormatException catch (error) {
      if (_provisionalGeneration == generation) _provisionalGeneration = null;
      await _discardBestEffort(candidate);
      _restoreOrExposeFailure(
        previousState,
        'wayland_global_shortcuts_malformed_response',
      );
      throw HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.platformError,
        diagnosticCode: 'wayland_global_shortcuts_malformed_response',
        cause: error,
      );
    } catch (error) {
      if (_provisionalGeneration == generation) _provisionalGeneration = null;
      await _discardBestEffort(candidate);
      _restoreOrExposeFailure(
        previousState,
        'wayland_global_shortcuts_registration_failed',
      );
      throw HotkeyRegistrationException(
        kind: HotkeyRegistrationFailureKind.platformError,
        diagnosticCode: 'wayland_global_shortcuts_registration_failed',
        cause: error,
      );
    }
  }

  Map<String, PortalShortcutBinding> _validateExactBindings({
    required Set<String> requestedIds,
    required List<PortalShortcutBinding> bindings,
  }) {
    final actualById = <String, PortalShortcutBinding>{};
    for (final binding in bindings) {
      if (actualById.containsKey(binding.id)) {
        throw const FormatException('Duplicate portal shortcut binding.');
      }
      actualById[binding.id] = binding;
    }
    if (actualById.length != requestedIds.length ||
        !actualById.keys.toSet().containsAll(requestedIds) ||
        !requestedIds.containsAll(actualById.keys)) {
      throw const _PortalRegistrationFailure(
        kind: HotkeyRegistrationFailureKind.permissionDenied,
        diagnosticCode: 'wayland_global_shortcuts_partial_bind',
      );
    }
    return actualById;
  }

  Future<void> _discardBestEffort(PortalCandidateSession? candidate) async {
    if (candidate == null) return;
    try {
      await _bridge.discardCandidate(candidate);
    } catch (_) {}
  }

  void _restoreOrExposeFailure(
    HotkeyRuntimeState previousState,
    String diagnosticCode,
  ) {
    if (previousState.phase == HotkeyRuntimePhase.active &&
        previousState.generation != null &&
        _activeGeneration == previousState.generation) {
      _emit(previousState);
      return;
    }
    if (_activeGeneration == null &&
        (_state.phase == HotkeyRuntimePhase.revoked ||
            _state.phase == HotkeyRuntimePhase.unavailable)) {
      return;
    }
    _emit(_state.copyWith(
      phase: HotkeyRuntimePhase.failed,
      clearGeneration: true,
      bindings: const {},
      diagnosticCode: diagnosticCode,
    ));
  }

  @override
  Future<void> unregisterAll() {
    if (_closed) return Future<void>.value();
    final cancellation = _bridge.cancelPendingRequest().catchError((_) {});
    return _serialize(() async {
      await cancellation;
      _activeGeneration = null;
      _activeProfile = null;
      _activeCallback = null;
      _activeActions = const {};
      _pressedShortcutIds.clear();
      await _bridge.closeSessions();
      if (!_closing) {
        final preserveFailure =
            _state.phase == HotkeyRuntimePhase.unavailable ||
                _state.phase == HotkeyRuntimePhase.revoked ||
                _state.phase == HotkeyRuntimePhase.failed;
        _emit(_state.copyWith(
          phase: preserveFailure ? _state.phase : HotkeyRuntimePhase.inactive,
          clearGeneration: true,
          bindings: const {},
          clearDiagnosticCode: !preserveFailure,
        ));
      }
    });
  }

  @override
  Future<void> configureShortcuts() async {
    if (_state.portalVersion < 2 || _state.phase != HotkeyRuntimePhase.active) {
      throw StateError('Global shortcut configuration is unavailable.');
    }
    await _bridge.configureShortcuts();
  }

  @override
  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    try {
      await unregisterAll();
    } finally {
      await _eventSubscription.cancel();
      try {
        await _bridge.dispose();
      } finally {
        _closed = true;
        _emit(_state.copyWith(
          phase: HotkeyRuntimePhase.closed,
          clearGeneration: true,
          bindings: const {},
        ));
        await _states.close();
      }
    }
  }

  void _handleEvent(GlobalShortcutsPortalEvent event) {
    if (_closing || _closed) return;
    if (event is PortalAvailabilityChanged) {
      if (!event.capability.available) {
        _revoke(
          HotkeyRuntimePhase.unavailable,
          'wayland_global_shortcuts_unavailable',
          portalVersion: event.capability.version,
        );
      } else {
        _emit(_state.copyWith(portalVersion: event.capability.version));
      }
      return;
    }
    final isActiveGeneration = event.generation == _activeGeneration;
    final isProvisionalGeneration = event.generation == _provisionalGeneration;
    if (!isActiveGeneration && !isProvisionalGeneration) return;
    if (isProvisionalGeneration && !isActiveGeneration) {
      if (event is PortalSessionClosed) {
        _revoke(
          HotkeyRuntimePhase.revoked,
          event.reason?.isNotEmpty == true
              ? event.reason!
              : 'wayland_global_shortcuts_session_closed',
        );
      }
      return;
    }

    switch (event) {
      case PortalShortcutActivated():
        final action = _activeActions[event.shortcutId];
        if (action == null || !_pressedShortcutIds.add(event.shortcutId)) {
          return;
        }
        _activeCallback?.call(action);
      case PortalShortcutDeactivated():
        if (_activeActions.containsKey(event.shortcutId)) {
          _pressedShortcutIds.remove(event.shortcutId);
        }
      case PortalShortcutsChanged():
        _applyChangedBindings(event.bindings);
      case PortalSessionClosed():
        _revoke(
          HotkeyRuntimePhase.revoked,
          event.reason?.isNotEmpty == true
              ? event.reason!
              : 'wayland_global_shortcuts_session_closed',
        );
      case PortalAvailabilityChanged():
        break;
    }
  }

  void _applyChangedBindings(List<PortalShortcutBinding> bindings) {
    final activeIds = _activeActions.keys.toSet();
    Map<String, PortalShortcutBinding> actualById;
    try {
      actualById = _validateExactBindings(
        requestedIds: activeIds,
        bindings: bindings,
      );
    } catch (_) {
      _revoke(
        HotkeyRuntimePhase.revoked,
        'wayland_global_shortcuts_changed_partial',
      );
      return;
    }
    final profile = _activeProfile;
    if (profile == null) return;
    _emit(_state.copyWith(
      bindings: {
        for (final entry in _activeActions.entries)
          entry.value: HotkeyRuntimeBinding(
            action: entry.value,
            desiredTrigger: formatXdgShortcut(
              profile.bindings[entry.value]!,
            ),
            actualTriggerDescription: actualById[entry.key]?.triggerDescription,
          ),
      },
      clearDiagnosticCode: true,
    ));
  }

  void _handleEventError(Object error, StackTrace stackTrace) {
    if (_closing || _closed) return;
    _revoke(
      HotkeyRuntimePhase.failed,
      'wayland_global_shortcuts_event_stream_failed',
    );
  }

  void _revoke(
    HotkeyRuntimePhase phase,
    String diagnosticCode, {
    int? portalVersion,
  }) {
    final hadActiveSession =
        _activeGeneration != null || _provisionalGeneration != null;
    final revokeEpoch = ++_authorityEpoch;
    _activeGeneration = null;
    _provisionalGeneration = null;
    _activeProfile = null;
    _activeCallback = null;
    _activeActions = const {};
    _pressedShortcutIds.clear();
    _emit(_state.copyWith(
      phase: phase,
      portalVersion: portalVersion,
      clearGeneration: true,
      bindings: const {},
      diagnosticCode: diagnosticCode,
    ));
    if (hadActiveSession && !_closing && !_closed) {
      unawaited(_serialize(() async {
        if (_authorityEpoch != revokeEpoch || _activeGeneration != null) return;
        await _bridge.closeSessions();
      }).catchError((_) {}));
    }
  }

  void _emit(HotkeyRuntimeState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  static String _defaultDescription(ShortcutAction action) => switch (action) {
        ShortcutAction.showOverlay => 'Show text assistant',
        ShortcutAction.emojify => 'Add emoji to clipboard text',
        ShortcutAction.rewrite => 'Rewrite clipboard text',
        ShortcutAction.fix => 'Fix clipboard text',
      };
}

final class _PortalRegistrationFailure implements Exception {
  const _PortalRegistrationFailure({
    required this.kind,
    required this.diagnosticCode,
  });

  final HotkeyRegistrationFailureKind kind;
  final String diagnosticCode;
}
