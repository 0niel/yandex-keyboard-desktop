import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_state.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_processing_repository.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';

final class TextReplacementController extends Cubit<TextReplacementState> {
  TextReplacementController({
    required SelectionBackend selectionBackend,
    required TextProcessingRepository processingRepository,
    this.copyAttempts = 8,
    this.copyRetryDelay = const Duration(milliseconds: 40),
    TextAssistantRuntimePolicyProvider policyProvider =
        const FixedTextAssistantRuntimePolicyProvider(),
    PrivacyActivityRecorder activityRecorder =
        const NoOpPrivacyActivityRecorder(),
    PrivacyPlatformFamily platformFamily = PrivacyPlatformFamily.unknown,
    DateTime Function() now = DateTime.now,
    FutureOr<void> Function()? onDispose,
  })  : assert(copyAttempts > 0),
        _selectionBackend = selectionBackend,
        _processingRepository = processingRepository,
        _policyProvider = policyProvider,
        _activityRecorder = activityRecorder,
        _platformFamily = platformFamily,
        _now = now,
        _onDispose = onDispose,
        super(const TextReplacementState());

  final SelectionBackend _selectionBackend;
  final TextProcessingRepository _processingRepository;
  final TextAssistantRuntimePolicyProvider _policyProvider;
  final PrivacyActivityRecorder _activityRecorder;
  final PrivacyPlatformFamily _platformFamily;
  final DateTime Function() _now;
  final int copyAttempts;
  final Duration copyRetryDelay;
  final FutureOr<void> Function()? _onDispose;

  bool get requiresManualPaste =>
      _selectionBackend is ManualPasteSelectionBackend;

  int _operationId = 0;
  Completer<void>? _operationSettled;
  TextProcessingCancellationToken? _activeProcessingCancellation;
  bool _shuttingDown = false;

  Future<void> reportTriggerFailure({
    TextAction? action,
    required String diagnosticCode,
  }) async {
    if (state.isBusy || _shuttingDown) return;
    final policy = _policyProvider.current;
    final occurredAt = _now().toUtc();
    emit(TextReplacementState(
      stage: TextReplacementStage.failed,
      action: action,
      failureCode: diagnosticCode,
    ));
    if (action != null) {
      await _recordPrivacyActivity(
        policy: policy,
        startedAt: occurredAt,
        action: action,
        outcome: TextReplacementOutcome.failed,
        failureCode: diagnosticCode,
        clipboardRestoreSkipped: false,
        clipboardRestoreFailureCode: null,
      );
    }
  }

