import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yandex_keyboard_desktop/src/features/privacy/domain/privacy_activity.dart';
import 'package:yandex_keyboard_desktop/src/platform/posix/posix_file_mode_gateway.dart';

typedef PrivacyTimestamp = DateTime Function();

abstract interface class PrivacyFilePermissionHardener {
  Future<void> hardenDirectory(Directory directory);

  Future<void> hardenFile(File file);
}

final class NoOpPrivacyFilePermissionHardener
    implements PrivacyFilePermissionHardener {
  const NoOpPrivacyFilePermissionHardener();

  @override
  Future<void> hardenDirectory(Directory directory) async {}

  @override
  Future<void> hardenFile(File file) async {}
}

final class PosixPrivacyFilePermissionHardener
    implements PrivacyFilePermissionHardener {
  PosixPrivacyFilePermissionHardener({
    PosixFileModeGateway gateway = const NativePosixFileModeGateway(),
  }) : _gateway = gateway;

  final PosixFileModeGateway _gateway;

  @override
  Future<void> hardenDirectory(Directory directory) =>
      _gateway.setMode(directory.path, 0x1C0);

  @override
  Future<void> hardenFile(File file) => _gateway.setMode(file.path, 0x180);
}

final class FilePrivacyActivityRepository implements PrivacyActivityRepository {
  FilePrivacyActivityRepository({
    required File historyFile,
    required File diagnosticsFile,
    required Directory exportDirectory,
    required PrivacyConsentProvider consentProvider,
    PrivacyTimestamp now = DateTime.now,
    PrivacyFilePermissionHardener? permissionHardener,
    this.maxHistoryEntries = 250,
    this.maxDiagnosticEntries = 500,
    this.maxFileBytes = 1024 * 1024,
    this.maxExportFiles = 5,
    this.maxExportBytes = 5 * 1024 * 1024,
    this.historyRetention = const Duration(days: 30),
    this.diagnosticsRetention = const Duration(days: 14),
    this.exportRetention = const Duration(days: 7),
  })  : _historyFile = historyFile,
        _diagnosticsFile = diagnosticsFile,
        _exportDirectory = exportDirectory,
        _consentProvider = consentProvider,
        _permissionHardener = permissionHardener ??
            ((Platform.isLinux || Platform.isMacOS)
                ? PosixPrivacyFilePermissionHardener()
                : const NoOpPrivacyFilePermissionHardener()),
        _now = now,
        assert(maxHistoryEntries >= 0),
        assert(maxDiagnosticEntries >= 0),
        assert(maxFileBytes > 0),
        assert(maxExportFiles > 0),
        assert(maxExportBytes > 0);

  static const schemaVersion = 1;
  static const redactionPolicyVersion = 1;

  final File _historyFile;
  final File _diagnosticsFile;
  final Directory _exportDirectory;
  final PrivacyConsentProvider _consentProvider;
  final PrivacyFilePermissionHardener _permissionHardener;
  final PrivacyTimestamp _now;
  final int maxHistoryEntries;
  final int maxDiagnosticEntries;
  final int maxFileBytes;
  final int maxExportFiles;
  final int maxExportBytes;
  final Duration historyRetention;
  final Duration diagnosticsRetention;
  final Duration exportRetention;
  Future<void> _operationTail = Future<void>.value();
  bool _historyClearRequested = false;
  bool _diagnosticsClearRequested = false;

  @override
  Future<PrivacyActivitySnapshot> load() => _serialize(_load);

