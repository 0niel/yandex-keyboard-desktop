import 'package:yandex_keyboard_desktop/src/platform/selection/direct_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_target_identity.dart';

enum WindowsUiaProbeStatus {
  success,
  patternUnavailable,
  accessDenied,
  passwordControl,
  targetChanged,
  noSelection,
  multipleSelection,
  selectionTooLarge,
  providerFailure,
  timeout,
}

final class WindowsUiaProbe {
  const WindowsUiaProbe({
    required this.status,
    this.identity,
    this.text,
  });

  final WindowsUiaProbeStatus status;
  final WindowsTargetIdentity? identity;
  final String? text;
}

WindowsUiaProbe decodeWindowsUiaProbeMessage(
  Map<Object?, Object?> message,
) {
  final statusName = message['status'];
  WindowsUiaProbeStatus? status;
  for (final candidate in WindowsUiaProbeStatus.values) {
    if (candidate.name == statusName) {
      status = candidate;
      break;
    }
  }
  if (status == null) {
    return const WindowsUiaProbe(
      status: WindowsUiaProbeStatus.providerFailure,
    );
  }
  WindowsTargetIdentity? identity;
  final runtimeId = message['runtimeId'];
  final windowHandle = message['windowHandle'];
  final processId = message['processId'];
  if (runtimeId is List<Object?> &&
      windowHandle is int &&
      processId is int &&
      runtimeId.every((value) => value is int)) {
    identity = WindowsTargetIdentity(
      windowHandle: windowHandle,
      processId: processId,
      runtimeId: runtimeId.cast<int>(),
    );
  }
  return WindowsUiaProbe(
    status: status,
    identity: identity,
    text: message['text'] as String?,
  );
}

abstract interface class WindowsUiaGateway {
  Future<WindowsUiaProbe> readSelection(
    DirectSelectionTarget target, {
    required int maxTextLength,
  });

  Future<WindowsUiaProbe> inspectFocusedTarget(DirectSelectionTarget target);
}
