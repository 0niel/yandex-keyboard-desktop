import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts a clean Windows portable archive', () async {
    final fixture = await _fixture();
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('sha256='));
  });

  test('rejects private and build-only portable payloads', () async {
    final fixture = await _fixture(includeForbiddenFiles: true);
    addTearDown(() => fixture.parent.delete(recursive: true));

    final result = await _audit(fixture);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('secrets/token.txt'));
    expect(result.stderr, contains('runner.pdb'));
    expect(result.stderr, contains('../escape.txt'));
  });
}

Future<ProcessResult> _audit(File fixture) => Process.run(
      'python',
      ['tool/check_windows_portable.py', fixture.path],
      workingDirectory: Directory.current.path,
    );

Future<File> _fixture({bool includeForbiddenFiles = false}) async {
  final directory =
      await Directory.systemTemp.createTemp('ykd-portable-audit-');
  final archive = File('${directory.path}/portable.zip');
  const createArchive = r'''
import sys, zipfile

path, forbidden = sys.argv[1], sys.argv[2] == "1"
entries = {
  "yandex_keyboard_desktop.exe": b"fixture",
  "flutter_windows.dll": b"fixture",
  "data/flutter_assets/NOTICES.Z": b"notices",
  "data/flutter_assets/assets/brand/symbol.svg": b"<svg/>",
  "data/flutter_assets/assets/brand/wordmark.svg": b"<svg/>",
}
if forbidden:
  entries["data/flutter_assets/secrets/token.txt"] = b"private"
  entries["runner.pdb"] = b"debug"
  entries["stale.msix"] = b"installer"
  entries["../escape.txt"] = b"escape"
with zipfile.ZipFile(path, "w") as archive:
  for name, value in entries.items():
    archive.writestr(name, value)
''';
  final result = await Process.run('python', [
    '-c',
    createArchive,
    archive.path,
    includeForbiddenFiles ? '1' : '0',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Could not create portable fixture: ${result.stderr}');
  }
  return archive;
}
