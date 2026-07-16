import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_state.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_processing_repository.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';

void main() {
  group('TextReplacementController', () {
    test('surfaces target capture failures before a transaction starts',
        () async {
      final backend = _FakeSelectionBackend();
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
      );

      await controller.reportTriggerFailure(
        action: TextAction.fix,
        diagnosticCode: 'selection_target_capture_failed',
      );

      expect(controller.state.stage, TextReplacementStage.failed);
      expect(controller.state.action, TextAction.fix);
      expect(
        controller.state.failureCode,
        'selection_target_capture_failed',
      );
      expect(backend.calls, isEmpty);
      await controller.close();
    });

    test('runs the transaction and restores the original clipboard', () async {
      final backend = _FakeSelectionBackend();
      final repository = _FakeProcessingRepository(result: 'Improved text');
      final controller = _controller(backend, repository);

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completed);
      expect(controller.state.stage, TextReplacementStage.completed);
      expect(repository.receivedText, 'Selected text');
      expect(repository.receivedAction, TextAction.rewrite);
      expect(backend.replacementText, 'Improved text');
      expect(backend.restoreExpectedRevision, 3);
      expect(
        backend.calls,
        containsAllInOrder([
          'captureTarget',
          'snapshotClipboard',
          'copySelection',
          'isSameTarget',
          'focus',
          'isSameTarget',
          'stageReplacement',
          'commitReplacement',
          'restoreClipboard',
        ]),
      );
      await controller.close();
    });

    test('supports opaque snapshots and stages rollback from selected text',
        () async {
      final token = Object();
      final backend = _FakeSelectionBackend(snapshotData: token);
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      expect(
        await controller.run(TextAction.rewrite),
        TextReplacementOutcome.completed,
      );
      expect(backend.rollbackText, 'Selected text');
      expect(backend.releasedSnapshots, [token]);
      await controller.close();
    });

    test('releases a snapshot when copy fails before clipboard ownership',
        () async {
      final token = Object();
      final backend = _FakeSelectionBackend(
        snapshotData: token,
        copyFailure: const SelectionBackendException(
          kind: SelectionFailureKind.staleCopy,
          diagnosticCode: 'selection_copy_stale',
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.failed,
      );
      expect(backend.releasedSnapshots, [token]);
      await controller.close();
    });

    test('releases a snapshot after cancellation immediately after capture',
        () async {
      final token = Object();
      late TextReplacementController controller;
      final backend = _FakeSelectionBackend(
        snapshotData: token,
        onSnapshot: () => controller.cancel(),
      );
      controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.cancelled,
      );
      expect(backend.releasedSnapshots, [token]);
      await controller.close();
    });

    test('reports a typed native snapshot release failure as a warning',
        () async {
      final backend = _FakeSelectionBackend(
        snapshotReleaseFailure: const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'native_snapshot_release_busy',
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.completedWithWarning,
      );
      expect(controller.state.failureCode, 'native_snapshot_release_busy');
      expect(
        controller.state.clipboardRestoreFailureCode,
        'native_snapshot_release_busy',
      );
      await controller.close();
    });

    test('preserves an existing warning when typed snapshot release fails',
        () async {
      final backend = _FakeSelectionBackend(
        commitVerification: CommitVerification.unverified,
        snapshotReleaseFailure: const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'native_snapshot_release_busy',
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.completedWithWarning,
      );
      expect(controller.state.failureCode, 'selection_commit_unverified');
      expect(
        controller.state.clipboardRestoreFailureCode,
        'native_snapshot_release_busy',
      );
      await controller.close();
    });

    test('maps an unexpected native snapshot release failure safely', () async {
      final backend = _FakeSelectionBackend(
        commitVerification: CommitVerification.unverified,
        snapshotReleaseFailure: StateError('private native failure'),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.completedWithWarning,
      );
      expect(
        controller.state.failureCode,
        'selection_commit_unverified',
      );
      expect(
        controller.state.clipboardRestoreFailureCode,
        'clipboard_snapshot_release_failed',
      );
      await controller.close();
    });

    test('fails safely when copy never produces a fresh revision', () async {
      final backend = _FakeSelectionBackend(
        copyFailure: const SelectionBackendException(
          kind: SelectionFailureKind.staleCopy,
          diagnosticCode: 'selection_copy_stale',
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
        copyAttempts: 2,
      );

      final outcome = await controller.run(TextAction.fix);

      expect(outcome, TextReplacementOutcome.failed);
      expect(controller.state.stage, TextReplacementStage.failed);
      expect(controller.state.failureCode, 'selection_copy_stale');
      expect(backend.calls, isNot(contains('stageReplacement')));
      expect(backend.calls, isNot(contains('restoreClipboard')));
      await controller.close();
    });

    test('restores clipboard owned by a copy operation that then fails',
        () async {
      final backend = _FakeSelectionBackend(
        copyFailure: const SelectionBackendException(
          kind: SelectionFailureKind.staleCopy,
          diagnosticCode: 'selection_copy_stale',
          ownedClipboardRevision: 2,
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
      );

      final outcome = await controller.run(TextAction.fix);

      expect(outcome, TextReplacementOutcome.failed);
      expect(backend.restoreExpectedRevision, 2);
      await controller.close();
    });

    test('refuses to commit when the original target changed', () async {
      final backend = _FakeSelectionBackend(
        sameTargetResults: [false],
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.failed);
      expect(controller.state.failureCode, 'selection_target_changed');
      expect(backend.calls, isNot(contains('stageReplacement')));
      expect(backend.restoreExpectedRevision, 2);
      await controller.close();
    });

    test('maps processing failures to safe diagnostics', () async {
      final backend = _FakeSelectionBackend();
      final controller = _controller(
        backend,
        _FakeProcessingRepository(
          result: 'unused',
          failure: const TextProcessingException(
            kind: TextProcessingFailureKind.timeout,
            diagnosticCode: 'transform_timeout',
          ),
        ),
      );

      final outcome = await controller.run(TextAction.fix);

      expect(outcome, TextReplacementOutcome.failed);
      expect(controller.state.failureCode, 'transform_timeout');
      expect(backend.restoreExpectedRevision, 2);
      await controller.close();
    });

    test('UIA read failure path never restores an unowned clipboard', () async {
      final backend = _FakeSelectionBackend(copyOwnedRevision: null);
      final controller = _controller(
        backend,
        _FakeProcessingRepository(
          result: 'unused',
          failure: const TextProcessingException(
            kind: TextProcessingFailureKind.timeout,
            diagnosticCode: 'transform_timeout',
          ),
        ),
      );

      final outcome = await controller.run(TextAction.fix);

      expect(outcome, TextReplacementOutcome.failed);
      expect(backend.calls, isNot(contains('restoreClipboard')));
      expect(backend.calls, contains('releaseTarget'));
      expect(backend.restoreExpectedRevision, isNull);
      await controller.close();
    });

    test('preserves a secondary clipboard cleanup failure diagnostic',
        () async {
      final backend = _FakeSelectionBackend(
        restoreFailure: const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'clipboard_restore_busy',
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(
          result: 'unused',
          failure: const TextProcessingException(
            kind: TextProcessingFailureKind.timeout,
            diagnosticCode: 'transform_timeout',
          ),
        ),
      );

      final outcome = await controller.run(TextAction.fix);

      expect(outcome, TextReplacementOutcome.failed);
      expect(controller.state.failureCode, 'transform_timeout');
      expect(
        controller.state.clipboardRestoreFailureCode,
        'clipboard_restore_busy',
      );
      await controller.close();
    });

    test('preserves newer external clipboard data', () async {
      final backend = _FakeSelectionBackend(
        restoreResult: ClipboardRestoreResult.skippedExternalChange,
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completed);
      expect(controller.state.clipboardRestoreSkipped, isTrue);
      await controller.close();
    });

    test('reports a committed result with a restore warning', () async {
      final backend = _FakeSelectionBackend(
        restoreFailure: const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'clipboard_restore_busy',
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completedWithWarning);
      expect(
        controller.state.stage,
        TextReplacementStage.completedWithWarning,
      );
      expect(controller.state.failureCode, 'clipboard_restore_busy');
      await controller.close();
    });

    test('maps an unexpected restore failure without retrying commit',
        () async {
      final backend = _FakeSelectionBackend(restoreUnexpectedFailure: true);
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completedWithWarning);
      expect(controller.state.failureCode, 'clipboard_restore_failed');
      await controller.close();
    });

    test('does not invite retry when a failed commit may have applied',
        () async {
      final backend = _FakeSelectionBackend(
        commitFailure: const SelectionBackendException(
          kind: SelectionFailureKind.injectionRejected,
          diagnosticCode: 'selection_commit_unverified',
          commitMayHaveOccurred: true,
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completedWithWarning);
      expect(controller.state.failureCode, 'selection_commit_unverified');
      expect(backend.restoreExpectedRevision, 3);
      await controller.close();
    });

    test('does not downgrade an ambiguous commit when restore also fails',
        () async {
      final backend = _FakeSelectionBackend(
        commitFailure: const SelectionBackendException(
          kind: SelectionFailureKind.injectionRejected,
          diagnosticCode: 'selection_commit_maybe_applied',
          commitMayHaveOccurred: true,
        ),
        restoreFailure: const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'clipboard_restore_busy',
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completedWithWarning);
      expect(controller.state.failureCode, 'selection_commit_maybe_applied');
      await controller.close();
    });

    test('reports an unverified commit as a non-retryable warning', () async {
      final backend = _FakeSelectionBackend(
        commitVerification: CommitVerification.unverified,
        restoreResult: ClipboardRestoreResult.skippedExternalChange,
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completedWithWarning);
      expect(controller.state.failureCode, 'selection_commit_unverified');
      await controller.close();
    });

    test('preserves an unverified commit across an unexpected restore failure',
        () async {
      final backend = _FakeSelectionBackend(
        commitVerification: CommitVerification.unverified,
        restoreUnexpectedFailure: true,
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completedWithWarning);
      expect(controller.state.failureCode, 'selection_commit_unverified');
      await controller.close();
    });

    test('cancellation after staging prevents commit and restores ownership',
        () async {
      late TextReplacementController controller;
      final backend = _FakeSelectionBackend(
        onStage: () => controller.cancel(),
      );
      controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.cancelled);
      expect(backend.calls, isNot(contains('commitReplacement')));
      expect(backend.restoreExpectedRevision, 3);
      await controller.close();
    });

    test('cancellation during commit never reports a safe cancelled result',
        () async {
      late TextReplacementController controller;
      final backend = _FakeSelectionBackend(
        onCommit: () => controller.cancel(),
      );
      controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.completedWithWarning);
      expect(
        controller.state.failureCode,
        'selection_commit_completed_after_cancel',
      );
      await controller.close();
    });

    test('restores clipboard owned by staging when staging then fails',
        () async {
      final backend = _FakeSelectionBackend(
        stageFailure: const SelectionBackendException(
          kind: SelectionFailureKind.clipboardBusy,
          diagnosticCode: 'selection_stage_failed',
          ownedClipboardRevision: 3,
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final outcome = await controller.run(TextAction.rewrite);

      expect(outcome, TextReplacementOutcome.failed);
      expect(backend.restoreExpectedRevision, 3);
      await controller.close();
    });

    test('rejects overlapping work and supports cancellation', () async {
      final captureCompleter = Completer<SelectionTarget>();
      final backend = _FakeSelectionBackend(
        captureCompleter: captureCompleter,
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
      );

      final firstRun = controller.run(TextAction.rewrite);
      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.busy,
      );

      controller.cancel();
      captureCompleter.complete(const SelectionTarget('target'));

      expect(await firstRun, TextReplacementOutcome.cancelled);
      expect(controller.state.stage, TextReplacementStage.cancelled);
      controller.reset();
      expect(controller.state.stage, TextReplacementStage.idle);
      await controller.close();
    });

    test('cancellation during snapshot never proceeds to copying', () async {
      late TextReplacementController controller;
      final backend = _FakeSelectionBackend(
        onSnapshot: () => controller.cancel(),
      );
      controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
      );

      final outcome = await controller.run(TextAction.fix);

      expect(outcome, TextReplacementOutcome.cancelled);
      expect(backend.calls, isNot(contains('copySelection')));
      await controller.close();
    });

    test('releases owned resources when closed', () async {
      var disposed = false;
      final controller = _controller(
        _FakeSelectionBackend(),
        _FakeProcessingRepository(result: 'unused'),
        onDispose: () => disposed = true,
      );

      await controller.close();

      expect(disposed, isTrue);
    });

    test('keeps transformed clipboard data after a successful transaction',
        () async {
      final backend = _FakeSelectionBackend();
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 0,
            restoreOriginalClipboard: false,
            defaultAction: TextAction.rewrite,
          ),
        ),
      );

      expect(
        await controller.run(TextAction.rewrite),
        TextReplacementOutcome.completed,
      );
      expect(backend.restoreOriginal, isFalse);
      await controller.close();
    });

    test('restores original clipboard on failure even under keep policy',
        () async {
      final backend = _FakeSelectionBackend();
      final controller = _controller(
        backend,
        _FakeProcessingRepository(
          result: 'unused',
          failure: const TextProcessingException(
            kind: TextProcessingFailureKind.network,
            diagnosticCode: 'transform_network_error',
          ),
        ),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 0,
            restoreOriginalClipboard: false,
            defaultAction: TextAction.fix,
          ),
        ),
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.failed,
      );
      expect(backend.restoreOriginal, isTrue);
      await controller.close();
    });

    test('uses one immutable policy snapshot for the entire transaction',
        () async {
      final initial = const TextAssistantRuntimePolicy(
        requestTimeout: Duration(seconds: 5),
        retryAttempts: 0,
        restoreOriginalClipboard: true,
        defaultAction: TextAction.rewrite,
      );
      final provider = MutableTextAssistantRuntimePolicyProvider(
        initial: initial,
      );
      final backend = _FakeSelectionBackend(
        onSnapshot: () => provider.replace(
          const TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 30),
            retryAttempts: 8,
            restoreOriginalClipboard: false,
            defaultAction: TextAction.fix,
          ),
        ),
      );
      final repository = _FakeProcessingRepository(result: 'Improved text');
      final controller = _controller(
        backend,
        repository,
        policyProvider: provider,
      );

      expect(
        await controller.run(TextAction.rewrite),
        TextReplacementOutcome.completed,
      );
      expect(repository.receivedPolicy, same(initial));
      expect(backend.restoreOriginal, isTrue);
      await controller.close();
    });

    test('keep policy applies to an unverified committed replacement',
        () async {
      final backend = _FakeSelectionBackend(
        commitVerification: CommitVerification.unverified,
        restoreResult: ClipboardRestoreResult.skippedExternalChange,
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Improved text'),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 0,
            restoreOriginalClipboard: false,
            defaultAction: TextAction.rewrite,
          ),
        ),
      );

      expect(
        await controller.run(TextAction.rewrite),
        TextReplacementOutcome.completedWithWarning,
      );
      expect(backend.restoreOriginal, isFalse);
      expect(controller.state.clipboardRestoreSkipped, isTrue);
      await controller.close();
    });

    test('records exactly one metadata-only event when consent is stable',
        () async {
      final recorder = _FakeActivityRecorder();
      final times = [
        DateTime.utc(2026, 7, 13, 12, 34, 56),
        DateTime.utc(2026, 7, 13, 12, 34, 59),
      ];
      final controller = _controller(
        _FakeSelectionBackend(),
        _FakeProcessingRepository(result: 'TRANSFORMED_SECRET'),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 0,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.rewrite,
            historyEnabled: true,
            diagnosticsEnabled: true,
            privacyConsentGeneration: 7,
          ),
        ),
        activityRecorder: recorder,
        platformFamily: PrivacyPlatformFamily.windows,
        now: () => times.removeAt(0),
      );

      expect(
        await controller.run(TextAction.rewrite),
        TextReplacementOutcome.completed,
      );

      expect(recorder.events, hasLength(1));
      expect(recorder.consent?.historyEnabled, isTrue);
      expect(recorder.consent?.diagnosticsEnabled, isTrue);
      expect(
        recorder.events.single.durationBucket,
        PrivacyDurationBucket.underFiveSeconds,
      );
      expect(recorder.events.single.occurredAt.second, 0);
      expect(
        recorder.events.single.toJson().toString(),
        isNot(contains('TRANSFORMED_SECRET')),
      );
      expect(
        recorder.events.single.toJson().toString(),
        isNot(contains('Selected text')),
      );
      await controller.close();
    });

    test('consent generation change suppresses an in-flight write', () async {
      final recorder = _FakeActivityRecorder();
      final provider = MutableTextAssistantRuntimePolicyProvider(
        initial: const TextAssistantRuntimePolicy(
          requestTimeout: Duration(seconds: 5),
          retryAttempts: 0,
          restoreOriginalClipboard: true,
          defaultAction: TextAction.fix,
          historyEnabled: true,
          diagnosticsEnabled: true,
          privacyConsentGeneration: 1,
        ),
      );
      final backend = _FakeSelectionBackend(
        onSnapshot: () => provider.replace(
          const TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 0,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.fix,
            historyEnabled: false,
            diagnosticsEnabled: false,
            privacyConsentGeneration: 2,
          ),
        ),
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'result'),
        policyProvider: provider,
        activityRecorder: recorder,
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.completed,
      );
      expect(recorder.events, isEmpty);
      await controller.close();
    });

    test('activity storage failure never changes the text outcome', () async {
      final controller = _controller(
        _FakeSelectionBackend(),
        _FakeProcessingRepository(result: 'result'),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 0,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.fix,
            diagnosticsEnabled: true,
          ),
        ),
        activityRecorder: _FakeActivityRecorder(fail: true),
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.completed,
      );
      await controller.close();
    });

    test('records warning and failed outcomes as closed metadata', () async {
      final policy = const FixedTextAssistantRuntimePolicyProvider(
        TextAssistantRuntimePolicy(
          requestTimeout: Duration(seconds: 5),
          retryAttempts: 0,
          restoreOriginalClipboard: true,
          defaultAction: TextAction.fix,
          diagnosticsEnabled: true,
        ),
      );
      final warningRecorder = _FakeActivityRecorder();
      final warningController = _controller(
        _FakeSelectionBackend(
          commitVerification: CommitVerification.unverified,
        ),
        _FakeProcessingRepository(result: 'result'),
        policyProvider: policy,
        activityRecorder: warningRecorder,
      );
      expect(
        await warningController.run(TextAction.fix),
        TextReplacementOutcome.completedWithWarning,
      );
      expect(
        warningRecorder.events.single.outcome,
        PrivacyActivityOutcome.completedWithWarning,
      );
      await warningController.close();

      final failedRecorder = _FakeActivityRecorder();
      final failedController = _controller(
        _FakeSelectionBackend(),
        _FakeProcessingRepository(
          result: 'unused',
          failure: const TextProcessingException(
            kind: TextProcessingFailureKind.timeout,
            diagnosticCode: 'transform_timeout',
          ),
        ),
        policyProvider: policy,
        activityRecorder: failedRecorder,
      );
      expect(
        await failedController.run(TextAction.fix),
        TextReplacementOutcome.failed,
      );
      expect(
        failedRecorder.events.single.outcome,
        PrivacyActivityOutcome.failed,
      );
      await failedController.close();
    });

    test('records cancellation only when original consent remains active',
        () async {
      late TextReplacementController controller;
      final recorder = _FakeActivityRecorder();
      final backend = _FakeSelectionBackend(
        onSnapshot: () => controller.cancel(),
      );
      controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
        policyProvider: const FixedTextAssistantRuntimePolicyProvider(
          TextAssistantRuntimePolicy(
            requestTimeout: Duration(seconds: 5),
            retryAttempts: 0,
            restoreOriginalClipboard: true,
            defaultAction: TextAction.fix,
            historyEnabled: true,
          ),
        ),
        activityRecorder: recorder,
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.cancelled,
      );
      expect(
        recorder.events.single.outcome,
        PrivacyActivityOutcome.cancelled,
      );
      await controller.close();
    });

    test('exposes explicit clipboard recovery and returns to idle', () async {
      final backend = _FakeSelectionBackend(
        recoveryRequired: true,
        recoverySucceeds: true,
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
      );

      expect(await controller.retryClipboardRecovery(), isTrue);
      expect(backend.recoveryCalls, 1);
      expect(controller.state.stage, TextReplacementStage.idle);

      await controller.close();
    });

    test('stages a direct selection from the snapshot revision', () async {
      final backend = _FakeSelectionBackend(copyOwnedRevision: null);
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'Transformed'),
      );

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.completed,
      );
      expect(backend.stageExpectedRevision, 1);

      await controller.close();
    });

    test('failed explicit recovery remains in the manual recovery state',
        () async {
      final backend = _FakeSelectionBackend(
        recoveryRequired: true,
        recoverySucceeds: false,
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
      );

      expect(await controller.retryClipboardRecovery(), isFalse);
      expect(controller.state.stage, TextReplacementStage.failed);
      expect(
        controller.state.failureCode,
        'clipboard_recovery_manual_action_required',
      );

      await controller.close();
    });

    test('unsafe shutdown remains in the manual recovery state', () async {
      final shutdownCompleter = Completer<bool>()..complete(false);
      final backend = _FakeSelectionBackend(
        recoveryRequired: true,
        shutdownCompleter: shutdownCompleter,
      );
      final controller = _controller(
        backend,
        _FakeProcessingRepository(result: 'unused'),
      );

      expect(await controller.prepareForShutdown(), isFalse);
      expect(controller.state.stage, TextReplacementStage.failed);
      expect(
        controller.state.failureCode,
        'clipboard_recovery_manual_action_required',
      );

      backend.calls.clear();
      final outcome = await controller.run(TextAction.rewrite);
      expect(outcome, isNot(TextReplacementOutcome.busy));
      expect(backend.calls, contains('captureTarget'));

      await controller.close();
    });

    test('cancellation aborts processing before clipboard restoration',
        () async {
      final backend = _FakeSelectionBackend();
      final repository = _CancellableProcessingRepository();
      final controller = TextReplacementController(
        selectionBackend: backend,
        processingRepository: repository,
      );

      final operation = controller.run(TextAction.rewrite);
      await repository.started.future;
      controller.cancel();

      expect(await operation, TextReplacementOutcome.cancelled);
      expect(await repository.cancelled.future, isTrue);
      expect(repository.token?.isCancelled, isTrue);
      expect(backend.restoreExpectedRevision, 2);
      expect(backend.calls, contains('releaseTarget'));
      await controller.close();
    });

    test('shutdown waits for transport cancellation, not its full timeout',
        () async {
      final backend = _FakeSelectionBackend();
      final repository = _CancellableProcessingRepository();
      final controller = TextReplacementController(
        selectionBackend: backend,
        processingRepository: repository,
      );

      final operation = controller.run(TextAction.fix);
      await repository.started.future;
      final shutdown = controller.prepareForShutdown();

      expect(
        await shutdown.timeout(const Duration(seconds: 1)),
        isTrue,
      );
      expect(await operation, TextReplacementOutcome.cancelled);
      expect(await repository.cancelled.future, isTrue);
      expect(backend.restoreExpectedRevision, 2);
      await controller.close();
    });

    test('shutdown latch rejects a transaction started during the close gate',
        () async {
      final shutdownCompleter = Completer<bool>();
      final backend = _FakeSelectionBackend(
        shutdownCompleter: shutdownCompleter,
      );
      final repository = _FakeProcessingRepository(result: 'unused');
      final controller = _controller(backend, repository);

      final shutdown = controller.prepareForShutdown();
      await Future<void>.delayed(Duration.zero);

      expect(
        await controller.run(TextAction.fix),
        TextReplacementOutcome.busy,
      );
      expect(repository.receivedText, isNull);
      shutdownCompleter.complete(true);
      expect(await shutdown, isTrue);

      await controller.close();
    });
  });
}

