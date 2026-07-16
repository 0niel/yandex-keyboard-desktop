import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';
import 'package:yandex_keyboard_desktop/src/platform/hotkeys/hotkey_runtime_state.dart';

void main() {
  test('copyWith updates and explicitly clears nullable runtime fields', () {
    final original = HotkeyRuntimeState(
      phase: HotkeyRuntimePhase.active,
      portalVersion: 2,
      generation: 7,
      diagnosticCode: 'old',
      bindings: const {
        ShortcutAction.fix: HotkeyRuntimeBinding(
          action: ShortcutAction.fix,
          desiredTrigger: 'CTRL+F',
          actualTriggerDescription: 'Ctrl + F',
        ),
      },
    );
    final changed = original.copyWith(
      phase: HotkeyRuntimePhase.revoked,
      portalVersion: 3,
      generation: 8,
      diagnosticCode: 'new',
      bindings: const {
        ShortcutAction.rewrite: HotkeyRuntimeBinding(
          action: ShortcutAction.rewrite,
          desiredTrigger: 'CTRL+R',
        ),
      },
    );

    expect(changed.phase, HotkeyRuntimePhase.revoked);
    expect(changed.portalVersion, 3);
    expect(changed.generation, 8);
    expect(changed.diagnosticCode, 'new');
    expect(changed.bindings.keys, [ShortcutAction.rewrite]);
    expect(changed.configureSupported, true);
    expect(
      changed
          .copyWith(
            clearGeneration: true,
            clearDiagnosticCode: true,
          )
          .generation,
      isNull,
    );
    expect(
      changed.copyWith(clearDiagnosticCode: true).diagnosticCode,
      isNull,
    );
    expect(HotkeyRuntimeState.inactive().configureSupported, false);
    expect(original, isNot(changed));
  });

  test('bindings are immutable and equality uses action order', () {
    final mutable = <ShortcutAction, HotkeyRuntimeBinding>{
      ShortcutAction.fix: const HotkeyRuntimeBinding(
        action: ShortcutAction.fix,
        desiredTrigger: 'CTRL+F',
      ),
      ShortcutAction.showOverlay: const HotkeyRuntimeBinding(
        action: ShortcutAction.showOverlay,
        desiredTrigger: 'CTRL+O',
      ),
    };
    final state = HotkeyRuntimeState(
      phase: HotkeyRuntimePhase.active,
      portalVersion: 2,
      bindings: mutable,
    );
    mutable.clear();

    expect(state.bindings, hasLength(2));
    expect(() => state.bindings.clear(), throwsUnsupportedError);
    expect(
      state,
      HotkeyRuntimeState(
        phase: HotkeyRuntimePhase.active,
        portalVersion: 2,
        bindings: {
          ShortcutAction.showOverlay:
              state.bindings[ShortcutAction.showOverlay]!,
          ShortcutAction.fix: state.bindings[ShortcutAction.fix]!,
        },
      ),
    );
  });
}
