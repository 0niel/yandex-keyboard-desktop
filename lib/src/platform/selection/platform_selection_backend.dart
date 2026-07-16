import 'dart:async';

import 'package:flutter/services.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/direct_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';

abstract interface class ClipboardTextGateway {
  Future<String> readText();

  Future<void> writeText(String text);
}

final class FlutterClipboardTextGateway implements ClipboardTextGateway {
  const FlutterClipboardTextGateway();

  @override
  Future<String> readText() async {
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  }

  @override
  Future<void> writeText(String text) {
    return Clipboard.setData(ClipboardData(text: text));
  }
}

final class PlatformSelectionBackend
    implements
        SelectionBackend,
        ClipboardRecoveryBackend,
        ClipboardSnapshotLifecycle,
        SelectionBackendLifecycle {
  PlatformSelectionBackend({
    required SelectionPlatformGateway platform,
    ClipboardTextGateway clipboard = const FlutterClipboardTextGateway(),
    DirectSelectionReader? directSelectionReader,
    this.clipboardRecoveryDelay = const Duration(milliseconds: 100),
    this.maxAutomaticClipboardRecoveryAttempts = 8,
  })  : assert(maxAutomaticClipboardRecoveryAttempts > 0),
        _platform = platform,
        _clipboard = clipboard,
        _directSelectionReader = directSelectionReader;

  final SelectionPlatformGateway _platform;
  final ClipboardTextGateway _clipboard;
  final DirectSelectionReader? _directSelectionReader;
  final Duration clipboardRecoveryDelay;
  final int maxAutomaticClipboardRecoveryAttempts;
  final Map<int, String> _ownedClipboardText = {};
  final Set<DirectSelectionTarget> _directTargets = {};
  final Map<PlatformClipboardSnapshot, NativeClipboardSnapshotGateway>
      _activeNativeSnapshots = {};
  _PendingClipboardRecovery? _pendingClipboardRecovery;
  Future<void>? _clipboardRecoveryTask;
  Completer<void>? _recoveryDelayWakeup;
  bool _disposed = false;
  bool _shutdownRequested = false;

  @override
  bool get hasPendingClipboardRecovery =>
      _pendingClipboardRecovery != null || _activeNativeSnapshots.isNotEmpty;

  @override
  bool get clipboardRecoveryRequiresManualAction =>
      _pendingClipboardRecovery?.requiresManualAction ??
      _activeNativeSnapshots.isNotEmpty;

  @override
  Future<SelectionTarget> captureTarget() async {
    if (_disposed) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.unsupported,
        diagnosticCode: 'selection_backend_disposed',
      );
    }
    final recovery = _pendingClipboardRecovery;
    if (recovery != null) {
      throw SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: recovery.requiresManualAction
            ? 'clipboard_recovery_manual_action_required'
            : 'clipboard_recovery_pending',
      );
    }
    if (_activeNativeSnapshots.isNotEmpty &&
        !await _releaseAllNativeSnapshots()) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'clipboard_snapshot_cleanup_pending',
      );
    }
    _releaseDirectTargets();
    final handle = _platform.getOriginalForegroundWindow();
    final processId = await _platform.getWindowProcessId(handle);
    if (handle == 0 ||
        processId == 0 ||
        !await _platform.isWindowValid(handle)) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.unsupported,
        diagnosticCode: 'selection_target_unavailable',
      );
    }
    return SelectionTarget('$handle:$processId');
  }

  @override
  void releaseTarget(SelectionTarget target) {
    if (_pendingClipboardRecovery == null) {
      _ownedClipboardText.clear();
    }
    final identity = _parseTarget(target);
    if (identity == null) return;
    final directTarget = DirectSelectionTarget(
      windowHandle: identity.handle,
      processId: identity.processId,
    );
    _directSelectionReader?.releaseTarget(directTarget);
    _directTargets.remove(directTarget);
  }

  @override
  Future<ClipboardSnapshot> snapshotClipboard() async {
    final nativeGateway = _platform;
    if (nativeGateway is NativeClipboardSnapshotGateway) {
      final snapshots = nativeGateway as NativeClipboardSnapshotGateway;
      if (!await snapshots.supportsNativeClipboardSnapshots()) {
        return _snapshotTextClipboard();
      }
      try {
        final native = await snapshots.captureNativeClipboardSnapshot();
        _activeNativeSnapshots[native] = snapshots;
        return ClipboardSnapshot(
          revision: native.revision,
          nativeData: native,
        );
      } on ClipboardTransactionException catch (error) {
        throw SelectionBackendException(
          kind: error.retryable
              ? SelectionFailureKind.clipboardBusy
              : SelectionFailureKind.unsupported,
          diagnosticCode: error.code,
        );
      }
    }
    return _snapshotTextClipboard();
  }

  Future<ClipboardSnapshot> _snapshotTextClipboard() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final before = await _platform.getClipboardRevision();
      if (!await _platform.supportsLosslessTextClipboardSnapshot()) {
        final afterCapability = await _platform.getClipboardRevision();
        if (before == afterCapability) {
          throw const SelectionBackendException(
            kind: SelectionFailureKind.unsupported,
            diagnosticCode: 'clipboard_lossless_snapshot_unavailable',
          );
        }
        continue;
      }
      final text = await _clipboard.readText();
      final after = await _platform.getClipboardRevision();
      if (before == after) {
        return ClipboardSnapshot(revision: after, nativeData: text);
      }
    }
    throw const SelectionBackendException(
      kind: SelectionFailureKind.clipboardBusy,
      diagnosticCode: 'clipboard_snapshot_unstable',
    );
  }

  @override
  Future<SelectionCopy> copySelection(
    SelectionTarget target,
    ClipboardSnapshot snapshot, {
    required int maxAttempts,
    required Duration retryDelay,
  }) async {
    final identity = _parseTarget(target);
    if (identity == null || !await _matchesTarget(identity)) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.unsupported,
        diagnosticCode: 'selection_target_unavailable',
      );
    }
    final permissionGateway = _platform;
    if (permissionGateway is TargetInteractionPermissionGateway) {
      final permissions =
          permissionGateway as TargetInteractionPermissionGateway;
      final permitted = await permissions.canInteractWithTarget(
        identity.handle,
      );
      if (!permitted) {
        throw const SelectionBackendException(
          kind: SelectionFailureKind.permissionDenied,
          diagnosticCode: 'selection_target_higher_integrity',
        );
      }
    }
    final directTarget = DirectSelectionTarget(
      windowHandle: identity.handle,
      processId: identity.processId,
    );
    final directReader = _directSelectionReader;
    if (directReader != null) {
      if (!await _platform.focusWindow(identity.handle) ||
          !await _matchesTarget(identity) ||
          await _platform.getForegroundWindow() != identity.handle) {
        throw const SelectionBackendException(
          kind: SelectionFailureKind.targetChanged,
          diagnosticCode: 'selection_focus_not_restored_before_read',
        );
      }
      final directRead = await directReader.readSelection(directTarget);
      switch (directRead) {
        case DirectSelectionSuccess():
          _directTargets.add(directTarget);
          return SelectionCopy(
            text: directRead.text,
            ownedClipboardRevision: null,
          );
        case DirectSelectionRejected():
          throw SelectionBackendException(
            kind: directRead.kind,
            diagnosticCode: directRead.diagnosticCode,
          );
        case DirectSelectionUnavailable():
          if (directRead.targetIdentityCaptured) {
            _directTargets.add(directTarget);
          }
          break;
      }
    }
    final stableGateway = _platform;
    StableClipboardTextGateway? stableReads;
    try {
      if (stableGateway is StableClipboardTextGateway) {
        final candidate = stableGateway as StableClipboardTextGateway;
        if (await candidate.supportsStableClipboardTextReads()) {
          stableReads = candidate;
        }
      }
    } on ClipboardTransactionException catch (error) {
      throw _selectionFailureForClipboardTransaction(error);
    }
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      StableClipboardTextRead? stableRead;
      try {
        stableRead = await stableReads?.copySelectionTextWithEvidence(
          identity.handle,
        );
      } on ClipboardTransactionException catch (error) {
        throw _selectionFailureForClipboardTransaction(error);
      }
      final text =
          stableRead?.text ?? await _platform.getSelectedText(identity.handle);
      final revision =
          stableRead?.revision ?? await _platform.getClipboardRevision();
      final isOwnedByTarget = stableRead != null
          ? stableRead.ownerProcessId == identity.processId
          : await _platform.isClipboardOwnedByTarget(identity.handle);
      final isFreshOwnedCopy =
          revision != snapshot.revision && text.isNotEmpty && isOwnedByTarget;
      if (isFreshOwnedCopy) {
        _ownedClipboardText[revision] = text;
        final exactTargetStillMatches =
            !_directTargets.contains(directTarget) ||
                await directReader?.isSameTarget(directTarget) == true;
        if (await _matchesTarget(identity) &&
            await _platform.getForegroundWindow() == identity.handle &&
            exactTargetStillMatches) {
          return SelectionCopy(
            text: text,
            ownedClipboardRevision: revision,
          );
        }
        throw SelectionBackendException(
          kind: SelectionFailureKind.targetChanged,
          diagnosticCode: 'selection_target_changed_during_copy',
          ownedClipboardRevision: revision,
        );
      }
      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
    throw const SelectionBackendException(
      kind: SelectionFailureKind.staleCopy,
      diagnosticCode: 'selection_copy_stale',
    );
  }

  @override
  Future<bool> isSameTarget(SelectionTarget target) async {
    final identity = _parseTarget(target);
    if (identity == null || !await _matchesTarget(identity)) {
      return false;
    }
    final directTarget = DirectSelectionTarget(
      windowHandle: identity.handle,
      processId: identity.processId,
    );
    if (!_directTargets.contains(directTarget)) {
      return true;
    }
    return await _directSelectionReader?.isSameTarget(directTarget) ?? false;
  }

  @override
  Future<void> focus(SelectionTarget target) async {
    final identity = _parseTarget(target);
    if (identity == null ||
        !await _matchesTarget(identity) ||
        !await _platform.focusWindow(identity.handle) ||
        !await _matchesTarget(identity)) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.targetChanged,
        diagnosticCode: 'selection_focus_not_restored',
      );
    }
  }

  @override
  Future<ClipboardLease> stageReplacement(
    SelectionTarget target,
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) async {
    if (await _platform.getClipboardRevision() != expectedRevision) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'selection_stage_clipboard_changed',
      );
    }

    int? revision;
    final atomic = _platform.supportsAtomicTextClipboardTransactions();
    if (atomic) {
      try {
        revision = await _platform.writeClipboardTextIfRevision(
          text,
          expectedRevision: expectedRevision,
          rollbackText: rollbackText,
        );
      } on AtomicClipboardMutationException catch (error) {
        _ownedClipboardText[error.revision] = error.currentText;
        throw SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'selection_stage_native_write_failed',
          ownedClipboardRevision: error.revision,
        );
      } on ClipboardTransactionException catch (error) {
        throw _selectionFailureForClipboardTransaction(error);
      }
      if (revision == null) {
        throw const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'selection_stage_clipboard_changed',
        );
      }
    } else {
      await _clipboard.writeText(text);
      revision = await _platform.getClipboardRevision();
    }
    if (revision == expectedRevision) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'selection_stage_revision_unchanged',
      );
    }

    _ownedClipboardText[revision] = text;
    if (atomic) {
      return ClipboardLease(target: target, clipboardRevision: revision);
    }

    try {
      final stagedText = await _clipboard.readText();
      final afterRead = await _platform.getClipboardRevision();
      if (afterRead == revision && stagedText != text) {
        _ownedClipboardText[revision] = stagedText;
        throw SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'selection_stage_failed',
          ownedClipboardRevision: revision,
        );
      }
      if (afterRead != revision && stagedText == text) {
        _ownedClipboardText.remove(revision);
        revision = afterRead;
        _ownedClipboardText[revision] = text;
      } else if (stagedText != text) {
        _ownedClipboardText.remove(revision);
        throw SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'selection_stage_failed',
        );
      }
    } on SelectionBackendException {
      rethrow;
    } catch (_) {
      throw SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'selection_stage_failed',
        ownedClipboardRevision: revision,
      );
    }
    return ClipboardLease(target: target, clipboardRevision: revision);
  }

  @override
  Future<CommitVerification> commitReplacement(ClipboardLease lease) async {
    final identity = _parseTarget(lease.target);
    if (identity == null ||
        !await _matchesTarget(identity) ||
        await _platform.getForegroundWindow() != identity.handle ||
        !await isSameTarget(lease.target)) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.targetChanged,
        diagnosticCode: 'selection_target_changed_before_commit',
      );
    }
    final replacement = _ownedClipboardText[lease.clipboardRevision];
    if (replacement == null) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.injectionRejected,
        diagnosticCode: 'selection_lease_missing',
      );
    }
    final beforeRead = await _platform.getClipboardRevision();
    final afterRead = await _platform.getClipboardRevision();
    if (beforeRead != lease.clipboardRevision ||
        afterRead != lease.clipboardRevision ||
        !await _matchesTarget(identity) ||
        await _platform.getForegroundWindow() != identity.handle) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'selection_stage_lease_lost',
      );
    }
    try {
      await _platform.replaceSelectedText(identity.handle, replacement);
    } catch (_) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.injectionRejected,
        diagnosticCode: 'selection_injection_rejected',
        commitMayHaveOccurred: true,
      );
    }
    return CommitVerification.unverified;
  }

  @override
  Future<ClipboardRestoreResult> restoreClipboard(
    ClipboardSnapshot snapshot, {
    required int expectedRevision,
    bool restoreOriginal = true,
  }) async {
    try {
      final currentRevision = await _platform.getClipboardRevision();
      final expectedText = _ownedClipboardText[expectedRevision];
      if (currentRevision != expectedRevision || expectedText == null) {
        return ClipboardRestoreResult.skippedExternalChange;
      }
      final supportsAtomicTransactions =
          _platform.supportsAtomicTextClipboardTransactions();
      if (!supportsAtomicTransactions) {
        final currentText = await _clipboard.readText();
        final revisionAfterRead = await _platform.getClipboardRevision();
        if (revisionAfterRead != expectedRevision ||
            currentText != expectedText) {
          return ClipboardRestoreResult.skippedExternalChange;
        }
      }
      if (!restoreOriginal) {
        return ClipboardRestoreResult.keptReplacement;
      }
      final original = snapshot.nativeData;
      if (original is! String && original is! PlatformClipboardSnapshot) {
        throw const SelectionBackendException(
          kind: SelectionFailureKind.unsupported,
          diagnosticCode: 'clipboard_snapshot_format_unsupported',
        );
      }
      final originalData = original!;
      final usesNativeSnapshot = originalData is PlatformClipboardSnapshot;
      if (supportsAtomicTransactions || usesNativeSnapshot) {
        var recoveryRevision = expectedRevision;
        var recoveryText = expectedText;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            final restoredRevision = await _restoreOriginalIfRevision(
              originalData,
              expectedRevision: recoveryRevision,
              rollbackText: recoveryText,
            );
            if (restoredRevision == null) {
              return ClipboardRestoreResult.skippedExternalChange;
            }
            return ClipboardRestoreResult.restored;
          } on AtomicClipboardMutationException catch (error) {
            _ownedClipboardText
              ..remove(recoveryRevision)
              ..[error.revision] = error.currentText;
            recoveryRevision = error.revision;
            recoveryText = error.currentText;
            if (attempt == 2) {
              _scheduleClipboardRecovery(
                originalData: originalData,
                expectedRevision: error.revision,
                currentText: error.currentText,
              );
              throw SelectionBackendException(
                kind: SelectionFailureKind.clipboardBusy,
                diagnosticCode: 'clipboard_restore_native_write_failed',
                ownedClipboardRevision: error.revision,
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          } on UnknownClipboardMutationException catch (error) {
            _ownedClipboardText
              ..remove(recoveryRevision)
              ..remove(error.revision);
            throw SelectionBackendException(
              kind: SelectionFailureKind.clipboardBusy,
              diagnosticCode: error.code,
              commitMayHaveOccurred: true,
            );
          } on ClipboardTransactionException catch (error) {
            if (!error.retryable || attempt == 2) {
              _scheduleClipboardRecovery(
                originalData: originalData,
                expectedRevision: recoveryRevision,
                currentText: recoveryText,
                startAutomatically: error.retryable,
              );
              throw SelectionBackendException(
                kind: SelectionFailureKind.clipboardBusy,
                diagnosticCode: 'clipboard_restore_native_write_failed',
                ownedClipboardRevision: recoveryRevision,
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          } catch (_) {
            _scheduleClipboardRecovery(
              originalData: originalData,
              expectedRevision: recoveryRevision,
              currentText: recoveryText,
              startAutomatically: false,
            );
            throw SelectionBackendException(
              kind: SelectionFailureKind.clipboardBusy,
              diagnosticCode: 'clipboard_restore_native_write_failed',
              ownedClipboardRevision: recoveryRevision,
            );
          }
        }
      } else {
        if (await _platform.getClipboardRevision() != expectedRevision) {
          return ClipboardRestoreResult.skippedExternalChange;
        }
        if (originalData is! String) {
          throw const SelectionBackendException(
            kind: SelectionFailureKind.unsupported,
            diagnosticCode: 'clipboard_snapshot_format_unsupported',
          );
        }
        await _clipboard.writeText(originalData);
      }
      return ClipboardRestoreResult.restored;
    } finally {
      if (_pendingClipboardRecovery == null) {
        _ownedClipboardText.clear();
        await _tryReleaseNativeSnapshot(snapshot.nativeData);
      }
      _releaseDirectTargets();
    }
  }

  Future<int?> _restoreOriginalIfRevision(
    Object original, {
    required int expectedRevision,
    required String rollbackText,
  }) {
    if (original is PlatformClipboardSnapshot) {
      final nativeGateway = _platform;
      if (nativeGateway is! NativeClipboardSnapshotGateway) {
        return Future<int?>.error(
          const ClipboardTransactionException(
            code: 'native_clipboard_snapshot_gateway_unavailable',
            retryable: false,
          ),
        );
      }
      final snapshots = nativeGateway as NativeClipboardSnapshotGateway;
      return snapshots.restoreNativeClipboardSnapshotIfRevision(
        original.payload,
        expectedRevision: expectedRevision,
        rollbackText: rollbackText,
      );
    }
    if (original is String) {
      return _platform.writeClipboardTextIfRevision(
        original,
        expectedRevision: expectedRevision,
        rollbackText: rollbackText,
      );
    }
    return Future<int?>.error(
      const ClipboardTransactionException(
        code: 'clipboard_snapshot_format_unsupported',
        retryable: false,
      ),
    );
  }

  @override
  Future<void> releaseClipboardSnapshot(ClipboardSnapshot snapshot) async {
    if (identical(
        _pendingClipboardRecovery?.originalData, snapshot.nativeData)) {
      return;
    }
    if (!await _tryReleaseNativeSnapshot(snapshot.nativeData)) {
      throw const SelectionBackendException(
        kind: SelectionFailureKind.clipboardBusy,
        diagnosticCode: 'clipboard_snapshot_release_failed',
      );
    }
  }

  Future<bool> _tryReleaseNativeSnapshot(Object? original) async {
    if (original is! PlatformClipboardSnapshot) return true;
    final snapshots = _activeNativeSnapshots[original];
    if (snapshots == null) return true;
    try {
      await snapshots.releaseNativeClipboardSnapshot(original.payload);
      _activeNativeSnapshots.remove(original);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _releaseAllNativeSnapshots() async {
    var releasedAll = true;
    for (final snapshot in _activeNativeSnapshots.keys.toList()) {
      releasedAll = await _tryReleaseNativeSnapshot(snapshot) && releasedAll;
    }
    return releasedAll;
  }

  SelectionBackendException _selectionFailureForClipboardTransaction(
    ClipboardTransactionException error,
  ) =>
      SelectionBackendException(
        kind: error.retryable
            ? SelectionFailureKind.clipboardBusy
            : SelectionFailureKind.unsupported,
        diagnosticCode: error.code,
      );

  void _scheduleClipboardRecovery({
    required Object originalData,
    required int expectedRevision,
    required String currentText,
    bool startAutomatically = true,
  }) {
    final recovery = _PendingClipboardRecovery(
      originalData: originalData,
      expectedRevision: expectedRevision,
      currentText: currentText,
    );
    recovery.requiresManualAction = !startAutomatically;
    _pendingClipboardRecovery = recovery;
    _ownedClipboardText[expectedRevision] = currentText;
    if (startAutomatically) _startClipboardRecovery();
  }

  void _startClipboardRecovery() {
    _clipboardRecoveryTask ??= _recoverClipboard().whenComplete(() {
      _clipboardRecoveryTask = null;
    });
  }

  @override
  Future<bool> retryClipboardRecovery() async {
    if (_disposed) return false;
    final runningTask = _clipboardRecoveryTask;
    if (runningTask != null) await runningTask;
    final recovery = _pendingClipboardRecovery;
    if (recovery == null) {
      return _activeNativeSnapshots.isNotEmpty &&
          await _releaseAllNativeSnapshots();
    }
    if (!recovery.requiresManualAction) return false;
    recovery
      ..requiresManualAction = false
      ..automaticAttempts = 0;
    _startClipboardRecovery();
    await _clipboardRecoveryTask;
    return _pendingClipboardRecovery == null &&
        await _releaseAllNativeSnapshots();
  }

  Future<void> _recoverClipboard() async {
    while (true) {
      final recovery = _pendingClipboardRecovery;
      if (recovery == null || recovery.requiresManualAction || _disposed) {
        return;
      }
      await _waitForRecoveryDelay(_recoveryDelay(recovery.automaticAttempts));
      if (!identical(recovery, _pendingClipboardRecovery)) continue;
      if (_shutdownRequested) return;
      if (await _platform.getClipboardRevision() != recovery.expectedRevision) {
        await _finishClipboardRecovery(recovery);
        return;
      }
      try {
        final revision = await _restoreOriginalIfRevision(
          recovery.originalData,
          expectedRevision: recovery.expectedRevision,
          rollbackText: recovery.currentText,
        );
        if (revision == null) {
          await _finishClipboardRecovery(recovery);
          return;
        }
        await _finishClipboardRecovery(recovery);
        return;
      } on AtomicClipboardMutationException catch (error) {
        _ownedClipboardText.remove(recovery.expectedRevision);
        recovery
          ..expectedRevision = error.revision
          ..currentText = error.currentText;
        _ownedClipboardText[error.revision] = error.currentText;
        if (!_recordAutomaticRecoveryFailure(recovery)) return;
      } on ClipboardTransactionException catch (error) {
        if (!error.retryable || !_recordAutomaticRecoveryFailure(recovery)) {
          recovery.requiresManualAction = true;
          return;
        }
      } catch (_) {
        recovery.requiresManualAction = true;
        return;
      }
    }
  }

  bool _recordAutomaticRecoveryFailure(_PendingClipboardRecovery recovery) {
    recovery.automaticAttempts++;
    if (recovery.automaticAttempts < maxAutomaticClipboardRecoveryAttempts) {
      return true;
    }
    recovery.requiresManualAction = true;
    return false;
  }

  Duration _recoveryDelay(int attempt) {
    final exponent = attempt < 0 ? 0 : (attempt > 5 ? 5 : attempt);
    final microseconds =
        (clipboardRecoveryDelay.inMicroseconds * (1 << exponent))
            .clamp(
              0,
              const Duration(seconds: 2).inMicroseconds,
            )
            .toInt();
    return Duration(microseconds: microseconds);
  }

  Future<void> _waitForRecoveryDelay(Duration delay) async {
    final wakeup = Completer<void>();
    _recoveryDelayWakeup = wakeup;
    try {
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(delay),
        wakeup.future,
      ]);
    } finally {
      if (identical(_recoveryDelayWakeup, wakeup)) {
        _recoveryDelayWakeup = null;
      }
    }
  }

  Future<void> _finishClipboardRecovery(
    _PendingClipboardRecovery recovery,
  ) async {
    if (!identical(recovery, _pendingClipboardRecovery)) return;
    _pendingClipboardRecovery = null;
    _ownedClipboardText.clear();
    await _tryReleaseNativeSnapshot(recovery.originalData);
  }

  @override
  Future<bool> prepareForShutdown() async {
    if (_disposed) return true;
    _shutdownRequested = true;
    final wakeup = _recoveryDelayWakeup;
    if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
    await _clipboardRecoveryTask;

    final recovery = _pendingClipboardRecovery;
    if (recovery != null && !await _runFinalClipboardRecovery(recovery)) {
      recovery.requiresManualAction = true;
      _shutdownRequested = false;
      return false;
    }
    if (!await _releaseAllNativeSnapshots()) {
      _shutdownRequested = false;
      return false;
    }

    _disposed = true;
    _pendingClipboardRecovery = null;
    _ownedClipboardText.clear();
    _releaseDirectTargets();
    return true;
  }

  Future<bool> _runFinalClipboardRecovery(
    _PendingClipboardRecovery recovery,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!identical(recovery, _pendingClipboardRecovery)) return true;
      if (await _platform.getClipboardRevision() != recovery.expectedRevision) {
        await _finishClipboardRecovery(recovery);
        return true;
      }
      try {
        final revision = await _restoreOriginalIfRevision(
          recovery.originalData,
          expectedRevision: recovery.expectedRevision,
          rollbackText: recovery.currentText,
        );
        if (revision == null) {
          await _finishClipboardRecovery(recovery);
          return true;
        }
        await _finishClipboardRecovery(recovery);
        return true;
      } on AtomicClipboardMutationException catch (error) {
        _ownedClipboardText.remove(recovery.expectedRevision);
        recovery
          ..expectedRevision = error.revision
          ..currentText = error.currentText;
        _ownedClipboardText[error.revision] = error.currentText;
      } on ClipboardTransactionException catch (error) {
        if (!error.retryable) return false;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  void _releaseDirectTargets() {
    for (final target in _directTargets) {
      _directSelectionReader?.releaseTarget(target);
    }
    _directTargets.clear();
  }

  ({int handle, int processId})? _parseTarget(SelectionTarget target) {
    final parts = target.id.split(':');
    if (parts.length != 2) {
      return null;
    }
    final handle = int.tryParse(parts[0]);
    final processId = int.tryParse(parts[1]);
    if (handle == null || processId == null) {
      return null;
    }
    return (handle: handle, processId: processId);
  }

  Future<bool> _matchesTarget(
    ({int handle, int processId}) identity,
  ) async {
    return identity.handle == _platform.getOriginalForegroundWindow() &&
        await _platform.isWindowValid(identity.handle) &&
        await _platform.getWindowProcessId(identity.handle) ==
            identity.processId;
  }
}

final class _PendingClipboardRecovery {
  _PendingClipboardRecovery({
    required this.originalData,
    required this.expectedRevision,
    required this.currentText,
  });

  final Object originalData;
  int expectedRevision;
  String currentText;
  int automaticAttempts = 0;
  bool requiresManualAction = false;
}
