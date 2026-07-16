import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_coverage.dart';

void main() {
  test('coverage thresholds reject non-finite and out-of-range values', () {
    expect(isValidCoverageMinimum(90), isTrue);
    expect(isValidCoverageMinimum(null), isFalse);
    expect(isValidCoverageMinimum(double.nan), isFalse);
    expect(isValidCoverageMinimum(double.infinity), isFalse);
    expect(isValidCoverageMinimum(-0.01), isFalse);
    expect(isValidCoverageMinimum(100.01), isFalse);
  });

  test('broad gate includes handwritten source and excludes named boundaries',
      () {
    final files = parseLcov('''
SF:lib/src/feature.dart
LF:10
LH:9
end_of_record
SF:lib/src/platform/native_boundary.dart
LF:10
LH:0
end_of_record
SF:lib/l10n/generated.dart
LF:100
LH:0
end_of_record
'''
        .split('\n'));
    final result = measureCoverage(
      files,
      includePrefixes: const ['lib/src/'],
      excludePrefixes: const ['lib/src/platform/native_boundary.dart'],
    );

    expect(result, (found: 10, hit: 9));
  });

  test('native boundary remains measured when it is not explicitly named', () {
    final files = parseLcov('''
SF:lib/src/feature.dart
LF:10
LH:9
end_of_record
SF:lib/src/platform/native_boundary.dart
LF:10
LH:0
end_of_record
'''
        .split('\n'));
    final result = measureCoverage(
      files,
      includePrefixes: const ['lib/src/'],
    );

    expect(result, (found: 20, hit: 9));
  });

  test('required source inventory rejects silently unmeasured production code',
      () {
    final missing = findMissingRequiredSources(
      measuredFiles: const {
        'lib/src/measured.dart': (found: 1, hit: 1),
      },
      sourcePaths: const [
        'lib/src/measured.dart',
        'lib/src/unmeasured.dart',
        'lib/l10n/generated.dart',
      ],
      includePrefixes: const ['lib/src/'],
    );

    expect(missing, const ['lib/src/unmeasured.dart']);
  });

  test('required source inventory only accepts exact named allowances', () {
    final missing = findMissingRequiredSources(
      measuredFiles: const {},
      sourcePaths: const [
        r'lib\src\platform\native.dart',
        'lib/src/platform/native_extra.dart',
        'lib/src/generated/localizations.dart',
      ],
      includePrefixes: const ['lib/src/'],
      excludePrefixes: const ['lib/src/generated/'],
      allowedUnmeasuredPaths: const {'lib/src/platform/native.dart'},
    );

    expect(missing, const ['lib/src/platform/native_extra.dart']);
  });

  test('zero-line SF records do not satisfy required source inventory', () {
    final measuredFiles = parseLcov('''
SF:lib/src/uninstrumented.dart
LF:0
LH:0
end_of_record
'''
        .split('\n'));

    expect(
      findMissingRequiredSources(
        measuredFiles: measuredFiles,
        sourcePaths: const ['lib/src/uninstrumented.dart'],
        includePrefixes: const ['lib/src/'],
      ),
      const ['lib/src/uninstrumented.dart'],
    );
  });

  test('branch parser and filters use BRF and BRH independently of lines', () {
    final files = parseBranchLcov('''
SF:lib/src/feature.dart
LF:100
LH:100
BRF:8
BRH:6
end_of_record
SF:lib/src/platform/native.dart
LF:1
LH:1
BRF:4
BRH:0
end_of_record
'''
        .split('\n'));

    expect(files['lib/src/feature.dart'], (found: 8, hit: 6));
    expect(
      measureCoverage(
        files,
        includePrefixes: const ['lib/src/'],
        excludePrefixes: const ['lib/src/platform/native.dart'],
      ),
      (found: 8, hit: 6),
    );
  });

  test('branch parser derives totals from Flutter BRDA-only reports', () {
    final files = parseBranchLcov('''
SF:lib/src/feature.dart
BRDA:10,0,0,3
BRDA:10,0,1,0
BRDA:20,0,0,-
end_of_record
'''
        .split('\n'));

    expect(files['lib/src/feature.dart'], (found: 3, hit: 1));
  });
}