TextReplacementController _controller(
  _FakeSelectionBackend backend,
  _FakeProcessingRepository repository, {
  int copyAttempts = 3,
  TextAssistantRuntimePolicyProvider policyProvider =
      const FixedTextAssistantRuntimePolicyProvider(),
  PrivacyActivityRecorder activityRecorder =
      const NoOpPrivacyActivityRecorder(),
  PrivacyPlatformFamily platformFamily = PrivacyPlatformFamily.unknown,
  DateTime Function() now = DateTime.now,
  FutureOr<void> Function()? onDispose,
}) {
  return TextReplacementController(
    selectionBackend: backend,
    processingRepository: repository,
    copyAttempts: copyAttempts,
    policyProvider: policyProvider,
    activityRecorder: activityRecorder,
    platformFamily: platformFamily,
    now: now,
    onDispose: onDispose,
  );
}

final class _FakeProcessingRepository implements TextProcessingRepository {
  _FakeProcessingRepository({required this.result, this.failure});

  final String result;
  final Object? failure;
  String? receivedText;
  TextAction? receivedAction;
  TextAssistantRuntimePolicy? receivedPolicy;

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) async {
    receivedText = text;
    receivedAction = action;
    receivedPolicy = policy;
    if (failure case final error?) {
      throw error;
    }
    return result;
  }
}