  Future<TextReplacementOutcome> run(TextAction action) async {
    if (state.isBusy || _shuttingDown) {
      return TextReplacementOutcome.busy;
    }
    final operationSettled = Completer<void>();
    _operationSettled = operationSettled;
    final processingCancellation = TextProcessingCancellationToken();
    _activeProcessingCancellation = processingCancellation;

    final operationId = ++_operationId;
    final policy = _policyProvider.current;
    final startedAt = _now().toUtc();
    SelectionTarget? target;
    ClipboardSnapshot? snapshot;
    int? ownedClipboardRevision;
    var outcome = TextReplacementOutcome.failed;
    String? failureCode;
    String? clipboardRestoreFailureCode;
    var restoreSkipped = false;

    emit(TextReplacementState(
      stage: TextReplacementStage.capturing,
      action: action,
    ));

    try {
      target = await _selectionBackend.captureTarget();
      _throwIfCancelled(operationId);
      snapshot = await _selectionBackend.snapshotClipboard();
      _throwIfCancelled(operationId);

      emit(TextReplacementState(
        stage: TextReplacementStage.copying,
        action: action,
      ));
      final selectionCopy = await _selectionBackend.copySelection(
        target,
        snapshot,
        maxAttempts: copyAttempts,
        retryDelay: copyRetryDelay,
      );
      ownedClipboardRevision = selectionCopy.ownedClipboardRevision;
      _throwIfCancelled(operationId);

      emit(TextReplacementState(
        stage: TextReplacementStage.processing,
        action: action,
      ));
      final transformed = await _processingRepository.process(
        text: selectionCopy.text,
        action: action,
        policy: policy,
        cancellationToken: processingCancellation,
      );
      _throwIfCancelled(operationId);

      emit(TextReplacementState(
        stage: TextReplacementStage.validatingTarget,
        action: action,
      ));
      if (!await _selectionBackend.isSameTarget(target)) {
        throw const SelectionBackendException(
          kind: SelectionFailureKind.targetChanged,
          diagnosticCode: 'selection_target_changed',
        );
      }
      await _selectionBackend.focus(target);
      if (!await _selectionBackend.isSameTarget(target)) {
        throw const SelectionBackendException(
          kind: SelectionFailureKind.targetChanged,
          diagnosticCode: 'selection_focus_not_restored',
        );
      }
      _throwIfCancelled(operationId);

      emit(TextReplacementState(
        stage: TextReplacementStage.replacing,
        action: action,
      ));
      final lease = await _selectionBackend.stageReplacement(
        target,
        transformed,
        expectedRevision: ownedClipboardRevision ?? snapshot.revision,
        rollbackText: selectionCopy.text,
      );
      ownedClipboardRevision = lease.clipboardRevision;
      _throwIfCancelled(operationId);
      final verification = await _selectionBackend.commitReplacement(lease);
      if (verification == CommitVerification.unverified) {
        outcome = TextReplacementOutcome.completedWithWarning;
        failureCode = 'selection_commit_unverified';
      } else if (_operationId != operationId) {
        outcome = TextReplacementOutcome.completedWithWarning;
        failureCode = 'selection_commit_completed_after_cancel';
      } else {
        outcome = TextReplacementOutcome.completed;
      }
    } on _OperationCancelled {
      outcome = TextReplacementOutcome.cancelled;
    } on TextProcessingException catch (error) {
      if (error.kind == TextProcessingFailureKind.cancelled) {
        outcome = TextReplacementOutcome.cancelled;
      } else {
        failureCode = error.diagnosticCode;
      }
    } on SelectionBackendException catch (error) {
      failureCode = error.diagnosticCode;
      ownedClipboardRevision =
          error.ownedClipboardRevision ?? ownedClipboardRevision;
      if (error.commitMayHaveOccurred) {
        outcome = TextReplacementOutcome.completedWithWarning;
      }
    } catch (_) {
      failureCode = 'text_replacement_unexpected';
    } finally {
      if (snapshot != null && ownedClipboardRevision != null) {
        emit(TextReplacementState(
          stage: TextReplacementStage.restoringClipboard,
          action: action,
        ));
        try {
          final restoreResult = await _selectionBackend.restoreClipboard(
            snapshot,
            expectedRevision: ownedClipboardRevision,
            restoreOriginal:
                (!requiresManualPaste && policy.restoreOriginalClipboard) ||
                    (outcome != TextReplacementOutcome.completed &&
                        outcome != TextReplacementOutcome.completedWithWarning),
          );
          restoreSkipped =
              restoreResult == ClipboardRestoreResult.skippedExternalChange;
        } on SelectionBackendException catch (error) {
          clipboardRestoreFailureCode = error.diagnosticCode;
          outcome = outcome == TextReplacementOutcome.completed ||
                  outcome == TextReplacementOutcome.completedWithWarning
              ? TextReplacementOutcome.completedWithWarning
              : TextReplacementOutcome.failed;
          failureCode ??= error.diagnosticCode;
        } catch (_) {
          clipboardRestoreFailureCode = 'clipboard_restore_failed';
          outcome = outcome == TextReplacementOutcome.completed ||
                  outcome == TextReplacementOutcome.completedWithWarning
              ? TextReplacementOutcome.completedWithWarning
              : TextReplacementOutcome.failed;
          failureCode ??= 'clipboard_restore_failed';
        }
      }
      final snapshotToRelease = snapshot;
      final backend = _selectionBackend;
      if (snapshotToRelease != null && backend is ClipboardSnapshotLifecycle) {
        final snapshotLifecycle = backend as ClipboardSnapshotLifecycle;
        try {
          await snapshotLifecycle.releaseClipboardSnapshot(snapshotToRelease);
        } on SelectionBackendException catch (error) {
          clipboardRestoreFailureCode ??= error.diagnosticCode;
          outcome = outcome == TextReplacementOutcome.completed ||
                  outcome == TextReplacementOutcome.completedWithWarning
              ? TextReplacementOutcome.completedWithWarning
              : TextReplacementOutcome.failed;
          failureCode ??= error.diagnosticCode;
        } catch (_) {
          clipboardRestoreFailureCode ??= 'clipboard_snapshot_release_failed';
          outcome = outcome == TextReplacementOutcome.completed ||
                  outcome == TextReplacementOutcome.completedWithWarning
              ? TextReplacementOutcome.completedWithWarning
              : TextReplacementOutcome.failed;
          failureCode ??= 'clipboard_snapshot_release_failed';
        }
      }
      if (target != null) {
        _selectionBackend.releaseTarget(target);
      }
      if (_selectionBackend is ClipboardRecoveryBackend) {
        final recoveryBackend = _selectionBackend as ClipboardRecoveryBackend;
        if (recoveryBackend.hasPendingClipboardRecovery &&
            recoveryBackend.clipboardRecoveryRequiresManualAction) {
          failureCode = 'clipboard_recovery_manual_action_required';
        }
      }
    }

    switch (outcome) {
      case TextReplacementOutcome.completed:
        emit(TextReplacementState(
          stage: requiresManualPaste
              ? TextReplacementStage.awaitingManualPaste
              : TextReplacementStage.completed,
          action: action,
          clipboardRestoreSkipped: restoreSkipped,
        ));
      case TextReplacementOutcome.completedWithWarning:
        emit(TextReplacementState(
          stage: TextReplacementStage.completedWithWarning,
          action: action,
          failureCode: failureCode ?? 'clipboard_restore_failed',
          clipboardRestoreFailureCode: clipboardRestoreFailureCode,
          clipboardRestoreSkipped: restoreSkipped,
        ));
      case TextReplacementOutcome.cancelled:
        emit(TextReplacementState(
          stage: TextReplacementStage.cancelled,
          action: action,
        ));
      case TextReplacementOutcome.failed:
        emit(TextReplacementState(
          stage: TextReplacementStage.failed,
          action: action,
          failureCode: failureCode ?? 'text_replacement_failed',
          clipboardRestoreFailureCode: clipboardRestoreFailureCode,
        ));
      // coverage:ignore-start
      case TextReplacementOutcome.busy:
        throw StateError('Busy outcomes return before a transaction starts.');
      // coverage:ignore-end
    }
    await _recordPrivacyActivity(
      policy: policy,
      startedAt: startedAt,
      action: action,
      outcome: outcome,
      failureCode: failureCode,
      clipboardRestoreSkipped: restoreSkipped,
      clipboardRestoreFailureCode: clipboardRestoreFailureCode,
    );
    if (!operationSettled.isCompleted) operationSettled.complete();
    if (identical(_operationSettled, operationSettled)) {
      _operationSettled = null;
    }
    if (identical(_activeProcessingCancellation, processingCancellation)) {
      _activeProcessingCancellation = null;
    }
    return outcome;
  }

