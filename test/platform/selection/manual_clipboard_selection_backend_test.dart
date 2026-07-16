import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/application/text_replacement_state.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_assistant_runtime_policy.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/domain/text_processing_repository.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/manual_clipboard_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/platform_selection_backend.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_backend.dart';

void main() {
  test('reads only the explicit clipboard input and leaves result for paste',
      () async {
    final clipboard = _MemoryClipboard('copied selection');
    final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final selection = await backend.copySelection(
      target,
      snapshot,
      maxAttempts: 8,
      retryDelay: const Duration(milliseconds: 40),
    );

    expect(selection.text, 'copied selection');
    expect(selection.ownedClipboardRevision, isNull);
    final lease = await backend.stageReplacement(
      target,
      'transformed',
      expectedRevision: snapshot.revision,
      rollbackText: selection.text,
    );
    expect(await backend.commitReplacement(lease), CommitVerification.verified);
    expect(
      await backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
        restoreOriginal: false,
      ),
      ClipboardRestoreResult.keptReplacement,
    );
    expect(clipboard.value, 'transformed');
  });

  test('restores the source after a failed or cancelled staged operation',
      () async {
    final clipboard = _MemoryClipboard('source');
    final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'result',
      expectedRevision: snapshot.revision,
      rollbackText: 'source',
    );

    expect(
      await backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
        restoreOriginal: true,
      ),
      ClipboardRestoreResult.restored,
    );
    expect(clipboard.value, 'source');
  });

  test('preserves a newer clipboard value copied during processing', () async {
    final clipboard = _MemoryClipboard('source');
    final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    clipboard.value = 'new external value';

    await expectLater(
      backend.stageReplacement(
        target,
        'result',
        expectedRevision: snapshot.revision,
        rollbackText: 'source',
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'manual_clipboard_changed_before_result',
        ),
      ),
    );
    expect(clipboard.value, 'new external value');
  });

  test('does not verify or restore over a change after staging', () async {
    final clipboard = _MemoryClipboard('source');
    final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'result',
      expectedRevision: snapshot.revision,
      rollbackText: 'source',
    );
    clipboard.value = 'new external value';

    await expectLater(
      backend.commitReplacement(lease),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'manual_clipboard_changed_after_result',
        ),
      ),
    );
    expect(
      await backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
        restoreOriginal: true,
      ),
      ClipboardRestoreResult.skippedExternalChange,
    );
    expect(clipboard.value, 'new external value');
  });

  test('fails before processing when the user has not copied text', () async {
    final backend = ManualClipboardSelectionBackend(
      clipboard: _MemoryClipboard('  '),
    );

    await expectLater(
      backend.snapshotClipboard(),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'manual_clipboard_text_missing',
        ),
      ),
    );
  });

  test('controller reports a truthful manual-paste completion state', () async {
    final clipboard = _MemoryClipboard('copied selection');
    final controller = TextReplacementController(
      selectionBackend: ManualClipboardSelectionBackend(clipboard: clipboard),
      processingRepository: const _UppercaseRepository(),
      policyProvider: const FixedTextAssistantRuntimePolicyProvider(),
    );
    addTearDown(controller.close);

    expect(controller.requiresManualPaste, isTrue);
    expect(
      await controller.run(TextAction.fix),
      TextReplacementOutcome.completed,
    );
    expect(controller.state.stage, TextReplacementStage.awaitingManualPaste);
    expect(clipboard.value, 'COPIED SELECTION');
  });

  test('successful manual cleanup never reads or restores the clipboard',
      () async {
    final clipboard = _SequencedFaultClipboard(
      'copied selection',
      failingReadCalls: {5},
    );
    final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
    final controller = TextReplacementController(
      selectionBackend: backend,
      processingRepository: const _UppercaseRepository(),
      policyProvider: const FixedTextAssistantRuntimePolicyProvider(),
    );
    addTearDown(controller.close);

    expect(
      await controller.run(TextAction.fix),
      TextReplacementOutcome.completed,
    );
    expect(controller.state.stage, TextReplacementStage.awaitingManualPaste);
    expect(clipboard.value, 'COPIED SELECTION');
    expect(backend.hasPendingClipboardRecovery, isFalse);
    expect(await controller.prepareForShutdown(), isTrue);
    expect(clipboard.value, 'COPIED SELECTION');
  });

  test('retains recovery ownership when restoring the source write fails',
      () async {
    final clipboard = _FaultyClipboard('source');
    final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'result',
      expectedRevision: snapshot.revision,
      rollbackText: 'source',
    );
    clipboard.failWrites = true;

    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
        restoreOriginal: true,
      ),
      throwsA(
        isA<SelectionBackendException>().having(
          (error) => error.diagnosticCode,
          'diagnosticCode',
          'manual_clipboard_restore_failed',
        ),
      ),
    );
    backend.releaseTarget(target);

    expect(backend.hasPendingClipboardRecovery, isTrue);
    expect(await backend.prepareForShutdown(), isFalse);
    expect(clipboard.value, 'result');

    clipboard.failWrites = false;
    expect(await backend.retryClipboardRecovery(), isTrue);
    expect(backend.hasPendingClipboardRecovery, isFalse);
    expect(clipboard.value, 'source');
    expect(await backend.prepareForShutdown(), isTrue);
  });

  test('retains recovery ownership after read and verification failures',
      () async {
    for (final failure in _RestoreFailure.values) {
      final clipboard = _FaultyClipboard('source');
      final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
      final target = await backend.captureTarget();
      final snapshot = await backend.snapshotClipboard();
      final lease = await backend.stageReplacement(
        target,
        'result',
        expectedRevision: snapshot.revision,
        rollbackText: 'source',
      );
      switch (failure) {
        case _RestoreFailure.read:
          clipboard.failReads = true;
        case _RestoreFailure.verification:
          clipboard.ignoreWrites = true;
      }

      await expectLater(
        backend.restoreClipboard(
          snapshot,
          expectedRevision: lease.clipboardRevision,
          restoreOriginal: true,
        ),
        throwsA(isA<SelectionBackendException>()),
      );
      backend.releaseTarget(target);
      expect(backend.hasPendingClipboardRecovery, isTrue, reason: failure.name);

      clipboard
        ..failReads = false
        ..ignoreWrites = false;
      expect(await backend.retryClipboardRecovery(), isTrue,
          reason: failure.name);
      expect(clipboard.value, 'source', reason: failure.name);
    }
  });

  test('releases recovery without overwriting a newer external clipboard',
      () async {
    final clipboard = _FaultyClipboard('source');
    final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
    final target = await backend.captureTarget();
    final snapshot = await backend.snapshotClipboard();
    final lease = await backend.stageReplacement(
      target,
      'result',
      expectedRevision: snapshot.revision,
      rollbackText: 'source',
    );
    clipboard.failWrites = true;
    await expectLater(
      backend.restoreClipboard(
        snapshot,
        expectedRevision: lease.clipboardRevision,
        restoreOriginal: true,
      ),
      throwsA(isA<SelectionBackendException>()),
    );
    clipboard
      ..failWrites = false
      ..value = 'new external value';

    expect(await backend.retryClipboardRecovery(), isTrue);
    expect(backend.hasPendingClipboardRecovery, isFalse);
    expect(clipboard.value, 'new external value');
  });

  test('controller exposes retry when manual rollback cannot complete',
      () async {
    final clipboard = _SequencedFaultClipboard(
      'source',
      failingReadCalls: {4},
      failingWriteCalls: {2},
    );
    final backend = ManualClipboardSelectionBackend(clipboard: clipboard);
    final controller = TextReplacementController(
      selectionBackend: backend,
      processingRepository: const _UppercaseRepository(),
      policyProvider: const FixedTextAssistantRuntimePolicyProvider(),
    );
    addTearDown(controller.close);

    expect(
      await controller.run(TextAction.fix),
      TextReplacementOutcome.failed,
    );
    expect(
      controller.state.failureCode,
      'clipboard_recovery_manual_action_required',
    );
    expect(backend.hasPendingClipboardRecovery, isTrue);

    clipboard.clearFailures();
    expect(await controller.retryClipboardRecovery(), isTrue);
    expect(clipboard.value, 'source');
    expect(backend.hasPendingClipboardRecovery, isFalse);
  });
}

