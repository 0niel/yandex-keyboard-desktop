import 'package:yandex_keyboard_desktop/src/features/settings/domain/key_binding.dart';

enum HotkeyRegistrationFailureKind {
  conflict,
  permissionDenied,
  unsupported,
  platformError,
}

final class HotkeyRegistrationException implements Exception {
  const HotkeyRegistrationException({
    required this.kind,
    required this.diagnosticCode,
    this.rollbackFailed = false,
    this.failedActions = const [],
    this.cause,
  });

  final HotkeyRegistrationFailureKind kind;
  final String diagnosticCode;
  final bool rollbackFailed;

  final List<ShortcutAction> failedActions;
  final Object? cause;

  @override
  String toString() => 'Hotkey registration failed: $diagnosticCode '
      '(kind: ${kind.name}, rollbackFailed: $rollbackFailed, '
      'failedActions: $failedActions, cause: $cause)';
}

abstract interface class HotkeyRegistrar {
  Future<void> replaceProfile({
    required KeyBindingProfile previous,
    required KeyBindingProfile next,
    required void Function(ShortcutAction action) onTriggered,
  });

  Future<void> unregisterAll();
}

abstract interface class HotkeyRegistrarLifecycle {
  Future<void> close();
}
