import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_xccov.dart';

void main() {
  test('recursively extracts Swift files and normalizes paths', () {
    final files = parseXccovFiles({
      'targets': [
        {
          'files': [
            {
              'path': r'C:\repo\KeyboardTransaction.swift',
              'coveredLines': 19,
              'executableLines': 20,
            },
          ],
        },
      ],
    });

    expect(files.single.path, 'C:/repo/KeyboardTransaction.swift');
    expect(files.single.percentage, 95);
  });

  test('uses the best instrumented copy when a source is in two targets', () {
    const files = [
      XccovFileCoverage(
        path: '/Runner/KeyboardSettings.swift',
        coveredLines: 0,
        executableLines: 40,
      ),
      XccovFileCoverage(
        path: '/RunnerTests/KeyboardSettings.swift',
        coveredLines: 38,
        executableLines: 40,
      ),
    ];

    final best = bestCoverageForSuffix(files, 'KeyboardSettings.swift');

    expect(best?.coveredLines, 38);
    expect(best?.percentage, 95);
  });

  test('zero executable lines are not treated as covered', () {
    const coverage = XccovFileCoverage(
      path: '/Runner/KeyboardLayout.swift',
      coveredLines: 0,
      executableLines: 0,
    );

    expect(coverage.percentage, 0);
  });

  test('prefers an instrumented copy over an empty target copy', () {
    const files = [
      XccovFileCoverage(
        path: '/KeyboardExtension/KeyboardLayout.swift',
        coveredLines: 0,
        executableLines: 0,
      ),
      XccovFileCoverage(
        path: '/RunnerTests/KeyboardLayout.swift',
        coveredLines: 9,
        executableLines: 10,
      ),
    ];

    final best = bestCoverageForSuffix(files, 'KeyboardLayout.swift');

    expect(best?.executableLines, 10);
    expect(best?.percentage, 90);
  });

  test('CLI fails a mixed report when any selected file is uninstrumented', () {
    final directory = Directory.systemTemp.createTempSync('ykd-xccov-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final report = File('${directory.path}/coverage.json')
      ..writeAsStringSync(jsonEncode({
        'targets': [
          {
            'files': [
              {
                'path': '/RunnerTests/KeyboardSettings.swift',
                'coveredLines': 0,
                'executableLines': 0,
              },
              {
                'path': '/RunnerTests/KeyboardTransaction.swift',
                'coveredLines': 20,
                'executableLines': 20,
              },
            ],
          },
        ],
      }));

    final result = Process.runSync(
      _dartExecutable(),
      [
        'tool/check_xccov.dart',
        report.path,
        '90',
        'KeyboardSettings.swift',
        'KeyboardTransaction.swift=100',
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 1);
    expect(result.stderr, contains('No executable xccov lines'));
    expect(result.stdout, contains('KeyboardTransaction.swift: 100.00%'));
  });

  test('does not match a merely similar filename', () {
    const files = [
      XccovFileCoverage(
        path: '/repo/NotKeyboardSettings.swift',
        coveredLines: 10,
        executableLines: 10,
      ),
    ];

    expect(bestCoverageForSuffix(files, 'KeyboardSettings.swift'), isNull);
  });
}

String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  for (var level = 0; level < 8; level += 1) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}dart-sdk'
      '${Platform.pathSeparator}bin${Platform.pathSeparator}$executableName',
    );
    if (candidate.existsSync()) return candidate.path;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return executableName;
}
