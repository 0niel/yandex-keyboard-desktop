import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';

final class DirectSelectionTarget {
  const DirectSelectionTarget({
    required this.windowHandle,
    required this.processId,
  });

  final int windowHandle;
  final int processId;

  @override
  bool operator ==(Object other) =>
      other is DirectSelectionTarget &&
      other.windowHandle == windowHandle &&
      other.processId == processId;

  @override
  int get hashCode => Object.hash(windowHandle, processId);
}

sealed class DirectSelectionRead {
  const DirectSelectionRead();
}

final class DirectSelectionSuccess extends DirectSelectionRead {
  const DirectSelectionSuccess(this.text);

  final String text;
}

final class DirectSelectionUnavailable extends DirectSelectionRead {
  const DirectSelectionUnavailable(
    this.diagnosticCode, {
    this.targetIdentityCaptured = false,
  });

  final String diagnosticCode;
  final bool targetIdentityCaptured;
}

final class DirectSelectionRejected extends DirectSelectionRead {
  const DirectSelectionRejected({
    required this.kind,
    required this.diagnosticCode,
  });

  final SelectionFailureKind kind;
  final String diagnosticCode;
}

abstract interface class DirectSelectionReader {
  Future<DirectSelectionRead> readSelection(DirectSelectionTarget target);

  Future<bool> isSameTarget(DirectSelectionTarget target);

  void releaseTarget(DirectSelectionTarget target);
}