  @override
  Future<PrivacyActivitySnapshot> record(
    PrivacyActivityEvent event, {
    required PrivacyConsent consent,
  }) =>
      _serialize(() async {
        final snapshot = await _load();
        final activeConsent = _consentProvider.currentPrivacyConsent;
        if (activeConsent != consent || !activeConsent.anyEnabled) {
          return snapshot;
        }

        var history = snapshot.history;
        var diagnostics = snapshot.diagnostics;
        if (consent.historyEnabled) {
          history = _pruneHistory([...history, event.toHistoryEntry()]);
          history = await _fitHistoryToBytes(history);
        }
        if (consent.diagnosticsEnabled) {
          diagnostics = _pruneDiagnostics([...diagnostics, event]);
          diagnostics = await _fitDiagnosticsToBytes(diagnostics);
        }
        if (_consentProvider.currentPrivacyConsent != consent) {
          return snapshot;
        }
        if (consent.historyEnabled && consent.diagnosticsEnabled) {
          await _writeBoth(history, diagnostics);
        } else if (consent.historyEnabled) {
          await _writeHistory(history);
        } else if (consent.diagnosticsEnabled) {
          await _writeDiagnostics(diagnostics);
        }
        return PrivacyActivitySnapshot(
          history: history,
          diagnostics: diagnostics,
          managedExportPaths: snapshot.managedExportPaths,
        );
      });

  @override
  Future<PrivacyActivitySnapshot> clearHistory() => _serialize(() async {
        _historyClearRequested = true;
        final markerPersisted =
            await _bestEffortWriteClearMarker(_historyClearMarker);
        await _deleteWithSidecars(_historyFile);
        final journalDiscarded = await _discardPendingTransactionForClear(
          preserveHistory: false,
          preserveDiagnostics: true,
        );
        if (!journalDiscarded && !markerPersisted) {
          throw FileSystemException(
            'History was deleted but its durable clear marker failed.',
            _historyFile.path,
          );
        }
        await _finalizeClearMarker(
          marker: _historyClearMarker,
          targetDeleted: !await _historyFile.exists(),
        );
        final diagnostics = await _bestEffortReadDiagnostics();
        final exports = await _bestEffortPruneExports();
        return PrivacyActivitySnapshot(
          history: const [],
          diagnostics: diagnostics,
          managedExportPaths: exports.files.map((file) => file.path).toList(),
          managedExportsKnown: exports.known,
        );
      });

  @override
  Future<PrivacyActivitySnapshot> clearDiagnostics() => _serialize(() async {
        _diagnosticsClearRequested = true;
        final markerPersisted =
            await _bestEffortWriteClearMarker(_diagnosticsClearMarker);
        await _deleteWithSidecars(_diagnosticsFile);
        final journalDiscarded = await _discardPendingTransactionForClear(
          preserveHistory: true,
          preserveDiagnostics: false,
        );
        if (!journalDiscarded && !markerPersisted) {
          throw FileSystemException(
            'Diagnostics were deleted but their durable clear marker failed.',
            _diagnosticsFile.path,
          );
        }
        if (await _exportDirectory.exists()) {
          await _exportDirectory.delete(recursive: true);
        }
        await _finalizeClearMarker(
          marker: _diagnosticsClearMarker,
          targetDeleted: !await _diagnosticsFile.exists() &&
              !await _exportDirectory.exists(),
        );
        final history = await _bestEffortReadHistory();
        return PrivacyActivitySnapshot(
          history: history,
          diagnostics: const [],
        );
      });

  @override
  Future<String> exportDiagnostics() => _serialize(() async {
        await _recoverPendingTransaction();
        final diagnostics = await _readDiagnostics();
        await _createPrivateDirectory(_exportDirectory);
        await _pruneExports();
        final timestamp = _now()
            .toUtc()
            .toIso8601String()
            .replaceAll(':', '-')
            .replaceAll('.', '-');
        final destination = File(
          '${_exportDirectory.path}${Platform.pathSeparator}'
          'diagnostics-$timestamp.json',
        );
        final payload = <String, Object>{
          'schemaVersion': schemaVersion,
          'redactionPolicyVersion': redactionPolicyVersion,
          'generatedAt': _roundToMinute(_now()).toIso8601String(),
          'containsSelectedOrTransformedText': false,
          'diagnostics': diagnostics.map((entry) => entry.toJson()).toList(),
        };
        final encoded = jsonEncode(payload);
        if (utf8.encode(encoded).length > maxExportBytes) {
          throw FileSystemException(
            'Diagnostic export exceeds the managed export limit.',
            destination.path,
          );
        }
        await _writeAtomic(destination, encoded);
        await _pruneExports(protectedPath: destination.path);
        return destination.path;
      });