enum _RestoreFailure { read, verification }

final class _MemoryClipboard implements ClipboardTextGateway {
  _MemoryClipboard(this.value);

  String value;

  @override
  Future<String> readText() async => value;

  @override
  Future<void> writeText(String text) async => value = text;
}

final class _FaultyClipboard implements ClipboardTextGateway {
  _FaultyClipboard(this.value);

  String value;
  bool failReads = false;
  bool failWrites = false;
  bool ignoreWrites = false;

  @override
  Future<String> readText() async {
    if (failReads) throw StateError('read failed');
    return value;
  }

  @override
  Future<void> writeText(String text) async {
    if (failWrites) throw StateError('write failed');
    if (!ignoreWrites) value = text;
  }
}

final class _SequencedFaultClipboard implements ClipboardTextGateway {
  _SequencedFaultClipboard(
    this.value, {
    Set<int> failingReadCalls = const {},
    Set<int> failingWriteCalls = const {},
  })  : _failingReadCalls = {...failingReadCalls},
        _failingWriteCalls = {...failingWriteCalls};

  String value;
  final Set<int> _failingReadCalls;
  final Set<int> _failingWriteCalls;
  int _readCalls = 0;
  int _writeCalls = 0;

  void clearFailures() {
    _failingReadCalls.clear();
    _failingWriteCalls.clear();
  }

  @override
  Future<String> readText() async {
    if (_failingReadCalls.contains(++_readCalls)) {
      throw StateError('read failed');
    }
    return value;
  }

  @override
  Future<void> writeText(String text) async {
    if (_failingWriteCalls.contains(++_writeCalls)) {
      throw StateError('write failed');
    }
    value = text;
  }
}

final class _UppercaseRepository implements TextProcessingRepository {
  const _UppercaseRepository();

  @override
  Future<String> process({
    required String text,
    required TextAction action,
    TextAssistantRuntimePolicy? policy,
    TextProcessingCancellationToken? cancellationToken,
  }) async =>
      text.toUpperCase();
}
