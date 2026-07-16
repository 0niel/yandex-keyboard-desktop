final class WindowsTargetIdentity {
  WindowsTargetIdentity({
    required this.windowHandle,
    required this.processId,
    required List<int> runtimeId,
  }) : runtimeId = List<int>.unmodifiable(runtimeId);

  final int windowHandle;
  final int processId;
  final List<int> runtimeId;

  bool hasSameControl(WindowsTargetIdentity other) =>
      windowHandle == other.windowHandle &&
      processId == other.processId &&
      _listEquals(runtimeId, other.runtimeId);

  static bool _listEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
