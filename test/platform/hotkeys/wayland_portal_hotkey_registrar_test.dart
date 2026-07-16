import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/global_shortcuts_portal_bridge.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_registrar.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_runtime_state.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/wayland_portal_hotkey_registrar.dart';

void main() {
  test('commits an exact candidate and exposes opaque actual triggers',
      () async {
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final triggered = <ShortcutAction>[];
    final profile = KeyBindingProfile.defaults();

    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: triggered.add,
    );

    expect(bridge.committed.single.generation, 1);
    expect(registrar.state.phase, HotkeyRuntimePhase.active);
    expect(registrar.state.portalVersion, 2);
    expect(
      registrar
          .state.bindings[ShortcutAction.rewrite]?.actualTriggerDescription,
      'opaque:rewrite:1',
    );

    bridge.emit(PortalShortcutActivated(
      generation: 1,
      shortcutId: 'rewrite',
      timestamp: 10,
      activationToken: 'token',
    ));
    bridge.emit(PortalShortcutActivated(
      generation: 1,
      shortcutId: 'rewrite',
      timestamp: 11,
    ));
    bridge.emit(PortalShortcutDeactivated(
      generation: 1,
      shortcutId: 'rewrite',
      timestamp: 12,
    ));
    bridge.emit(PortalShortcutActivated(
      generation: 1,
      shortcutId: 'rewrite',
      timestamp: 13,
    ));

    expect(triggered, [ShortcutAction.rewrite, ShortcutAction.rewrite]);
    await registrar.close();
  });

  test('partial replacement fails closed and retains previous callback',
      () async {
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final firstTriggered = <ShortcutAction>[];
    final secondTriggered = <ShortcutAction>[];
    final profile = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: firstTriggered.add,
    );
    final activeBefore = registrar.state;
    bridge.results.add(PortalBindResult(
      status: PortalBindStatus.success,
      bindings: [_binding('rewrite', 2)],
    ));

    await expectLater(
      registrar.replaceProfile(
        previous: profile,
        next: _changedProfile(profile),
        onTriggered: secondTriggered.add,
      ),
      throwsA(isA<HotkeyRegistrationException>().having(
        (error) => error.diagnosticCode,
        'diagnosticCode',
        'wayland_global_shortcuts_partial_bind',
      )),
    );

    expect(bridge.committed, hasLength(1));
    expect(bridge.discarded.single.generation, 2);
    expect(registrar.state, activeBefore);
    bridge.emit(PortalShortcutActivated(
      generation: 2,
      shortcutId: 'rewrite',
      timestamp: 1,
    ));
    bridge.emit(PortalShortcutActivated(
      generation: 1,
      shortcutId: 'fix',
      timestamp: 2,
    ));
    expect(firstTriggered, [ShortcutAction.fix]);
    expect(secondTriggered, isEmpty);
    await registrar.close();
  });

  test('cancel and malformed response discard candidate without commit',
      () async {
    final profile = KeyBindingProfile.defaults();

    for (final scenario in <(PortalBindResult?, String)>[
      (
        PortalBindResult(
          status: PortalBindStatus.cancelled,
          bindings: const [],
        ),
        'wayland_global_shortcuts_cancelled',
      ),
      (null, 'wayland_global_shortcuts_malformed_response'),
    ]) {
      final bridge = _FakePortalBridge();
      if (scenario.$1 case final result?) {
        bridge.results.add(result);
      } else {
        bridge.bindError = const FormatException('malformed');
      }
      final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);

      await expectLater(
        registrar.replaceProfile(
          previous: profile,
          next: profile,
          onTriggered: (_) {},
        ),
        throwsA(isA<HotkeyRegistrationException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          scenario.$2,
        )),
      );

      expect(bridge.committed, isEmpty);
      expect(bridge.discarded, hasLength(1));
      expect(registrar.state.phase, HotkeyRuntimePhase.failed);
      expect(registrar.state.diagnosticCode, scenario.$2);
      await registrar.unregisterAll();
      expect(registrar.state.phase, HotkeyRuntimePhase.failed);
      expect(registrar.state.diagnosticCode, scenario.$2);
      await registrar.close();
    }
  });

  test('ignores unknown and stale activation events', () async {
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final triggered = <ShortcutAction>[];
    final profile = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: triggered.add,
    );

    bridge.emit(PortalShortcutActivated(
      generation: 0 + 2,
      shortcutId: 'rewrite',
      timestamp: 1,
    ));
    bridge.emit(PortalShortcutActivated(
      generation: 1,
      shortcutId: 'unknown',
      timestamp: 2,
    ));

    expect(triggered, isEmpty);
    await registrar.close();
  });

  test('updates exact changed triggers and revokes a partial session',
      () async {
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final triggered = <ShortcutAction>[];
    final profile = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: triggered.add,
    );

    bridge.emit(PortalShortcutsChanged(
      generation: 1,
      bindings: [
        for (final action in ShortcutAction.values)
          PortalShortcutBinding(
            id: action.name,
            description: action.name,
            triggerDescription: 'system chose ${action.name}',
          ),
      ],
    ));
    expect(
      registrar.state.bindings[ShortcutAction.fix]?.actualTriggerDescription,
      'system chose fix',
    );

    bridge.emit(PortalShortcutsChanged(
      generation: 1,
      bindings: [_binding('rewrite', 1)],
    ));
    expect(registrar.state.phase, HotkeyRuntimePhase.revoked);
    expect(
      registrar.state.diagnosticCode,
      'wayland_global_shortcuts_changed_partial',
    );
    bridge.emit(PortalShortcutActivated(
      generation: 1,
      shortcutId: 'rewrite',
      timestamp: 3,
    ));
    expect(triggered, isEmpty);
    await registrar.close();
  });

  test('session close and portal loss revoke active generation', () async {
    final profile = KeyBindingProfile.defaults();

    final closedBridge = _FakePortalBridge();
    final closedRegistrar = WaylandPortalHotkeyRegistrar(bridge: closedBridge);
    await closedRegistrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: (_) {},
    );
    closedBridge.emit(PortalSessionClosed(
      generation: 1,
      reason: 'revoked-by-user',
    ));
    expect(closedRegistrar.state.phase, HotkeyRuntimePhase.revoked);
    expect(closedRegistrar.state.diagnosticCode, 'revoked-by-user');
    await closedRegistrar.close();

    final lostBridge = _FakePortalBridge();
    final lostRegistrar = WaylandPortalHotkeyRegistrar(bridge: lostBridge);
    await lostRegistrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: (_) {},
    );
    lostBridge.emit(const PortalAvailabilityChanged(
      generation: 1,
      capability: GlobalShortcutsCapability(available: false, version: 0),
    ));
    expect(lostRegistrar.state.phase, HotkeyRuntimePhase.unavailable);
    await lostRegistrar.close();
  });

  test('unavailable capability fails before creating a candidate', () async {
    final bridge = _FakePortalBridge()
      ..capability =
          const GlobalShortcutsCapability(available: false, version: 0);
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final profile = KeyBindingProfile.defaults();

    await expectLater(
      registrar.replaceProfile(
        previous: profile,
        next: profile,
        onTriggered: (_) {},
      ),
      throwsA(isA<HotkeyRegistrationException>().having(
        (error) => error.kind,
        'kind',
        HotkeyRegistrationFailureKind.unsupported,
      )),
    );

    expect(bridge.created, isEmpty);
    expect(registrar.state.phase, HotkeyRuntimePhase.unavailable);
    await registrar.close();
  });

  test('configure requires an active version 2 session', () async {
    final profile = KeyBindingProfile.defaults();
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    expect(registrar.configureShortcuts, throwsStateError);

    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: (_) {},
    );
    await registrar.configureShortcuts();
    expect(bridge.configureCalls, 1);
    await registrar.close();
  });

  test('an all-disabled profile closes sessions without opening a portal',
      () async {
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final profile = KeyBindingProfile.defaults();
    final disabled = profile.copyWith(bindings: {
      for (final entry in profile.bindings.entries)
        entry.key: entry.value.copyWith(enabled: false),
    });

    await registrar.replaceProfile(
      previous: profile,
      next: disabled,
      onTriggered: (_) {},
    );

    expect(bridge.created, isEmpty);
    expect(bridge.capabilityCalls, 0);
    expect(bridge.cancelCalls, 1);
    expect(bridge.closeCalls, 1);
    expect(registrar.state.phase, HotkeyRuntimePhase.inactive);
    expect(registrar.state.portalVersion, 0);
    await registrar.close();
  });

  test('concurrent owner loss cannot be overwritten by replacement rollback',
      () async {
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final profile = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: (_) {},
    );
    bridge.bindError = StateError('portal disappeared');
    bridge.onBind = (candidate) {
      bridge.emit(PortalSessionClosed(
        generation: 1,
        reason: 'portal_owner_lost',
      ));
    };

    await expectLater(
      registrar.replaceProfile(
        previous: profile,
        next: _changedProfile(profile),
        onTriggered: (_) {},
      ),
      throwsA(isA<HotkeyRegistrationException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(registrar.state.phase, HotkeyRuntimePhase.revoked);
    expect(registrar.state.generation, isNull);
    expect(registrar.state.bindings, isEmpty);
    expect(bridge.closeCalls, greaterThanOrEqualTo(1));
    await registrar.close();
  });

  test('revoke during a successful bind invalidates the replacement', () async {
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final profile = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: (_) {},
    );
    bridge.onBind = (candidate) {
      bridge.emit(PortalSessionClosed(
        generation: 1,
        reason: 'portal_owner_lost',
      ));
    };

    await expectLater(
      registrar.replaceProfile(
        previous: profile,
        next: _changedProfile(profile),
        onTriggered: (_) {},
      ),
      throwsA(
        isA<HotkeyRegistrationException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'wayland_global_shortcuts_revoked_during_binding',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(bridge.committed, hasLength(1));
    expect(bridge.discarded.single.generation, 2);
    expect(registrar.state.phase, HotkeyRuntimePhase.revoked);
    expect(registrar.state.generation, isNull);
    expect(registrar.state.bindings, isEmpty);
    expect(bridge.closeCalls, 1);
    await registrar.close();
  });

  test('revoke during commit cannot publish a dead candidate', () async {
    final bridge = _FakePortalBridge();
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final profile = KeyBindingProfile.defaults();
    await registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: (_) {},
    );
    bridge.onCommit = (candidate) {
      bridge.emit(PortalSessionClosed(
        generation: candidate.generation,
        reason: 'malformed_shortcuts_changed',
      ));
    };

    await expectLater(
      registrar.replaceProfile(
        previous: profile,
        next: _changedProfile(profile),
        onTriggered: (_) {},
      ),
      throwsA(
        isA<HotkeyRegistrationException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'wayland_global_shortcuts_revoked_during_binding',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(bridge.committed.map((candidate) => candidate.generation), [1, 2]);
    expect(bridge.discarded.single.generation, 2);
    expect(registrar.state.phase, HotkeyRuntimePhase.revoked);
    expect(registrar.state.generation, isNull);
    expect(registrar.state.bindings, isEmpty);
    expect(bridge.closeCalls, 1);
    await registrar.close();
  });

  test('close cancels a pending request and is idempotent', () async {
    final bridge = _FakePortalBridge()..holdBindOpen = true;
    final registrar = WaylandPortalHotkeyRegistrar(bridge: bridge);
    final profile = KeyBindingProfile.defaults();
    final replacement = registrar.replaceProfile(
      previous: profile,
      next: profile,
      onTriggered: (_) {},
    );
    await bridge.bindStarted.future;

    final closing = registrar.close();
    await expectLater(replacement, throwsA(isA<HotkeyRegistrationException>()));
    await closing;
    await registrar.close();

    expect(bridge.cancelCalls, 1);
    expect(bridge.closeCalls, 1);
    expect(bridge.disposeCalls, 1);
    expect(registrar.state.phase, HotkeyRuntimePhase.closed);
  });
}

PortalShortcutBinding _binding(String id, int generation) =>
    PortalShortcutBinding(
      id: id,
      description: id,
      triggerDescription: 'opaque:$id:$generation',
    );

KeyBindingProfile _changedProfile(KeyBindingProfile source) =>
    source.copyWith(bindings: {
      ...source.bindings,
      ShortcutAction.showOverlay: KeyChord(
        key: 'F8',
        modifiers: {KeyModifier.control, KeyModifier.shift},
      ),
    });

final class _FakePortalBridge implements GlobalShortcutsPortalBridge {
  final StreamController<GlobalShortcutsPortalEvent> _events =
      StreamController<GlobalShortcutsPortalEvent>.broadcast(sync: true);
  final List<PortalCandidateSession> created = [];
  final List<PortalCandidateSession> committed = [];
  final List<PortalCandidateSession> discarded = [];
  final List<PortalBindResult> results = [];
  final Completer<void> bindStarted = Completer<void>();
  GlobalShortcutsCapability capability =
      const GlobalShortcutsCapability(available: true, version: 2);
  Object? bindError;
  void Function(PortalCandidateSession candidate)? onBind;
  void Function(PortalCandidateSession candidate)? onCommit;
  bool holdBindOpen = false;
  Completer<PortalBindResult>? _heldBind;
  int cancelCalls = 0;
  int closeCalls = 0;
  int configureCalls = 0;
  int disposeCalls = 0;
  int capabilityCalls = 0;

  void emit(GlobalShortcutsPortalEvent event) => _events.add(event);

  @override
  Stream<GlobalShortcutsPortalEvent> get events => _events.stream;

  @override
  Future<GlobalShortcutsCapability> getCapability() async {
    capabilityCalls++;
    return capability;
  }

  @override
  Future<PortalCandidateSession> createCandidate({
    required int generation,
    required List<PortalShortcutDefinition> shortcuts,
  }) async {
    final candidate = PortalCandidateSession(
      id: 'candidate-$generation',
      generation: generation,
    );
    created.add(candidate);
    return candidate;
  }

  @override
  Future<PortalBindResult> bindCandidate(
    PortalCandidateSession candidate,
  ) async {
    if (!bindStarted.isCompleted) bindStarted.complete();
    onBind?.call(candidate);
    if (bindError case final error?) throw error;
    if (holdBindOpen) {
      _heldBind = Completer<PortalBindResult>();
      return _heldBind!.future;
    }
    if (results.isNotEmpty) return results.removeAt(0);
    return PortalBindResult(
      status: PortalBindStatus.success,
      bindings: [
        for (final action in ShortcutAction.values)
          _binding(action.name, candidate.generation),
      ],
    );
  }

  @override
  Future<void> commitCandidate(PortalCandidateSession candidate) async {
    committed.add(candidate);
    onCommit?.call(candidate);
  }

  @override
  Future<void> discardCandidate(PortalCandidateSession candidate) async {
    discarded.add(candidate);
  }

  @override
  Future<void> cancelPendingRequest() async {
    cancelCalls++;
    final held = _heldBind;
    if (held != null && !held.isCompleted) {
      held.complete(PortalBindResult(
        status: PortalBindStatus.cancelled,
        bindings: const [],
      ));
    }
  }

  @override
  Future<void> closeSessions() async {
    closeCalls++;
  }

  @override
  Future<void> configureShortcuts() async {
    configureCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _events.close();
  }
}
