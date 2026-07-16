import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_state.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_processing_repository.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/direct_selection_reader.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/platform_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';

void main() {
  test('rejects a higher-integrity target before reading selected text',
      () async {
    final platform = _FakeSelectionPlatformGateway(interactionAllowed: false);
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    await expectLater(
      backend.copySelection(
        target,
        snapshot,
        maxAttempts: 1,
        retryDelay: Duration.zero,
      ),
      throwsA(
        isA<SelectionBackendException>()
            .having(
              (error) => error.kind,
              'kind',
              SelectionFailureKind.permissionDenied,
            )
            .having(
              (error) => error.diagnosticCode,
              'code',
              'selection_target_higher_integrity',
            ),
      ),
    );
    expect(platform.copyCalls, 0);
  });

  test('opaque native snapshot bypasses Dart reads and restores through CAS',
      () async {
    final platform = _FakeSelectionPlatformGateway(
      atomicTransactions: true,
      nativeSnapshots: true,
    );
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );

    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    expect(snapshot.nativeData, isA<PlatformClipboardSnapshot>());
    expect(clipboard.readCalls, 0);

    final copy = await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: copy.ownedClipboardRevision!,
      rollbackText: copy.text,
    );

    expect(
      await backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      ClipboardRestoreResult.restored,
    );
    expect(clipboard.text, 'original');
    expect(platform.nativeRestoreCalls, 1);
    expect(platform.releasedNativeSnapshots, hasLength(1));
  });

  test('opaque snapshot is released after an external clipboard conflict',
      () async {
    final platform = _FakeSelectionPlatformGateway(
      atomicTransactions: true,
      nativeSnapshots: true,
    );
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final copy = await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: copy.ownedClipboardRevision!,
      rollbackText: copy.text,
    );
    platform.revision++;
    clipboard.text = 'external';

    expect(
      await backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      ClipboardRestoreResult.skippedExternalChange,
    );
    expect(platform.nativeRestoreCalls, 0);
    expect(platform.releasedNativeSnapshots, hasLength(1));
  });

  test('unknown native restore state is never retried or claimed as text',
      () async {
    final platform = _FakeSelectionPlatformGateway(
      atomicTransactions: true,
      nativeSnapshots: true,
    );
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final copy = await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: copy.ownedClipboardRevision!,
      rollbackText: copy.text,
    );
    platform.nativeRestorer = (_, __, ___) async {
      platform.revision++;
      throw UnknownClipboardMutationException(
        code: 'windows_clipboard_snapshot_restore_timeout',
        revision: platform.revision,
      );
    };

    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      throwsA(
        isA<SelectionBackendException>()
            .having(
              (error) => error.diagnosticCode,
              'code',
              'windows_clipboard_snapshot_restore_timeout',
            )
            .having(
              (error) => error.commitMayHaveOccurred,
              'commitMayHaveOccurred',
              isTrue,
            )
            .having(
              (error) => error.ownedClipboardRevision,
              'ownedClipboardRevision',
              isNull,
            ),
      ),
    );
    expect(backend.hasPendingClipboardRecovery, isFalse);
    expect(platform.nativeRestoreCalls, 1);
    expect(platform.nativeReleaseCalls, 1);
  });

  test('native snapshot capture failures become typed selection failures',
      () async {
    final platform = _FakeSelectionPlatformGateway(nativeSnapshots: true)
      ..nativeCaptureFailure = const ClipboardTransactionException(
        code: 'clipboard_snapshot_too_large',
        retryable: false,
      );
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );

    await expectLater(
      backend.snapshotClipboard(),
      throwsA(
        isA<SelectionBackendException>()
            .having(
              (error) => error.kind,
              'kind',
              SelectionFailureKind.unsupported,
            )
            .having(
              (error) => error.diagnosticCode,
              'diagnosticCode',
              'clipboard_snapshot_too_large',
            ),
      ),
    );
  });

  test('failed native release stays tracked and shutdown retries it', () async {
    final platform = _FakeSelectionPlatformGateway(nativeSnapshots: true)
      ..nativeReleaseFailuresRemaining = 1;
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );
    final snapshot = await backend.snapshotClipboard();

    await expectLater(
      backend.releaseClipboardSnapshot(snapshot),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'clipboard_snapshot_release_failed',
        ),
      ),
    );
    expect(backend.hasPendingClipboardRecovery, isTrue);
    expect(await backend.prepareForShutdown(), isTrue);
    expect(platform.nativeReleaseCalls, 2);
    expect(platform.releasedNativeSnapshots, hasLength(1));
  });

  test('next target capture retries orphaned native snapshot cleanup',
      () async {
    final platform = _FakeSelectionPlatformGateway(nativeSnapshots: true)
      ..nativeReleaseFailuresRemaining = 1;
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );
    final snapshot = await backend.snapshotClipboard();
    await expectLater(
      backend.releaseClipboardSnapshot(snapshot),
      throwsA(isA<SelectionBackendException>()),
    );

    expect(await backend.captureTarget(), isA<SelectionTarget>());
    expect(platform.nativeReleaseCalls, 2);
    expect(backend.hasPendingClipboardRecovery, isFalse);
  });

  test('controller cannot release a snapshot pinned by manual recovery',
      () async {
    final platform = _FakeSelectionPlatformGateway(
      atomicTransactions: true,
      nativeSnapshots: true,
      stableReads: true,
    );
    final clipboard = _FakeClipboard(platform, 'original');
    final successfulRestore = platform.nativeRestorer!;
    platform.nativeRestorer = (_, __, ___) async {
      throw const ClipboardTransactionException(
        code: 'native_restore_temporarily_unavailable',
        retryable: false,
      );
    };
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
      clipboardRecoveryDelay: Duration.zero,
    );
    final controller = TextReplacementController(
      selectionBackend: backend,
      processingRepository: const _FixedProcessingRepository('improved'),
      copyRetryDelay: Duration.zero,
    );

    expect(
      await controller.run(TextAction.fix),
      TextReplacementOutcome.completedWithWarning,
    );
    expect(backend.clipboardRecoveryRequiresManualAction, isTrue);
    expect(platform.nativeReleaseCalls, 0);

    platform.nativeRestorer = successfulRestore;
    expect(await backend.retryClipboardRecovery(), isTrue);
    expect(clipboard.text, 'original');
    expect(platform.nativeReleaseCalls, 1);
    expect(platform.releasedNativeSnapshots, hasLength(1));
    await controller.close();
  });

  test('atomic staging preserves typed pre-mutation diagnostics', () async {
    for (final retryable in <bool>[true, false]) {
      final platform = _FakeSelectionPlatformGateway(atomicTransactions: true)
        ..atomicPreMutationFailuresRemaining = 1
        ..atomicPreMutationFailureRetryable = retryable;
      final backend = PlatformSelectionBackend(
        platform: platform,
        clipboard: _FakeClipboard(platform, 'original'),
      );
      final target = await backend.captureTarget();

      await expectLater(
        backend.stageReplacement(
          target,
          'improved',
          expectedRevision: platform.revision,
          rollbackText: 'selected',
        ),
        throwsA(
          isA<SelectionBackendException>()
              .having(
                (error) => error.kind,
                'kind',
                retryable
                    ? SelectionFailureKind.clipboardBusy
                    : SelectionFailureKind.unsupported,
              )
              .having(
                (error) => error.diagnosticCode,
                'diagnosticCode',
                'test_pre_mutation_failure',
              ),
        ),
      );
    }
  });

  test('stable native copy binds text, revision, and owner PID together',
      () async {
    final platform = _FakeSelectionPlatformGateway(stableReads: true);
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    final copy = await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );

    expect(copy.text, 'selected-stable');
    expect(copy.ownedClipboardRevision, 2);
    expect(platform.stableReadCalls, 1);
    expect(platform.copyCalls, 0);
    expect(platform.ownerChecks, 0);
  });

  test('stable native copy rejects text attributed to another process',
      () async {
    final platform = _FakeSelectionPlatformGateway(
      stableReads: true,
      stableOwnerProcessId: 9001,
    );
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    await expectLater(
      backend.copySelection(
        target,
        snapshot,
        maxAttempts: 1,
        retryDelay: Duration.zero,
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_copy_stale',
        ),
      ),
    );
    expect(platform.ownerChecks, 0);
  });

  test('direct selection succeeds without taking clipboard ownership',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final reader = _FakeDirectSelectionReader(
      const DirectSelectionSuccess('selected through UIA'),
    );
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
      directSelectionReader: reader,
    );

    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final copy = await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 2,
      retryDelay: Duration.zero,
    );

    expect(copy.text, 'selected through UIA');
    expect(copy.ownedClipboardRevision, isNull);
    expect(platform.revision, snapshot.revision);
    expect(platform.copyCalls, 0);
  });

  test('direct unavailability falls back to clipboard copy exactly once',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
      directSelectionReader: _FakeDirectSelectionReader(
        const DirectSelectionUnavailable('windows_uia_pattern_unavailable'),
      ),
    );

    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final copy = await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 2,
      retryDelay: Duration.zero,
    );

    expect(copy.ownedClipboardRevision, 2);
    expect(platform.copyCalls, 1);
  });

  test('direct security rejection never falls back to clipboard copy',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
      directSelectionReader: _FakeDirectSelectionReader(
        const DirectSelectionRejected(
          kind: SelectionFailureKind.permissionDenied,
          diagnosticCode: 'windows_uia_password_control',
        ),
      ),
    );

    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    await expectLater(
      backend.copySelection(
        target,
        snapshot,
        maxAttempts: 2,
        retryDelay: Duration.zero,
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'windows_uia_password_control',
        ),
      ),
    );
    expect(platform.copyCalls, 0);
  });

  test('direct target identity participates in later validation', () async {
    final platform = _FakeSelectionPlatformGateway();
    final reader = _FakeDirectSelectionReader(
      const DirectSelectionSuccess('selected'),
    );
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
      directSelectionReader: reader,
    );

    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );

    reader.sameTarget = false;
    expect(await backend.isSameTarget(target), isFalse);
  });

  test('UIA identity still guards clipboard fallback control changes',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final reader = _FakeDirectSelectionReader(
      const DirectSelectionUnavailable(
        'windows_uia_pattern_unavailable',
        targetIdentityCaptured: true,
      ),
    );
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
      directSelectionReader: reader,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );

    reader.sameTarget = false;
    expect(await backend.isSameTarget(target), isFalse);
  });

  test('fallback copy revalidates the exact UIA control before returning text',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final reader = _FakeDirectSelectionReader(
      const DirectSelectionUnavailable(
        'windows_uia_pattern_unavailable',
        targetIdentityCaptured: true,
      ),
    );
    platform.onCopy = () => reader.sameTarget = false;
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
      directSelectionReader: reader,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    await expectLater(
      backend.copySelection(
        target,
        snapshot,
        maxAttempts: 1,
        retryDelay: Duration.zero,
      ),
      throwsA(
        isA<SelectionBackendException>()
            .having(
              (error) => error.diagnosticCode,
              'diagnosticCode',
              'selection_target_changed_during_copy',
            )
            .having(
              (error) => error.ownedClipboardRevision,
              'ownedClipboardRevision',
              2,
            ),
      ),
    );
  });

  test('direct read restores the captured window before probing UIA', () async {
    final platform = _FakeSelectionPlatformGateway()..foreground = 7;
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
      directSelectionReader: _FakeDirectSelectionReader(
        const DirectSelectionSuccess('selected'),
      ),
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );

    expect(platform.foreground, platform.original);
  });

  test('runs copy, staged paste, and compare-and-swap restore', () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );

    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final copy = await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 2,
      retryDelay: Duration.zero,
    );
    await backend.focus(target);
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );
    final verification = await backend.commitReplacement(lease);
    final restore = await backend.restoreClipboard(
      snapshot,
      expectedRevision: lease.clipboardRevision,
    );

    expect(copy.text, 'selected');
    expect(verification, CommitVerification.unverified);
    expect(platform.replacement, 'improved');
    expect(restore, ClipboardRestoreResult.restored);
    expect(clipboard.text, 'original');
    await expectLater(
      backend.commitReplacement(
        ClipboardLease(
          target: target,
          clipboardRevision: copy.ownedClipboardRevision!,
        ),
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_lease_missing',
        ),
      ),
    );
  });

  test('commits and restores across a phantom revision bump', () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    await backend.focus(target);
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );
    platform.revision++;

    final verification = await backend.commitReplacement(lease);
    final restore = await backend.restoreClipboard(
      snapshot,
      expectedRevision: lease.clipboardRevision,
    );

    expect(verification, CommitVerification.unverified);
    expect(platform.replacement, 'improved');
    expect(restore, ClipboardRestoreResult.restored);
    expect(clipboard.text, 'original');
  });

  test('a phantom bump with foreign clipboard text still loses the lease',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    await backend.focus(target);
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );
    platform.revision++;
    clipboard.text = 'external';

    await expectLater(
      backend.commitReplacement(lease),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_stage_lease_lost',
        ),
      ),
    );
    expect(platform.replacement, isNull);
  });

  test('rejects a stale copy instead of reusing clipboard contents', () async {
    final platform = _FakeSelectionPlatformGateway(copyChangesRevision: false);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    await expectLater(
      backend.copySelection(
        target,
        snapshot,
        maxAttempts: 2,
        retryDelay: Duration.zero,
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_copy_stale',
        ),
      ),
    );
  });

  test('fails closed when a lossless clipboard snapshot is unavailable',
      () async {
    final platform = _FakeSelectionPlatformGateway(losslessSnapshot: false);
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'rich clipboard'),
    );

    await expectLater(
      backend.snapshotClipboard(),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'clipboard_lossless_snapshot_unavailable',
        ),
      ),
    );
  });

  test('retries capability proof when clipboard revision changes', () async {
    final platform = _FakeSelectionPlatformGateway(
      losslessResults: [false, true],
      changeRevisionOnFirstCapabilityCheck: true,
    );
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'plain text'),
    );

    final snapshot = await backend.snapshotClipboard();

    expect(snapshot.revision, 2);
    expect(snapshot.nativeData, 'plain text');
  });

  test('does not attribute an external clipboard write to the target',
      () async {
    final platform =
        _FakeSelectionPlatformGateway(clipboardOwnedByTarget: false);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    await expectLater(
      backend.copySelection(
        target,
        snapshot,
        maxAttempts: 1,
        retryDelay: Duration.zero,
      ),
      throwsA(isA<SelectionBackendException>()),
    );
  });

  test('returns clipboard ownership when target changes during copy', () async {
    final platform =
        _FakeSelectionPlatformGateway(changeProcessIdDuringCopy: true);
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    try {
      await backend.copySelection(
        target,
        snapshot,
        maxAttempts: 1,
        retryDelay: Duration.zero,
      );
      fail('Expected target change.');
    } on SelectionBackendException catch (error) {
      expect(error.diagnosticCode, 'selection_target_changed_during_copy');
      expect(error.ownedClipboardRevision, 2);
    }
  });

  test('preserves a newer external clipboard revision', () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );
    await clipboard.writeText('external');

    final result = await backend.restoreClipboard(
      snapshot,
      expectedRevision: lease.clipboardRevision,
    );

    expect(result, ClipboardRestoreResult.skippedExternalChange);
    expect(clipboard.text, 'external');
  });

  test('keeps the replacement and releases its clipboard lease', () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );

    final result = await backend.restoreClipboard(
      snapshot,
      expectedRevision: lease.clipboardRevision,
      restoreOriginal: false,
    );

    expect(result, ClipboardRestoreResult.keptReplacement);
    expect(clipboard.text, 'improved');
    await backend.focus(target);
    await expectLater(
      backend.commitReplacement(lease),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_lease_missing',
        ),
      ),
    );
  });

  test('preserves and reports an external clipboard change under keep policy',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );
    await clipboard.writeText('external');

    final result = await backend.restoreClipboard(
      snapshot,
      expectedRevision: lease.clipboardRevision,
      restoreOriginal: false,
    );

    expect(result, ClipboardRestoreResult.skippedExternalChange);
    expect(clipboard.text, 'external');
  });

  test('does not restore after a same-text write races the clipboard read',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );
    clipboard.onRead = () {
      clipboard.onRead = null;
      platform.revision++;
    };

    final result = await backend.restoreClipboard(
      snapshot,
      expectedRevision: lease.clipboardRevision,
    );

    expect(result, ClipboardRestoreResult.skippedExternalChange);
    expect(clipboard.text, 'improved');
  });

  test('refuses to paste when the staged clipboard lease was replaced',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    await backend.focus(target);
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );
    await clipboard.writeText('external');

    await expectLater(
      backend.commitReplacement(lease),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_stage_lease_lost',
        ),
      ),
    );
    expect(platform.replacement, isNull);
  });

  test('rejects a reused window handle with a different process identity',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );
    final target = await backend.captureTarget();
    platform.processId = 9999;

    expect(await backend.isSameTarget(target), isFalse);
  });

  test('revalidates foreground target immediately before paste', () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: platform.revision,
      rollbackText: 'original',
    );
    platform.foreground = 99;

    await expectLater(
      backend.commitReplacement(lease),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_target_changed_before_commit',
        ),
      ),
    );
  });

  test('rejects staging when no new clipboard revision is acquired', () async {
    final platform = _FakeSelectionPlatformGateway();
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(
        platform,
        'original',
        incrementOnWrite: false,
      ),
    );
    final target = await backend.captureTarget();

    await expectLater(
      backend.stageReplacement(
        target,
        'improved',
        expectedRevision: platform.revision,
        rollbackText: 'original',
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_stage_revision_unchanged',
        ),
      ),
    );
  });

  test('rejects staging after an external copy during processing', () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final expectedRevision = platform.revision;
    platform.revision++;
    clipboard.text = 'new external value';

    await expectLater(
      backend.stageReplacement(
        target,
        'improved',
        expectedRevision: expectedRevision,
        rollbackText: 'original',
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_stage_clipboard_changed',
        ),
      ),
    );
    expect(clipboard.text, 'new external value');
  });

  test('post-write read failure reports acquired clipboard ownership',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(platform, 'original')
      ..onRead = () => throw StateError('read failed');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();

    await expectLater(
      backend.stageReplacement(
        target,
        'improved',
        expectedRevision: platform.revision,
        rollbackText: 'original',
      ),
      throwsA(
        isA<SelectionBackendException>()
            .having(
              (error) => error.diagnosticCode,
              'diagnosticCode',
              'selection_stage_failed',
            )
            .having(
              (error) => error.ownedClipboardRevision,
              'ownedClipboardRevision',
              2,
            ),
      ),
    );
  });

  test('restores a stable staged revision whose text was transformed',
      () async {
    final platform = _FakeSelectionPlatformGateway();
    final clipboard = _FakeClipboard(
      platform,
      'original',
      transformWrite: (value) => value == 'improved' ? 'altered' : value,
    );
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();

    late final SelectionBackendException failure;
    try {
      await backend.stageReplacement(
        target,
        'improved',
        expectedRevision: platform.revision,
        rollbackText: 'original',
      );
      fail('Expected staged text mismatch.');
    } on SelectionBackendException catch (error) {
      failure = error;
    }
    expect(failure.ownedClipboardRevision, 2);

    final result = await backend.restoreClipboard(
      snapshot,
      expectedRevision: failure.ownedClipboardRevision!,
    );
    expect(result, ClipboardRestoreResult.restored);
    expect(clipboard.text, 'original');
  });

  test('atomic restore preserves a clipboard change after validation',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform.rejectNextAtomicWrite = true;

    final result = await backend.restoreClipboard(
      snapshot,
      expectedRevision: lease.clipboardRevision,
    );

    expect(result, ClipboardRestoreResult.skippedExternalChange);
    expect(clipboard.text, 'improved');
  });

  test('native post-empty failure exposes ownership and can restore', () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    platform.throwAtomicMutationNext = true;

    late final SelectionBackendException failure;
    try {
      await backend.stageReplacement(
        target,
        'improved',
        expectedRevision: snapshot.revision,
        rollbackText: 'original',
      );
      fail('Expected a native clipboard mutation failure.');
    } on SelectionBackendException catch (error) {
      failure = error;
    }

    expect(failure.ownedClipboardRevision, 2);
    expect(clipboard.text, '');
    expect(
      await backend.restoreClipboard(
        snapshot,
        expectedRevision: failure.ownedClipboardRevision!,
      ),
      ClipboardRestoreResult.restored,
    );
    expect(clipboard.text, 'original');
  });

  test('restore retries native post-empty failures with new ownership',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform.atomicMutationFailuresRemaining = 2;

    expect(
      await backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      ClipboardRestoreResult.restored,
    );
    expect(clipboard.text, 'original');
    expect(platform.revision, 5);
  });

  test('restore follows the new revision after native rollback succeeds',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform
      ..atomicMutationFailuresRemaining = 1
      ..atomicMutationRollbackText = 'improved';

    expect(
      await backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      ClipboardRestoreResult.restored,
    );
    expect(clipboard.text, 'original');
    expect(platform.revision, 4);
  });

  test('background recovery restores after the synchronous retry budget',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
      clipboardRecoveryDelay: Duration.zero,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform.atomicMutationFailuresRemaining = 4;

    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'clipboard_restore_native_write_failed',
        ),
      ),
    );
    await expectLater(
      backend.captureTarget(),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'clipboard_recovery_pending',
        ),
      ),
    );

    for (var attempt = 0;
        attempt < 50 && clipboard.text != 'original';
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(clipboard.text, 'original');
    expect((await backend.captureTarget()).id, '42:4242');
  });

  test('background recovery preserves a newer external clipboard value',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
      clipboardRecoveryDelay: const Duration(milliseconds: 10),
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform.atomicMutationFailuresRemaining = 3;

    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      throwsA(isA<SelectionBackendException>()),
    );
    clipboard.text = 'external';
    platform.revision++;
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(clipboard.text, 'external');
    expect((await backend.captureTarget()).id, '42:4242');
  });

  test('background recovery also retries failures before native mutation',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
      clipboardRecoveryDelay: Duration.zero,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform.atomicPreMutationFailuresRemaining = 4;

    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'clipboard_restore_native_write_failed',
        ),
      ),
    );
    expect(clipboard.text, 'improved');

    for (var attempt = 0;
        attempt < 50 && clipboard.text != 'original';
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(clipboard.text, 'original');
    expect(platform.revision, 3);
  });

  test('bounded recovery enters manual state and can be retried explicitly',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
      clipboardRecoveryDelay: Duration.zero,
      maxAutomaticClipboardRecoveryAttempts: 2,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform.atomicPreMutationFailuresRemaining = 100;

    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      throwsA(isA<SelectionBackendException>()),
    );
    for (var attempt = 0;
        attempt < 50 && !backend.clipboardRecoveryRequiresManualAction;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(backend.hasPendingClipboardRecovery, isTrue);
    expect(backend.clipboardRecoveryRequiresManualAction, isTrue);
    await expectLater(
      backend.captureTarget(),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'clipboard_recovery_manual_action_required',
        ),
      ),
    );

    platform.atomicPreMutationFailuresRemaining = 0;
    expect(await backend.retryClipboardRecovery(), isTrue);
    for (var attempt = 0;
        attempt < 50 && backend.hasPendingClipboardRecovery;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(clipboard.text, 'original');
    expect(backend.hasPendingClipboardRecovery, isFalse);
  });

  test('shutdown is postponed until a permanent recovery failure is resolved',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
      clipboardRecoveryDelay: Duration.zero,
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform
      ..atomicPreMutationFailuresRemaining = 100
      ..atomicPreMutationFailureRetryable = false;

    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      throwsA(isA<SelectionBackendException>()),
    );
    expect(backend.clipboardRecoveryRequiresManualAction, isTrue);

    expect(await backend.prepareForShutdown(), isFalse);
    expect(backend.hasPendingClipboardRecovery, isTrue);
    expect(clipboard.text, 'improved');

    platform.atomicPreMutationFailuresRemaining = 0;
    expect(await backend.retryClipboardRecovery(), isTrue);
    expect(clipboard.text, 'original');
    expect(await backend.prepareForShutdown(), isTrue);

    expect(backend.hasPendingClipboardRecovery, isFalse);
    await expectLater(
      backend.captureTarget(),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_backend_disposed',
        ),
      ),
    );
  });

  test('shutdown wakes and quiesces automatic recovery before final CAS',
      () async {
    final platform = _FakeSelectionPlatformGateway(atomicTransactions: true);
    final clipboard = _FakeClipboard(platform, 'original');
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: clipboard,
      clipboardRecoveryDelay: const Duration(seconds: 30),
    );
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'improved',
      expectedRevision: snapshot.revision,
      rollbackText: 'original',
    );
    platform.atomicMutationFailuresRemaining = 4;

    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
      ),
      throwsA(isA<SelectionBackendException>()),
    );

    expect(await backend.prepareForShutdown(), isTrue);
    expect(clipboard.text, 'original');
    expect(backend.hasPendingClipboardRecovery, isFalse);
  });

  test('rejects a commit whose clipboard lease is not owned', () async {
    final platform = _FakeSelectionPlatformGateway()..foreground = 42;
    final backend = PlatformSelectionBackend(
      platform: platform,
      clipboard: _FakeClipboard(platform, 'original'),
    );

    await expectLater(
      backend.commitReplacement(
        const ClipboardLease(
          target: SelectionTarget('42:4242'),
          clipboardRevision: 999,
        ),
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'selection_lease_missing',
        ),
      ),
    );
  });
}

