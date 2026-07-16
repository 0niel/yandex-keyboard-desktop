import 'package:equatable/equatable.dart';
import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';

enum HotkeyRuntimePhase {
  unavailable,
  inactive,
  binding,
  active,
  revoked,
  failed,
  closed,
}

abstract interface class HotkeyRuntimeSource {
  HotkeyRuntimeState get state;

  Stream<HotkeyRuntimeState> get states;

  Future<void> configureShortcuts();
}

final class HotkeyRuntimeBinding extends Equatable {
  const HotkeyRuntimeBinding({
    required this.action,
    required this.desiredTrigger,
    this.actualTriggerDescription,
  });

  final ShortcutAction action;
  final String desiredTrigger;

  final String? actualTriggerDescription;

  @override
  List<Object?> get props => [
        action,
        desiredTrigger,
        actualTriggerDescription,
      ];
}

final class HotkeyRuntimeState extends Equatable {
  HotkeyRuntimeState({
    required this.phase,
    required this.portalVersion,
    required Map<ShortcutAction, HotkeyRuntimeBinding> bindings,
    this.generation,
    this.diagnosticCode,
  }) : bindings = Map.unmodifiable(bindings);

  factory HotkeyRuntimeState.inactive() => HotkeyRuntimeState(
        phase: HotkeyRuntimePhase.inactive,
        portalVersion: 0,
        bindings: const {},
      );

  final HotkeyRuntimePhase phase;
  final int portalVersion;
  final int? generation;
  final Map<ShortcutAction, HotkeyRuntimeBinding> bindings;
  final String? diagnosticCode;

  bool get configureSupported => portalVersion >= 2;

  HotkeyRuntimeState copyWith({
    HotkeyRuntimePhase? phase,
    int? portalVersion,
    int? generation,
    bool clearGeneration = false,
    Map<ShortcutAction, HotkeyRuntimeBinding>? bindings,
    String? diagnosticCode,
    bool clearDiagnosticCode = false,
  }) =>
      HotkeyRuntimeState(
        phase: phase ?? this.phase,
        portalVersion: portalVersion ?? this.portalVersion,
        generation: clearGeneration ? null : generation ?? this.generation,
        bindings: bindings ?? this.bindings,
        diagnosticCode:
            clearDiagnosticCode ? null : diagnosticCode ?? this.diagnosticCode,
      );

  @override
  List<Object?> get props {
    final orderedBindings = bindings.values.toList()
      ..sort((left, right) => left.action.index.compareTo(right.action.index));
    return [
      phase,
      portalVersion,
      generation,
      orderedBindings,
      diagnosticCode,
    ];
  }
}
