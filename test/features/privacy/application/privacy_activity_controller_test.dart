import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/application/privacy_activity_controller.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';

void main() {
  test('initializes, records, clears, and exports metadata', () async {
    final repository = _FakeRepository();
    final controller = PrivacyActivityController(repository: repository);

    await controller.initialize();
    expect(controller.state.stage, PrivacyActivityStage.ready);
    expect(controller.state.managedExportsKnown, isTrue);

    await controller.record(
      _event(),
      consent: _enabledConsent,
    );
    expect(controller.state.historyCount, 1);
    expect(controller.state.diagnosticsCount, 1);

    await controller.exportDiagnostics();
    expect(controller.state.lastExportPath, 'safe-export.json');
    repository.managedExportPathsAfterRecord = const ['other-export.json'];
    await controller.clearHistory();
    expect(controller.state.historyCount, 0);
    await controller.clearDiagnostics();
    expect(controller.state.diagnosticsCount, 0);
    expect(controller.state.lastExportPath, isNull);
    await controller.close();
  });

  test('disabled recording avoids the repository entirely', () async {
    final repository = _FakeRepository();
    final controller = PrivacyActivityController(repository: repository);

    await controller.record(
      _event(),
      consent: const PrivacyConsent.disabled(),
    );

    expect(repository.recordCalls, 0);
    await controller.close();
  });

  test('storage failures become safe state codes and never escape', () async {
    final repository = _FakeRepository()..fail = true;
    final controller = PrivacyActivityController(repository: repository);

    await controller.initialize();
    expect(controller.state.errorCode, 'privacy_data_load_failed');
    await controller.record(
      _event(),
      consent: _enabledConsent,
    );
    expect(controller.state.errorCode, 'privacy_data_write_failed');
    await controller.clearHistory();
    expect(controller.state.errorCode, 'privacy_history_clear_failed');
    await controller.clearDiagnostics();
    expect(controller.state.errorCode, 'privacy_diagnostics_clear_failed');
    await controller.exportDiagnostics();
    expect(controller.state.errorCode, 'privacy_diagnostics_export_failed');
    await controller.close();
  });

  test('background record completion cannot clear foreground busy state',
      () async {
    final repository = _FakeRepository();
    final controller = PrivacyActivityController(repository: repository);
    await controller.initialize();
    repository.recordGate = Completer<void>();
    repository.recordStarted = Completer<void>();
    repository.exportGate = Completer<void>();
    repository.exportStarted = Completer<void>();

    final record = controller.record(_event(), consent: _enabledConsent);
    await repository.recordStarted!.future;
    final export = controller.exportDiagnostics();
    await repository.exportStarted!.future;
    expect(controller.state.stage, PrivacyActivityStage.busy);

    repository.recordGate!.complete();
    await record;
    expect(controller.state.stage, PrivacyActivityStage.busy);

    repository.exportGate!.complete();
    await export;
    expect(controller.state.stage, PrivacyActivityStage.ready);
    expect(controller.state.lastExportPath, 'safe-export.json');
    await controller.close();
  });

  test('foreground partial failure reloads the truthful snapshot', () async {
    final repository = _FakeRepository();
    final controller = PrivacyActivityController(repository: repository);
    await controller.initialize();
    await controller.record(_event(), consent: _enabledConsent);
    repository.failClearDiagnosticsAfterMutation = true;

    await controller.clearDiagnostics();

    expect(controller.state.diagnosticsCount, 0);
    expect(
      controller.state.errorCode,
      'privacy_diagnostics_clear_failed',
    );
    await controller.close();
  });

  test('pruned managed export clears a previously displayed path', () async {
    final repository = _FakeRepository();
    final controller = PrivacyActivityController(repository: repository);
    await controller.initialize();
    await controller.exportDiagnostics();
    expect(controller.state.lastExportPath, 'safe-export.json');

    await controller.record(_event(), consent: _enabledConsent);

    expect(controller.state.managedExportCount, 0);
    expect(controller.state.lastExportPath, isNull);
    await controller.close();
  });
}

PrivacyActivityEvent _event() => PrivacyActivityEvent(
      occurredAt: DateTime.utc(2026, 7, 13, 12),
      action: TextAction.fix,
      outcome: PrivacyActivityOutcome.completed,
      durationBucket: PrivacyDurationBucket.underOneSecond,
      platformFamily: PrivacyPlatformFamily.linux,
      clipboardRestoreSkipped: false,
    );

const _enabledConsent = PrivacyConsent(
  historyEnabled: true,
  diagnosticsEnabled: true,
  generation: 1,
);

final class _FakeRepository implements PrivacyActivityRepository {
  PrivacyActivitySnapshot value = PrivacyActivitySnapshot.empty();
  bool fail = false;
  int recordCalls = 0;
  Completer<void>? recordGate;
  Completer<void>? recordStarted;
  Completer<void>? exportGate;
  Completer<void>? exportStarted;
  bool failClearDiagnosticsAfterMutation = false;
  List<String> managedExportPathsAfterRecord = const [];

  void _throwIfNeeded() {
    if (fail) throw StateError('private raw filesystem error');
  }

  @override
  Future<PrivacyActivitySnapshot> load() async {
    _throwIfNeeded();
    return value;
  }

  @override
  Future<PrivacyActivitySnapshot> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  }) async {
    recordCalls++;
    _throwIfNeeded();
    recordStarted?.complete();
    await recordGate?.future;
    value = PrivacyActivitySnapshot(
      history: consent.historyEnabled
          ? [...value.history, event.toHistoryEntry()]
          : value.history,
      diagnostics: consent.diagnosticsEnabled
          ? [...value.diagnostics, event]
          : value.diagnostics,
      managedExportPaths: managedExportPathsAfterRecord,
    );
    return value;
  }

  @override
  Future<PrivacyActivitySnapshot> clearHistory() async {
    _throwIfNeeded();
    value = PrivacyActivitySnapshot(
      history: const [],
      diagnostics: value.diagnostics,
    );
    return value;
  }

  @override
  Future<PrivacyActivitySnapshot> clearDiagnostics() async {
    _throwIfNeeded();
    value = PrivacyActivitySnapshot(
      history: value.history,
      diagnostics: const [],
    );
    if (failClearDiagnosticsAfterMutation) {
      throw StateError('export directory deletion failed');
    }
    return value;
  }

  @override
  Future<String> exportDiagnostics() async {
    _throwIfNeeded();
    exportStarted?.complete();
    await exportGate?.future;
    value = PrivacyActivitySnapshot(
      history: value.history,
      diagnostics: value.diagnostics,
      managedExportPaths: const ['safe-export.json'],
    );
    return 'safe-export.json';
  }
}
