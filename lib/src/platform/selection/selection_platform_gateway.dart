final class AtomicClipboardMutationException implements Exception {
  const AtomicClipboardMutationException({
    required this.revision,
    required this.currentText,
  });

  final int revision;
  final String currentText;
}

final class UnknownClipboardMutationException implements Exception {
  const UnknownClipboardMutationException({
    required this.code,
    required this.revision,
  });

  final String code;
  final int revision;
}

final class PlatformClipboardSnapshot {
  const PlatformClipboardSnapshot({
    required this.revision,
    required this.payload,
  });

  final int revision;
  final Object payload;
}

final class StableClipboardTextRead {
  const StableClipboardTextRead({
    required this.text,
    required this.revision,
    required this.ownerProcessId,
  });

  final String text;
  final int revision;
  final int ownerProcessId;
}

final class ClipboardTransactionException implements Exception {
  const ClipboardTransactionException({
    required this.code,
    required this.retryable,
  });

  final String code;
  final bool retryable;
}

abstract interface class SelectionPlatformGateway {
  Future<String> getSelectedText(int targetHandle);

  Future<void> replaceSelectedText(int targetHandle, String newText);

  Future<int> getForegroundWindow();

  Future<int> getWindowProcessId(int handle);

  int getOriginalForegroundWindow();

  Future<int> getClipboardRevision();

  Future<bool> isWindowValid(int handle);

  Future<bool> focusWindow(int handle);

  Future<bool> supportsLosslessTextClipboardSnapshot();

  Future<bool> isClipboardOwnedByTarget(int handle);

  bool supportsAtomicTextClipboardTransactions() => false;

  Future<int?> writeClipboardTextIfRevision(
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) =>
      Future<int?>.value(null);
}

abstract interface class NativeClipboardSnapshotGateway {
  Future<bool> supportsNativeClipboardSnapshots();

  Future<PlatformClipboardSnapshot> captureNativeClipboardSnapshot();

  Future<int?> restoreNativeClipboardSnapshotIfRevision(
    Object payload, {
    required int expectedRevision,
    required String rollbackText,
  });

  Future<void> releaseNativeClipboardSnapshot(Object payload);
}

abstract interface class TargetInteractionPermissionGateway {
  Future<bool> canInteractWithTarget(int targetHandle);
}

abstract interface class StableClipboardTextGateway {
  Future<bool> supportsStableClipboardTextReads();

  Future<StableClipboardTextRead> copySelectionTextWithEvidence(
    int targetHandle,
  );
}