  Future<PrivacyActivitySnapshot> _load() async {
    await _recoverPendingTransaction();
    final history = await _readHistory();
    final diagnostics = await _readDiagnostics();
    final exports = await _pruneExports();
    return PrivacyActivitySnapshot(
      history: history,
      diagnostics: diagnostics,
      managedExportPaths: exports.map((file) => file.path).toList(),
    );
  }

  Future<List<PrivacyHistoryEntry>> _readHistory() async {
    final decoded = await _readRoot(_historyFile, expectedKind: 'history');
    if (decoded == null) return const [];
    try {
      final entries = _decodeList(
        decoded['entries'],
        PrivacyHistoryEntry.fromJson,
      );
      final pruned = _pruneHistory(entries);
      if (pruned.length != entries.length) await _writeHistory(pruned);
      return pruned;
    } on FormatException {
      await _deleteWithSidecars(_historyFile);
      return const [];
    }
  }

  Future<List<PrivacyActivityEvent>> _readDiagnostics() async {
    final decoded =
        await _readRoot(_diagnosticsFile, expectedKind: 'diagnostics');
    if (decoded == null) return const [];
    try {
      final entries = _decodeList(
        decoded['entries'],
        PrivacyActivityEvent.fromJson,
      );
      final pruned = _pruneDiagnostics(entries);
      if (pruned.length != entries.length) await _writeDiagnostics(pruned);
      return pruned;
    } on FormatException {
      await _deleteWithSidecars(_diagnosticsFile);
      return const [];
    }
  }