  Future<void> _recordPrivacyActivity({
    required TextAssistantRuntimePolicy policy,
    required DateTime startedAt,
    required TextAction action,
    required TextReplacementOutcome outcome,
    required String? failureCode,
    required bool clipboardRestoreSkipped,
    required String? clipboardRestoreFailureCode,
  }) async {
    if (!policy.historyEnabled && !policy.diagnosticsEnabled) return;
    final completedAt = _now().toUtc();
    final current = _policyProvider.current;
    if (current.privacyConsentGeneration != policy.privacyConsentGeneration) {
      return;
    }
    try {
      await _activityRecorder.record(
        PrivacyActivityEvent(
          occurredAt: completedAt,
          action: action,
          outcome: _privacyOutcome(outcome),
          durationBucket: privacyDurationBucket(
            completedAt.difference(startedAt),
          ),
          platformFamily: _platformFamily,
          failureCode: failureCode,
          clipboardRestoreSkipped: clipboardRestoreSkipped,
          clipboardRestoreFailureCode: clipboardRestoreFailureCode,
        ),
        consent: PrivacyConsent(
          historyEnabled: policy.historyEnabled,
          diagnosticsEnabled: policy.diagnosticsEnabled,
          generation: policy.privacyConsentGeneration,
        ),
      );
    } catch (_) {}
  }

  void cancel() {
    if (state.isBusy) {
      _operationId++;
      _activeProcessingCancellation?.cancel();
    }
  }

  void reset() {
    if (!state.isBusy) {
      emit(const TextReplacementState());
    }
  }

  Future<bool> retryClipboardRecovery() async {
    if (state.isBusy || _selectionBackend is! ClipboardRecoveryBackend) {
      return false;
    }
    final recoveryBackend = _selectionBackend as ClipboardRecoveryBackend;
    if (!recoveryBackend.clipboardRecoveryRequiresManualAction) return false;

    emit(TextReplacementState(
      stage: TextReplacementStage.restoringClipboard,
      action: state.action,
    ));
    final recovered = await recoveryBackend.retryClipboardRecovery();
    if (recovered) {
      _shuttingDown = false;
      emit(const TextReplacementState());
    } else {
      emit(TextReplacementState(
        stage: TextReplacementStage.failed,
        action: state.action,
        failureCode: 'clipboard_recovery_manual_action_required',
      ));
    }
    return recovered;
  }

  Future<bool> prepareForShutdown() async {
    _shuttingDown = true;
    cancel();
    await _operationSettled?.future;
    final backend = _selectionBackend;
    if (backend is! SelectionBackendLifecycle) return true;
    final lifecycle = backend as SelectionBackendLifecycle;
    var safeToClose = false;
    try {
      safeToClose = await lifecycle.prepareForShutdown();
    } catch (_) {
      safeToClose = false;
    }
    if (!safeToClose) {
      _shuttingDown = false;
      emit(TextReplacementState(
        stage: TextReplacementStage.failed,
        action: state.action,
        failureCode: 'clipboard_recovery_manual_action_required',
      ));
    }
    return safeToClose;
  }

  void _throwIfCancelled(int operationId) {
    if (_operationId != operationId) {
      throw const _OperationCancelled();
    }
  }

  @override
  Future<void> close() async {
    await _onDispose?.call();
    await super.close();
  }
}

PrivacyActivityOutcome _privacyOutcome(TextReplacementOutcome outcome) =>
    switch (outcome) {
      TextReplacementOutcome.completed => PrivacyActivityOutcome.completed,
      TextReplacementOutcome.completedWithWarning =>
        PrivacyActivityOutcome.completedWithWarning,
      TextReplacementOutcome.cancelled => PrivacyActivityOutcome.cancelled,
      TextReplacementOutcome.failed => PrivacyActivityOutcome.failed,
      // coverage:ignore-start
      TextReplacementOutcome.busy => throw ArgumentError.value(outcome),
      // coverage:ignore-end
    };

final class _OperationCancelled implements Exception {
  const _OperationCancelled();
}