final class _FakeClipboard implements ClipboardTextGateway {
  _FakeClipboard(
    this.platform,
    this.text, {
    this.incrementOnWrite = true,
    this.transformWrite,
  }) {
    platform.atomicWriter = (value, expectedRevision) async {
      if (platform.atomicPreMutationFailuresRemaining > 0) {
        platform.atomicPreMutationFailuresRemaining--;
        throw ClipboardTransactionException(
          code: 'test_pre_mutation_failure',
          retryable: platform.atomicPreMutationFailureRetryable,
        );
      }
      if (platform.throwAtomicMutationNext ||
          platform.atomicMutationFailuresRemaining > 0) {
        platform.throwAtomicMutationNext = false;
        if (platform.atomicMutationFailuresRemaining > 0) {
          platform.atomicMutationFailuresRemaining--;
        }
        text = platform.atomicMutationRollbackText ?? '';
        platform.revision++;
        throw AtomicClipboardMutationException(
          revision: platform.revision,
          currentText: text,
        );
      }
      if (platform.rejectNextAtomicWrite) {
        platform.rejectNextAtomicWrite = false;
        return null;
      }
      if (platform.revision != expectedRevision) return null;
      text = value;
      platform.revision++;
      return platform.revision;
    };
    platform.nativeCapturer = () async => PlatformClipboardSnapshot(
          revision: platform.revision,
          payload: _FakeNativeClipboardPayload(text),
        );
    platform.nativeRestorer = (
      payload,
      expectedRevision,
      rollbackText,
    ) async {
      if (platform.revision != expectedRevision) return null;
      if (payload is! _FakeNativeClipboardPayload) {
        throw const ClipboardTransactionException(
          code: 'test_native_snapshot_invalid',
          retryable: false,
        );
      }
      text = payload.text;
      platform.revision++;
      return platform.revision;
    };
  }