  Future<Map<String, dynamic>?> _readRoot(
    File file, {
    required String expectedKind,
  }) async {
    await _recoverInterruptedWrite(file);
    if (!await file.exists()) return null;
    if (await file.length() > maxFileBytes) {
      await _deleteWithSidecars(file);
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != schemaVersion ||
          decoded['kind'] != expectedKind) {
        throw const FormatException('Invalid privacy data root.');
      }
      return decoded;
    } on FormatException {
      await _deleteWithSidecars(file);
      return null;
    }
  }

  List<T> _decodeList<T>(
    Object? source,
    T Function(Map<String, dynamic>) decode,
  ) {
    if (source is! List<dynamic>) {
      throw const FormatException('Privacy data entries must be a list.');
    }
    return source.map((value) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid privacy data entry.');
      }
      return decode(value);
    }).toList();
  }

  List<PrivacyHistoryEntry> _pruneHistory(
    List<PrivacyHistoryEntry> entries,
  ) {
    final cutoff = _now().toUtc().subtract(historyRetention);
    final retained = entries
        .where((entry) => !entry.occurredAt.isBefore(cutoff))
        .toList()
      ..sort((left, right) => left.occurredAt.compareTo(right.occurredAt));
    return retained.length <= maxHistoryEntries
        ? retained
        : retained.sublist(retained.length - maxHistoryEntries);
  }

  List<PrivacyActivityEvent> _pruneDiagnostics(
    List<PrivacyActivityEvent> entries,
  ) {
    final cutoff = _now().toUtc().subtract(diagnosticsRetention);
    final retained = entries
        .where((entry) => !entry.occurredAt.isBefore(cutoff))
        .toList()
      ..sort((left, right) => left.occurredAt.compareTo(right.occurredAt));
    return retained.length <= maxDiagnosticEntries
        ? retained
        : retained.sublist(retained.length - maxDiagnosticEntries);
  }

  Future<List<PrivacyHistoryEntry>> _fitHistoryToBytes(
    List<PrivacyHistoryEntry> entries,
  ) async {
    final retained = List<PrivacyHistoryEntry>.of(entries);
    while (retained.isNotEmpty &&
        utf8.encode(_historyPayload(retained)).length > maxFileBytes) {
      retained.removeAt(0);
    }
    return retained;
  }

  Future<List<PrivacyActivityEvent>> _fitDiagnosticsToBytes(
    List<PrivacyActivityEvent> entries,
  ) async {
    final retained = List<PrivacyActivityEvent>.of(entries);
    while (retained.isNotEmpty &&
        utf8.encode(_diagnosticsPayload(retained)).length > maxFileBytes) {
      retained.removeAt(0);
    }
    return retained;
  }

  File get _transactionFile => File(
        '${_historyFile.parent.path}${Platform.pathSeparator}'
        'privacy-activity.v1.transaction',
      );

  File get _historyClearMarker => File('${_historyFile.path}.clear-requested');

  File get _diagnosticsClearMarker =>
      File('${_diagnosticsFile.path}.clear-requested');

  Future<void> _writeBoth(
    List<PrivacyHistoryEntry> history,
    List<PrivacyActivityEvent> diagnostics,
  ) async {
    final historyPayload = _historyPayload(history);
    final diagnosticsPayload = _diagnosticsPayload(diagnostics);
    await _writeAtomic(
      _transactionFile,
      jsonEncode({
        'schemaVersion': schemaVersion,
        'historyPayload': historyPayload,
        'diagnosticsPayload': diagnosticsPayload,
      }),
    );
    await _writeHistoryPayload(historyPayload);
    await _writeDiagnosticsPayload(diagnosticsPayload);
    await _deleteWithSidecars(_transactionFile);
  }

  Future<void> _recoverPendingTransaction() async {
    final journalRemains = await _journalRemains();
    final clearHistory =
        _historyClearRequested || await _historyClearMarker.exists();
    final clearDiagnostics =
        _diagnosticsClearRequested || await _diagnosticsClearMarker.exists();
    if ((clearHistory || clearDiagnostics) && journalRemains) {
      await _discardPendingTransactionForClear(
        preserveHistory: !clearHistory,
        preserveDiagnostics: !clearDiagnostics,
      );
      if (clearHistory) {
        await _deleteWithSidecars(_historyFile);
        await _finalizeClearMarker(
          marker: _historyClearMarker,
          targetDeleted: !await _historyFile.exists(),
        );
      }
      if (clearDiagnostics) {
        await _deleteWithSidecars(_diagnosticsFile);
        if (await _exportDirectory.exists()) {
          await _exportDirectory.delete(recursive: true);
        }
        await _finalizeClearMarker(
          marker: _diagnosticsClearMarker,
          targetDeleted: !await _diagnosticsFile.exists() &&
              !await _exportDirectory.exists(),
        );
      }
      return;
    }
    if (!journalRemains) {
      if (clearHistory) {
        await _finalizeClearMarker(
          marker: _historyClearMarker,
          targetDeleted: true,
        );
      }
      if (clearDiagnostics) {
        await _finalizeClearMarker(
          marker: _diagnosticsClearMarker,
          targetDeleted: true,
        );
      }
    }
    await _recoverInterruptedWrite(_transactionFile);
    if (!await _transactionFile.exists()) return;
    try {
      await _permissionHardener.hardenFile(_transactionFile);
      if (await _transactionFile.length() > maxFileBytes * 3) {
        throw const FormatException('Oversized privacy transaction.');
      }
      final decoded = jsonDecode(await _transactionFile.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != schemaVersion ||
          decoded['historyPayload'] is! String ||
          decoded['diagnosticsPayload'] is! String) {
        throw const FormatException('Invalid privacy transaction.');
      }
      final history =
          _decodeHistoryPayload(decoded['historyPayload'] as String);
      final diagnostics =
          _decodeDiagnosticsPayload(decoded['diagnosticsPayload'] as String);
      await _writeHistory(history);
      await _writeDiagnostics(diagnostics);
      await _deleteWithSidecars(_transactionFile);
    } on FormatException {
      await _deleteWithSidecars(_transactionFile);
    }
  }

  Future<bool> _discardPendingTransactionForClear({
    required bool preserveHistory,
    required bool preserveDiagnostics,
  }) async {
    try {
      final backup = File('${_transactionFile.path}.backup');
      final source = await _transactionFile.exists()
          ? _transactionFile
          : await backup.exists()
              ? backup
              : null;
      if (source != null && await source.length() <= maxFileBytes * 3) {
        final decoded = jsonDecode(await source.readAsString());
        if (decoded is Map<String, dynamic>) {
          if (preserveHistory && decoded['historyPayload'] is String) {
            await _writeHistory(
              _decodeHistoryPayload(decoded['historyPayload'] as String),
            );
          }
          if (preserveDiagnostics && decoded['diagnosticsPayload'] is String) {
            await _writeDiagnostics(
              _decodeDiagnosticsPayload(
                decoded['diagnosticsPayload'] as String,
              ),
            );
          }
        }
      }
    } catch (_) {
    } finally {
      try {
        await _deleteWithSidecars(_transactionFile);
      } catch (_) {}
    }
    return !await _journalRemains();
  }

  Future<bool> _bestEffortWriteClearMarker(File marker) async {
    try {
      await _writeAtomic(
        marker,
        jsonEncode({'schemaVersion': schemaVersion, 'clearRequested': true}),
      );
    } catch (_) {}
    return marker.exists();
  }

  Future<void> _finalizeClearMarker({
    required File marker,
    required bool targetDeleted,
  }) async {
    try {
      final journalRemains = await _journalRemains();
      if (targetDeleted && !journalRemains) {
        try {
          await _deleteWithSidecars(marker);
        } catch (_) {}
        if (marker.path == _historyClearMarker.path) {
          _historyClearRequested = false;
        } else {
          _diagnosticsClearRequested = false;
        }
      }
    } catch (_) {}
  }

  Future<bool> _journalRemains() async =>
      await _transactionFile.exists() ||
      await File('${_transactionFile.path}.backup').exists();

  Future<List<PrivacyHistoryEntry>> _bestEffortReadHistory() async {
    try {
      return await _readHistory();
    } catch (_) {
      return const [];
    }
  }

  Future<List<PrivacyActivityEvent>> _bestEffortReadDiagnostics() async {
    try {
      return await _readDiagnostics();
    } catch (_) {
      return const [];
    }
  }

  Future<({List<File> files, bool known})> _bestEffortPruneExports() async {
    try {
      return (files: await _pruneExports(), known: true);
    } catch (_) {
      return (files: const <File>[], known: false);
    }
  }

  List<PrivacyHistoryEntry> _decodeHistoryPayload(String source) {
    if (utf8.encode(source).length > maxFileBytes) {
      throw const FormatException('Oversized history transaction payload.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['schemaVersion'] != schemaVersion ||
        decoded['kind'] != 'history') {
      throw const FormatException('Invalid history transaction payload.');
    }
    return _decodeList(decoded['entries'], PrivacyHistoryEntry.fromJson);
  }

  List<PrivacyActivityEvent> _decodeDiagnosticsPayload(String source) {
    if (utf8.encode(source).length > maxFileBytes) {
      throw const FormatException(
        'Oversized diagnostics transaction payload.',
      );
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['schemaVersion'] != schemaVersion ||
        decoded['kind'] != 'diagnostics') {
      throw const FormatException('Invalid diagnostics transaction payload.');
    }
    return _decodeList(decoded['entries'], PrivacyActivityEvent.fromJson);
  }

  Future<List<File>> _pruneExports({String? protectedPath}) async {
    if (!await _exportDirectory.exists()) return const [];
    await _permissionHardener.hardenDirectory(_exportDirectory);
    final managedBases = <String>{};
    await for (final entity in _exportDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      final basePath = _managedExportBasePath(entity);
      if (basePath != null) managedBases.add(basePath);
    }
    for (final basePath in managedBases) {
      await _recoverInterruptedWrite(File(basePath));
    }
    final cutoff = _now().toUtc().subtract(exportRetention);
    final candidates = <({File file, DateTime modified, int bytes})>[];
    await for (final entity in _exportDirectory.list(followLinks: false)) {
      if (entity is! File || !_isManagedExport(entity)) continue;
      final modified = (await entity.lastModified()).toUtc();
      if (modified.isBefore(cutoff) && entity.path != protectedPath) {
        await _deleteWithSidecars(entity);
        continue;
      }
      await _permissionHardener.hardenFile(entity);
      candidates.add((
        file: entity,
        modified: modified,
        bytes: await entity.length(),
      ));
    }
    candidates.sort((left, right) => right.modified.compareTo(left.modified));
    final retained = <File>[];
    var totalBytes = 0;
    for (final candidate in candidates) {
      final mustRetain = candidate.file.path == protectedPath;
      final fitsCount = retained.length < maxExportFiles;
      final fitsBytes = totalBytes + candidate.bytes <= maxExportBytes;
      if (mustRetain || (fitsCount && fitsBytes)) {
        retained.add(candidate.file);
        totalBytes += candidate.bytes;
      } else {
        await _deleteWithSidecars(candidate.file);
      }
    }
    return retained;
  }

  bool _isManagedExport(File file) {
    final name = file.uri.pathSegments.last;
    return name.startsWith('diagnostics-') && name.endsWith('.json');
  }

  String? _managedExportBasePath(File file) {
    var path = file.path;
    if (path.endsWith('.tmp')) {
      path = path.substring(0, path.length - '.tmp'.length);
    } else if (path.endsWith('.backup')) {
      path = path.substring(0, path.length - '.backup'.length);
    }
    return _isManagedExport(File(path)) ? path : null;
  }

  Future<void> _writeHistory(List<PrivacyHistoryEntry> entries) =>
      _writeHistoryPayload(_historyPayload(entries));

  Future<void> _writeDiagnostics(List<PrivacyActivityEvent> entries) =>
      _writeDiagnosticsPayload(_diagnosticsPayload(entries));

  Future<void> _writeHistoryPayload(String payload) =>
      _writeAtomic(_historyFile, payload);

  Future<void> _writeDiagnosticsPayload(String payload) =>
      _writeAtomic(_diagnosticsFile, payload);

  String _historyPayload(List<PrivacyHistoryEntry> entries) => jsonEncode({
        'schemaVersion': schemaVersion,
        'kind': 'history',
        'entries': entries.map((entry) => entry.toJson()).toList(),
      });

  String _diagnosticsPayload(List<PrivacyActivityEvent> entries) => jsonEncode({
        'schemaVersion': schemaVersion,
        'kind': 'diagnostics',
        'redactionPolicyVersion': redactionPolicyVersion,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      });

  Future<void> _writeAtomic(File file, String content) async {
    await _createPrivateDirectory(file.parent);
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    var movedCurrent = false;
    try {
      await temporary.writeAsString(content, flush: true);
      await _permissionHardener.hardenFile(temporary);
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) {
        await file.rename(backup.path);
        movedCurrent = true;
      }
      await temporary.rename(file.path);
      await _permissionHardener.hardenFile(file);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await file.exists() && movedCurrent && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _recoverInterruptedWrite(File file) async {
    final backup = File('${file.path}.backup');
    if (!await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    } else if (await file.exists() && await backup.exists()) {
      await backup.delete();
    }
    final temporary = File('${file.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    if (await file.exists()) await _permissionHardener.hardenFile(file);
  }

  Future<void> _createPrivateDirectory(Directory directory) async {
    await directory.create(recursive: true);
    await _permissionHardener.hardenDirectory(directory);
  }

  Future<void> _deleteWithSidecars(File file) async {
    for (final candidate in [
      file,
      File('${file.path}.tmp'),
      File('${file.path}.backup'),
    ]) {
      if (await candidate.exists()) await candidate.delete();
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

DateTime _roundToMinute(DateTime value) {
  final utc = value.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day, utc.hour, utc.minute);
}
