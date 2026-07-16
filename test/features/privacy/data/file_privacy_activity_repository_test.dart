import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/data/file_privacy_activity_repository.dart';
import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/core/domain/text_action.dart';
import 'package:yandex_keyboard_desktop/src/platform/posix/posix_file_mode_gateway.dart';

void main() {
  late Directory temporaryDirectory;
  late File historyFile;
  late File diagnosticsFile;
  late Directory exportDirectory;
  late DateTime now;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('privacy-test-');
    historyFile = File('${temporaryDirectory.path}/history.v1.json');
    diagnosticsFile = File('${temporaryDirectory.path}/diagnostics.v1.json');
    exportDirectory = Directory('${temporaryDirectory.path}/exports');
    now = DateTime.utc(2026, 7, 13, 12);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('disabled-by-default load and record create no privacy files', () async {
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );

    expect(await repository.load(), PrivacyActivitySnapshot.empty());
    await repository.record(
      _event(now),
      consent: const PrivacyConsent.disabled(),
    );

    expect(await historyFile.exists(), isFalse);
    expect(await diagnosticsFile.exists(), isFalse);
  });

  test('stores separate bounded metadata and never writes sentinel text',
      () async {
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      maxHistoryEntries: 2,
      maxDiagnosticEntries: 2,
    );
    for (var index = 0; index < 3; index++) {
      await repository.record(
        _event(
          now.add(Duration(minutes: index)),
          failureCode: 'SECRET_INPUT_$index',
        ),
        consent: _enabledConsent,
      );
    }

    final snapshot = await repository.load();
    final allBytes = '${await historyFile.readAsString()}'
        '${await diagnosticsFile.readAsString()}';

    expect(snapshot.history, hasLength(2));
    expect(snapshot.diagnostics, hasLength(2));
    expect(allBytes, isNot(contains('SECRET_INPUT')));
    expect(allBytes, isNot(contains('failureCode":"SECRET')));
    expect(allBytes, contains('unexpected'));
  });

  test('persists independently consented history and diagnostic streams',
      () async {
    const historyOnly = PrivacyConsent(
      historyEnabled: true,
      diagnosticsEnabled: false,
      generation: 2,
    );
    const diagnosticsOnly = PrivacyConsent(
      historyEnabled: false,
      diagnosticsEnabled: true,
      generation: 3,
    );
    final provider = _MutableConsentProvider(historyOnly);
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      consentProvider: provider,
    );

    await repository.record(_event(now), consent: historyOnly);
    expect(await historyFile.exists(), isTrue);
    expect(await diagnosticsFile.exists(), isFalse);

    provider.value = diagnosticsOnly;
    await repository.record(_event(now), consent: diagnosticsOnly);
    expect(await diagnosticsFile.exists(), isTrue);
  });

  test('prunes expired records and serializes concurrent appends', () async {
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );
    await Future.wait([
      repository.record(
        _event(now.subtract(const Duration(days: 31))),
        consent: _enabledConsent,
      ),
      repository.record(
        _event(now),
        consent: _enabledConsent,
      ),
      repository.record(
        _event(now.add(const Duration(minutes: 1))),
        consent: _enabledConsent,
      ),
    ]);

    final snapshot = await repository.load();

    expect(snapshot.history, hasLength(2));
    expect(snapshot.diagnostics, hasLength(2));
  });

  test('recovers a backup and deletes malformed or oversized input', () async {
    await historyFile.parent.create(recursive: true);
    final validPayload = jsonEncode({
      'schemaVersion': 1,
      'kind': 'history',
      'entries': [_event(now).toHistoryEntry().toJson()],
    });
    await File('${historyFile.path}.backup').writeAsString(validPayload);
    await diagnosticsFile.writeAsString('{private text');
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      maxFileBytes: 512,
    );

    final recovered = await repository.load();
    expect(recovered.history, hasLength(1));
    expect(recovered.diagnostics, isEmpty);
    expect(await diagnosticsFile.exists(), isFalse);

    await diagnosticsFile.writeAsString(List.filled(600, 'x').join());
    expect((await repository.load()).diagnostics, isEmpty);
    expect(await diagnosticsFile.exists(), isFalse);
  });

  test('deletes type-valid JSON with invalid entry field types', () async {
    await historyFile.parent.create(recursive: true);
    await historyFile.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'kind': 'history',
      'entries': [
        {
          'occurredAt': 42,
          'action': 'rewrite',
          'outcome': 'completed',
        },
      ],
    }));
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );

    expect((await repository.load()).history, isEmpty);
    expect(await historyFile.exists(), isFalse);
  });

  test('revalidates consent after a queued write reaches persistence',
      () async {
    final provider = _MutableConsentProvider(_enabledConsent);
    final hardener = _GatePermissionHardener();
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      consentProvider: provider,
      permissionHardener: hardener,
    );
    final blockingExport = repository.exportDiagnostics();
    await hardener.started.future;
    final queuedRecord = repository.record(
      _event(now),
      consent: _enabledConsent,
    );

    provider.value = const PrivacyConsent(
      historyEnabled: false,
      diagnosticsEnabled: false,
      generation: 2,
    );
    hardener.release.complete();
    await blockingExport;
    await queuedRecord;

    expect(await historyFile.exists(), isFalse);
    expect(await diagnosticsFile.exists(), isFalse);
  });

  test('recovers both streams from a failed cross-file commit', () async {
    final failingHardener = _FailingPermissionHardener(
      diagnosticsFile.path,
    );
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      permissionHardener: failingHardener,
    );

    await expectLater(
      repository.record(_event(now), consent: _enabledConsent),
      throwsA(isA<FileSystemException>()),
    );

    final recoveredRepository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );
    final recovered = await recoveredRepository.load();
    expect(recovered.history, hasLength(1));
    expect(recovered.diagnostics, hasLength(1));
    expect(
      await File(
        '${historyFile.parent.path}${Platform.pathSeparator}'
        'privacy-activity.v1.transaction',
      ).exists(),
      isFalse,
    );
  });

  test('clear remains deletion-biased when journal roll-forward keeps failing',
      () async {
    final hardener = _AlwaysFailingPermissionHardener(diagnosticsFile.path);
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      permissionHardener: hardener,
    );
    await expectLater(
      repository.record(_event(now), consent: _enabledConsent),
      throwsA(isA<FileSystemException>()),
    );
    final journal = File(
      '${historyFile.parent.path}${Platform.pathSeparator}'
      'privacy-activity.v1.transaction',
    );
    expect(await journal.exists(), isTrue);

    final cleared = await repository.clearHistory();

    expect(cleared.history, isEmpty);
    expect(await historyFile.exists(), isFalse);
    expect(await journal.exists(), isFalse);
  });

  test('history clear stays truthful when unrelated export pruning fails',
      () async {
    final writer = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );
    await writer.record(_event(now), consent: _enabledConsent);
    await exportDirectory.create(recursive: true);
    await File(
      '${exportDirectory.path}${Platform.pathSeparator}'
      'diagnostics-existing.json',
    ).writeAsString('metadata');
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      permissionHardener: _ExportDirectoryFailingHardener(
        exportDirectory.path,
      ),
    );
    final cleared = await repository.clearHistory();

    expect(cleared.history, isEmpty);
    expect(cleared.managedExportsKnown, isFalse);
    expect(await historyFile.exists(), isFalse);
  });

  test('stale completed clear marker does not disable later collection',
      () async {
    final writer = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );
    await writer.record(_event(now), consent: _enabledConsent);
    final marker = File('${historyFile.path}.clear-requested');
    await marker.writeAsString('{"clearRequested":true}');
    final abandonedTransaction = File(
      '${historyFile.parent.path}${Platform.pathSeparator}'
      'privacy-activity.v1.transaction.tmp',
    );
    await abandonedTransaction.writeAsString('uncommitted metadata');
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );

    expect((await repository.load()).history, hasLength(1));
    await repository.record(
      _event(now.add(const Duration(minutes: 1))),
      consent: _enabledConsent,
    );

    expect((await repository.load()).history, hasLength(2));
    expect(await marker.exists(), isFalse);
    expect(await abandonedTransaction.exists(), isFalse);
  });

  test('exports only redacted diagnostics and clear removes every sidecar',
      () async {
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );
    await repository.record(
      _event(now, failureCode: 'TOP SECRET transformed output'),
      consent: _enabledConsent,
    );

    final exportPath = await repository.exportDiagnostics();
    final exported = await File(exportPath).readAsString();
    expect(exported, contains('"containsSelectedOrTransformedText":false'));
    expect(exported, contains('"redactionPolicyVersion":1'));
    expect(exported, isNot(contains('TOP SECRET')));
    expect(exported, isNot(contains('history')));

    await File('${historyFile.path}.tmp').writeAsString('temporary');
    await File('${historyFile.path}.backup').writeAsString('backup');
    await repository.clearHistory();
    expect(await historyFile.exists(), isFalse);
    expect(await File('${historyFile.path}.tmp').exists(), isFalse);
    expect(await File('${historyFile.path}.backup').exists(), isFalse);

    await repository.clearDiagnostics();
    expect(await diagnosticsFile.exists(), isFalse);
    expect(await exportDirectory.exists(), isFalse);
  });

  test('bounds managed exports and reports them after source expiry', () async {
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      maxExportFiles: 2,
    );
    await repository.record(_event(now), consent: _enabledConsent);
    final first = File(await repository.exportDiagnostics());
    await first.setLastModified(now);
    now = now.add(const Duration(minutes: 1));
    final second = File(await repository.exportDiagnostics());
    await second.setLastModified(now);
    now = now.add(const Duration(minutes: 1));
    final third = File(await repository.exportDiagnostics());
    await third.setLastModified(now);

    final bounded = await repository.load();
    expect(bounded.managedExportCount, 2);
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isTrue);
    expect(await third.exists(), isTrue);

    now = now.add(const Duration(days: 15));
    final sourceExpired = await repository.load();
    expect(sourceExpired.diagnostics, isEmpty);
    expect(sourceExpired.managedExportCount, 0);
  });

  test('recovers or removes interrupted export sidecars during load', () async {
    await exportDirectory.create(recursive: true);
    final abandoned = File(
      '${exportDirectory.path}${Platform.pathSeparator}'
      'diagnostics-abandoned.json.tmp',
    );
    await abandoned.writeAsString('metadata');
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
    );

    final snapshot = await repository.load();

    expect(snapshot.managedExportCount, 0);
    expect(await abandoned.exists(), isFalse);
  });

  test('permission failure cleans the just-created temporary file', () async {
    final hardener = _AlwaysFailingPermissionHardener(historyFile.path);
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      permissionHardener: hardener,
    );

    await expectLater(
      repository.record(_event(now), consent: _enabledConsent),
      throwsA(isA<FileSystemException>()),
    );

    expect(await File('${historyFile.path}.tmp').exists(), isFalse);
  });

  test('hardens every created privacy directory and file', () async {
    final hardener = _RecordingPermissionHardener();
    final repository = _repository(
      historyFile,
      diagnosticsFile,
      exportDirectory,
      () => now,
      permissionHardener: hardener,
    );

    await repository.record(_event(now), consent: _enabledConsent);
    await repository.exportDiagnostics();

    expect(hardener.directories, contains(historyFile.parent.path));
    expect(hardener.directories, contains(exportDirectory.path));
    expect(
      hardener.files.any((path) => path == historyFile.path),
      isTrue,
    );
    expect(
      hardener.files.any((path) => path == diagnosticsFile.path),
      isTrue,
    );
    expect(
      hardener.files.any((path) => path.startsWith(exportDirectory.path)),
      isTrue,
    );
  });

  test('POSIX hardener requests owner-only directory and file modes', () async {
    final gateway = _FakePosixFileModeGateway();
    final hardener = PosixPrivacyFilePermissionHardener(
      gateway: gateway,
    );

    await hardener.hardenDirectory(exportDirectory);
    await hardener.hardenFile(diagnosticsFile);

    expect(gateway.calls[0], (path: exportDirectory.path, mode: 0x1C0));
    expect(gateway.calls[1], (path: diagnosticsFile.path, mode: 0x180));
  });
}