  final _FakeSelectionPlatformGateway platform;
  String text;
  final bool incrementOnWrite;
  final String Function(String value)? transformWrite;
  void Function()? onRead;
  int readCalls = 0;

  @override
  Future<String> readText() async {
    readCalls++;
    onRead?.call();
    return text;
  }

  @override
  Future<void> writeText(String value) async {
    text = transformWrite?.call(value) ?? value;
    if (incrementOnWrite) {
      platform.revision++;
    }
  }
}

final class _FakeNativeClipboardPayload {
  const _FakeNativeClipboardPayload(this.text);

  final String text;
}

final class _FixedProcessingRepository implements TextProcessingRepository {
  const _FixedProcessingRepository(this.result);

  final String result;

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) async =>
      result;
}

final class _FakeDirectSelectionReader implements DirectSelectionReader {
  _FakeDirectSelectionReader(this.result);

  final DirectSelectionRead result;
  bool sameTarget = true;

  @override
  Future<bool> isSameTarget(DirectSelectionTarget target) async => sameTarget;

  @override
  Future<DirectSelectionRead> readSelection(
    DirectSelectionTarget target,
  ) async =>
      result;

  @override
  void releaseTarget(DirectSelectionTarget target) {}
}

final class _FakeSelectionPlatformGateway
    implements
        SelectionPlatformGateway,
        NativeClipboardSnapshotGateway,
        TargetInteractionPermissionGateway,
        StableClipboardTextGateway {
  _FakeSelectionPlatformGateway({
    this.copyChangesRevision = true,
    this.losslessSnapshot = true,
    this.clipboardOwnedByTarget = true,
    List<bool>? losslessResults,
    this.changeRevisionOnFirstCapabilityCheck = false,
    this.changeProcessIdDuringCopy = false,
    this.atomicTransactions = false,
    this.nativeSnapshots = false,
    this.stableReads = false,
    this.stableOwnerProcessId = 4242,
    this.interactionAllowed = true,
  }) : losslessResults =
            losslessResults == null ? null : List<bool>.of(losslessResults);

  final bool copyChangesRevision;
  final bool losslessSnapshot;
  final bool clipboardOwnedByTarget;
  final List<bool>? losslessResults;
  final bool changeRevisionOnFirstCapabilityCheck;
  final bool changeProcessIdDuringCopy;
  final bool atomicTransactions;
  final bool nativeSnapshots;
  final bool stableReads;
  final int stableOwnerProcessId;
  final bool interactionAllowed;
  int capabilityChecks = 0;
  int original = 42;
  int foreground = 7;
  int revision = 1;
  int processId = 4242;
  String? replacement;
  int copyCalls = 0;
  void Function()? onCopy;
  bool rejectNextAtomicWrite = false;
  bool throwAtomicMutationNext = false;
  int atomicPreMutationFailuresRemaining = 0;
  bool atomicPreMutationFailureRetryable = true;
  int atomicMutationFailuresRemaining = 0;
  String? atomicMutationRollbackText;
  Future<int?> Function(String text, int expectedRevision)? atomicWriter;
  Future<PlatformClipboardSnapshot> Function()? nativeCapturer;
  Future<int?> Function(
    Object payload,
    int expectedRevision,
    String rollbackText,
  )? nativeRestorer;
  ClipboardTransactionException? nativeCaptureFailure;
  int nativeRestoreCalls = 0;
  int nativeReleaseCalls = 0;
  int nativeReleaseFailuresRemaining = 0;
  final List<Object> releasedNativeSnapshots = [];
  int stableReadCalls = 0;
  int ownerChecks = 0;

  @override
  Future<bool> focusWindow(int handle) async {
    foreground = handle;
    return true;
  }

  @override
  Future<bool> canInteractWithTarget(int targetHandle) async =>
      interactionAllowed;

  @override
  Future<int> getClipboardRevision() async => revision;

  @override
  Future<int> getForegroundWindow() async => foreground;

  @override
  int getOriginalForegroundWindow() => original;

  @override
  Future<int> getWindowProcessId(int handle) async =>
      handle == original ? processId : 0;

  @override
  Future<String> getSelectedText(int targetHandle) async {
    copyCalls++;
    foreground = targetHandle;
    if (copyChangesRevision) {
      revision++;
    }
    if (changeProcessIdDuringCopy) {
      processId++;
    }
    onCopy?.call();
    return 'selected';
  }

  @override
  Future<bool> isWindowValid(int handle) async => handle == original;

  @override
  Future<void> replaceSelectedText(int targetHandle, String newText) async {
    replacement = newText;
  }

  @override
  Future<bool> supportsLosslessTextClipboardSnapshot() async {
    capabilityChecks++;
    if (changeRevisionOnFirstCapabilityCheck && capabilityChecks == 1) {
      revision++;
    }
    final results = losslessResults;
    return results == null || results.isEmpty
        ? losslessSnapshot
        : results.removeAt(0);
  }

  @override
  Future<bool> isClipboardOwnedByTarget(int handle) async {
    ownerChecks++;
    return clipboardOwnedByTarget;
  }

  @override
  Future<bool> supportsStableClipboardTextReads() async => stableReads;

  @override
  Future<StableClipboardTextRead> copySelectionTextWithEvidence(
    int targetHandle,
  ) async {
    stableReadCalls++;
    foreground = targetHandle;
    revision++;
    return StableClipboardTextRead(
      text: 'selected-stable',
      revision: revision,
      ownerProcessId: stableOwnerProcessId,
    );
  }

  @override
  Future<bool> supportsNativeClipboardSnapshots() async => nativeSnapshots;

  @override
  Future<PlatformClipboardSnapshot> captureNativeClipboardSnapshot() async {
    final failure = nativeCaptureFailure;
    if (failure != null) throw failure;
    final capture = nativeCapturer;
    if (capture == null) throw StateError('Native snapshot capture is unset.');
    return capture();
  }

  @override
  Future<int?> restoreNativeClipboardSnapshotIfRevision(
    Object payload, {
    required int expectedRevision,
    required String rollbackText,
  }) async {
    nativeRestoreCalls++;
    return nativeRestorer?.call(payload, expectedRevision, rollbackText);
  }

  @override
  Future<void> releaseNativeClipboardSnapshot(Object payload) async {
    nativeReleaseCalls++;
    if (nativeReleaseFailuresRemaining > 0) {
      nativeReleaseFailuresRemaining--;
      throw StateError('transient native release failure');
    }
    releasedNativeSnapshots.add(payload);
  }

  @override
  bool supportsAtomicTextClipboardTransactions() => atomicTransactions;

  @override
  Future<int?> writeClipboardTextIfRevision(
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) async =>
      atomicWriter?.call(text, expectedRevision);
}