final class _CancellableProcessingRepository
    implements TextProcessingRepository {
  final Completer<void> started = Completer<void>();
  final Completer<bool> cancelled = Completer<bool>();
  TextProcessingCancellationToken? token;

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) async {
    token = cancellationToken;
    if (!started.isCompleted) started.complete();
    await cancellationToken!.whenCancelled;
    if (!cancelled.isCompleted) cancelled.complete(true);
    throw const TextProcessingException(
      kind: TextProcessingFailureKind.cancelled,
      diagnosticCode: 'transform_cancelled',
    );
  }
}

final class _FakeActivityRecorder implements PrivacyActivityRecorder {
  _FakeActivityRecorder({this.fail = false});

  final bool fail;
  final List<PrivacyActivityEvent> events = [];
  PrivacyConsent? consent;

  @override
  Future<void> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  }) async {
    if (fail) throw StateError('raw private persistence failure');
    events.add(event);
    this.consent = consent;
  }
}

final class _FakeSelectionBackend
    implements
        SelectionBackend,
        ClipboardRecoveryBackend,
        ClipboardSnapshotLifecycle,
        SelectionBackendLifecycle {
  _FakeSelectionBackend({
    List<bool> sameTargetResults = const [true, true],
    this.restoreResult = ClipboardRestoreResult.restored,
    this.captureCompleter,
    this.copyFailure,
    this.restoreFailure,
    this.commitFailure,
    this.stageFailure,
    this.commitVerification = CommitVerification.verified,
    this.onStage,
    this.onCommit,
    this.onSnapshot,
    this.restoreUnexpectedFailure = false,
    this.copyOwnedRevision = 2,
    this.recoveryRequired = false,
    this.recoverySucceeds = false,
    this.shutdownCompleter,
    this.snapshotData = 'original',
    this.snapshotReleaseFailure,
  }) : _sameTargetResults = List<bool>.of(sameTargetResults);

  final List<bool> _sameTargetResults;
  final ClipboardRestoreResult restoreResult;
  final Completer<SelectionTarget>? captureCompleter;
  final SelectionBackendException? copyFailure;
  final SelectionBackendException? restoreFailure;
  final SelectionBackendException? commitFailure;
  final SelectionBackendException? stageFailure;
  final CommitVerification commitVerification;
  final void Function()? onStage;
  final void Function()? onCommit;
  final void Function()? onSnapshot;
  final bool restoreUnexpectedFailure;
  final int? copyOwnedRevision;
  bool recoveryRequired;
  final bool recoverySucceeds;
  final Completer<bool>? shutdownCompleter;
  final Object? snapshotData;
  final Object? snapshotReleaseFailure;
  int recoveryCalls = 0;
  final List<String> calls = [];
  final List<Object?> releasedSnapshots = [];

  String? replacementText;
  int? stageExpectedRevision;
  int? restoreExpectedRevision;
  bool? restoreOriginal;
  String? rollbackText;

  @override
  bool get clipboardRecoveryRequiresManualAction => recoveryRequired;

  @override
  bool get hasPendingClipboardRecovery => recoveryRequired;

  @override
  Future<bool> retryClipboardRecovery() async {
    recoveryCalls++;
    if (recoverySucceeds) recoveryRequired = false;
    return recoverySucceeds;
  }

  @override
  Future<bool> prepareForShutdown() async {
    return shutdownCompleter?.future ?? true;
  }

  @override
  Future<SelectionTarget> captureTarget() async {
    calls.add('captureTarget');
    return captureCompleter?.future ?? const SelectionTarget('target');
  }

  @override
  void releaseTarget(SelectionTarget target) {
    calls.add('releaseTarget');
  }

  @override
  Future<CommitVerification> commitReplacement(ClipboardLease lease) async {
    calls.add('commitReplacement');
    onCommit?.call();
    if (commitFailure case final failure?) {
      throw failure;
    }
    return commitVerification;
  }

  @override
  Future<SelectionCopy> copySelection(
    SelectionTarget target,
    ClipboardSnapshot snapshot, {
    required int maxAttempts,
    required Duration retryDelay,
  }) async {
    calls.add('copySelection');
    if (copyFailure case final failure?) {
      throw failure;
    }
    return SelectionCopy(
      text: 'Selected text',
      ownedClipboardRevision: copyOwnedRevision,
    );
  }

  @override
  Future<void> focus(SelectionTarget target) async {
    calls.add('focus');
  }

  @override
  Future<bool> isSameTarget(SelectionTarget target) async {
    calls.add('isSameTarget');
    return _sameTargetResults.length > 1
        ? _sameTargetResults.removeAt(0)
        : _sameTargetResults.first;
  }

  @override
  Future<ClipboardLease> stageReplacement(
    SelectionTarget target,
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) async {
    calls.add('stageReplacement');
    replacementText = text;
    stageExpectedRevision = expectedRevision;
    this.rollbackText = rollbackText;
    onStage?.call();
    if (stageFailure case final failure?) {
      throw failure;
    }
    return ClipboardLease(target: target, clipboardRevision: 3);
  }

  @override
  Future<ClipboardRestoreResult> restoreClipboard(
    ClipboardSnapshot snapshot, {
    required int expectedRevision,
    bool restoreOriginal = true,
  }) async {
    calls.add('restoreClipboard');
    restoreExpectedRevision = expectedRevision;
    this.restoreOriginal = restoreOriginal;
    if (restoreFailure case final failure?) {
      throw failure;
    }
    if (restoreUnexpectedFailure) {
      throw StateError('unexpected restore failure');
    }
    return restoreResult;
  }

  @override
  Future<ClipboardSnapshot> snapshotClipboard() async {
    calls.add('snapshotClipboard');
    onSnapshot?.call();
    return ClipboardSnapshot(revision: 1, nativeData: snapshotData);
  }

  @override
  Future<void> releaseClipboardSnapshot(ClipboardSnapshot snapshot) async {
    calls.add('releaseClipboardSnapshot');
    if (snapshotReleaseFailure case final failure?) throw failure;
    releasedSnapshots.add(snapshot.nativeData);
  }
}