final class _FakePosixFileModeGateway implements PosixFileModeGateway {
  final List<({String path, int mode})> calls = [];

  @override
  Future<void> setMode(String path, int mode) async {
    calls.add((path: path, mode: mode));
  }
}

FilePrivacyActivityRepository _repository(
  File history,
  File diagnostics,
  Directory exports,
  DateTime Function() now, {
  int maxHistoryEntries = 250,
  int maxDiagnosticEntries = 500,
  int maxFileBytes = 1024 * 1024,
  int maxExportFiles = 5,
  PrivacyConsentProvider consentProvider = const _EnabledConsentProvider(),
  PrivacyFilePermissionHardener permissionHardener =
      const NoOpPrivacyFilePermissionHardener(),
}) =>
    FilePrivacyActivityRepository(
      historyFile: history,
      diagnosticsFile: diagnostics,
      exportDirectory: exports,
      consentProvider: consentProvider,
      permissionHardener: permissionHardener,
      now: now,
      maxHistoryEntries: maxHistoryEntries,
      maxDiagnosticEntries: maxDiagnosticEntries,
      maxFileBytes: maxFileBytes,
      maxExportFiles: maxExportFiles,
    );

const _enabledConsent = PrivacyConsent(
  historyEnabled: true,
  diagnosticsEnabled: true,
  generation: 1,
);

