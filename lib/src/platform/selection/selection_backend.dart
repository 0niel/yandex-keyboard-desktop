final class SelectionTarget {
  const SelectionTarget(this.id);

  final String id;
}

final class ClipboardSnapshot {
  const ClipboardSnapshot({
    required this.revision,
    required this.nativeData,
  });

  final int revision;
  final Object? nativeData;
}

final class SelectionCopy {
  const SelectionCopy({
    required this.text,
    required this.ownedClipboardRevision,
  });

  final String text;

  final int? ownedClipboardRevision;
}

final class ClipboardLease {
  const ClipboardLease({
    required this.target,
    required this.clipboardRevision,
  });

  final SelectionTarget target;
  final int clipboardRevision;
}

enum CommitVerification {
  verified,
  unverified,
}

enum ClipboardRestoreResult {
  restored,
  keptReplacement,
  skippedExternalChange,
}

enum SelectionFailureKind {
  unsupported,
  permissionDenied,
  clipboardBusy,
  staleCopy,
  targetChanged,
  injectionRejected,
}

final class SelectionBackendException implements Exception {
  const SelectionBackendException({
    required this.kind,
    required this.diagnosticCode,
    this.commitMayHaveOccurred = false,
    this.ownedClipboardRevision,
  });

  final SelectionFailureKind kind;
  final String diagnosticCode;
  final bool commitMayHaveOccurred;
  final int? ownedClipboardRevision;

  @override
  String toString() => 'SelectionBackendException($diagnosticCode)';
}

abstract interface class SelectionBackend {
  Future<SelectionTarget> captureTarget();

  void releaseTarget(SelectionTarget target);

  Future<ClipboardSnapshot> snapshotClipboard();

  Future<SelectionCopy> copySelection(
    SelectionTarget target,
    ClipboardSnapshot snapshot, {
    required int maxAttempts,
    required Duration retryDelay,
  });

  Future<bool> isSameTarget(SelectionTarget target);

  Future<void> focus(SelectionTarget target);

  Future<ClipboardLease> stageReplacement(
    SelectionTarget target,
    String text, {
    required int expectedRevision,
    required String rollbackText,
  });

  Future<CommitVerification> commitReplacement(ClipboardLease lease);

  Future<ClipboardRestoreResult> restoreClipboard(
    ClipboardSnapshot snapshot, {
    required int expectedRevision,
    bool restoreOriginal = true,
  });
}

abstract interface class ManualPasteSelectionBackend {}

abstract interface class ClipboardRecoveryBackend {
  bool get hasPendingClipboardRecovery;

  bool get clipboardRecoveryRequiresManualAction;

  Future<bool> retryClipboardRecovery();
}

abstract interface class ClipboardSnapshotLifecycle {
  Future<void> releaseClipboardSnapshot(ClipboardSnapshot snapshot);
}

abstract interface class SelectionBackendLifecycle {
  Future<bool> prepareForShutdown();
}