final class _EnabledConsentProvider implements PrivacyConsentProvider {
  const _EnabledConsentProvider();

  @override
  PrivacyConsent get currentPrivacyConsent => _enabledConsent;
}

final class _MutableConsentProvider implements PrivacyConsentProvider {
  _MutableConsentProvider(this.value);

  PrivacyConsent value;

  @override
  PrivacyConsent get currentPrivacyConsent => value;
}

final class _RecordingPermissionHardener
    implements PrivacyFilePermissionHardener {
  final Set<String> directories = {};
  final Set<String> files = {};

  @override
  Future<void> hardenDirectory(Directory directory) async {
    directories.add(directory.path);
  }

  @override
  Future<void> hardenFile(File file) async {
    files.add(file.path);
  }
}

final class _GatePermissionHardener implements PrivacyFilePermissionHardener {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> hardenDirectory(Directory directory) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
  }

  @override
  Future<void> hardenFile(File file) async {}
}

final class _FailingPermissionHardener
    implements PrivacyFilePermissionHardener {
  _FailingPermissionHardener(this.diagnosticsPath);

  final String diagnosticsPath;
  bool failed = false;

  @override
  Future<void> hardenDirectory(Directory directory) async {}

  @override
  Future<void> hardenFile(File file) async {
    if (!failed && file.path == '$diagnosticsPath.tmp') {
      failed = true;
      throw FileSystemException('simulated permission failure', file.path);
    }
  }
}

final class _AlwaysFailingPermissionHardener
    implements PrivacyFilePermissionHardener {
  _AlwaysFailingPermissionHardener(this.targetPath);

  final String targetPath;

  @override
  Future<void> hardenDirectory(Directory directory) async {}

  @override
  Future<void> hardenFile(File file) async {
    if (file.path == '$targetPath.tmp') {
      throw FileSystemException('persistent permission failure', file.path);
    }
  }
}

final class _ExportDirectoryFailingHardener
    implements PrivacyFilePermissionHardener {
  _ExportDirectoryFailingHardener(this.exportPath);

  final String exportPath;

  @override
  Future<void> hardenDirectory(Directory directory) async {
    if (directory.path == exportPath) {
      throw FileSystemException('export directory is unavailable', exportPath);
    }
  }

  @override
  Future<void> hardenFile(File file) async {}
}

PrivacyActivityEvent _event(
  DateTime occurredAt, {
  String? failureCode,
}) =>
    PrivacyActivityEvent(
      occurredAt: occurredAt,
      action: TextAction.rewrite,
      outcome: PrivacyActivityOutcome.completedWithWarning,
      durationBucket: PrivacyDurationBucket.underFiveSeconds,
      platformFamily: PrivacyPlatformFamily.windows,
      failureCode: failureCode,
      clipboardRestoreSkipped: false,
      clipboardRestoreFailureCode: null,
    );
