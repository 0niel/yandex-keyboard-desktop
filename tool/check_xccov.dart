import 'dart:convert';
import 'dart:io';

final class XccovFileCoverage {
  const XccovFileCoverage({
    required this.path,
    required this.coveredLines,
    required this.executableLines,
  });

  final String path;
  final int coveredLines;
  final int executableLines;

  double get percentage =>
      executableLines == 0 ? 0 : coveredLines * 100 / executableLines;
}

List<XccovFileCoverage> parseXccovFiles(Object? report) {
  final candidates = <XccovFileCoverage>[];

  void visit(Object? value) {
    if (value is List<Object?>) {
      for (final item in value) {
        visit(item);
      }
      return;
    }
    if (value is! Map<String, Object?>) return;
    final path = value['path'];
    final covered = value['coveredLines'];
    final executable = value['executableLines'];
    if (path is String &&
        path.endsWith('.swift') &&
        covered is num &&
        executable is num) {
      candidates.add(XccovFileCoverage(
        path: path.replaceAll('\\', '/'),
        coveredLines: covered.toInt(),
        executableLines: executable.toInt(),
      ));
    }
    for (final child in value.values) {
      visit(child);
    }
  }

  visit(report);
  return candidates;
}

XccovFileCoverage? bestCoverageForSuffix(
  Iterable<XccovFileCoverage> files,
  String suffix,
) {
  final normalized = suffix.replaceAll('\\', '/');
  XccovFileCoverage? best;
  final candidates = files.where((file) => normalized.contains('/')
      ? file.path.endsWith(normalized)
      : file.path.split('/').last == normalized);
  for (final file in candidates) {
    final fileIsInstrumented = file.executableLines > 0;
    final bestIsInstrumented = (best?.executableLines ?? 0) > 0;
    if (best == null ||
        (fileIsInstrumented && !bestIsInstrumented) ||
        (fileIsInstrumented == bestIsInstrumented &&
            (file.percentage > best.percentage ||
                (file.percentage == best.percentage &&
                    file.executableLines > best.executableLines)))) {
      best = file;
    }
  }
  return best;
}

void main(List<String> arguments) {
  if (arguments.length < 3) {
    stderr.writeln(
      'Usage: dart run tool/check_xccov.dart '
      '<report.json> <overall-percent> <file-suffix[=percent]>...',
    );
    exitCode = 64;
    return;
  }
  final requiredOverall = double.tryParse(arguments[1]);
  if (requiredOverall == null || requiredOverall < 0 || requiredOverall > 100) {
    stderr.writeln('Invalid overall coverage threshold: ${arguments[1]}');
    exitCode = 64;
    return;
  }

  final report = jsonDecode(File(arguments[0]).readAsStringSync());
  final files = parseXccovFiles(report);
  var totalCovered = 0;
  var totalExecutable = 0;
  var failed = false;
  for (final specification in arguments.skip(2)) {
    final separator = specification.lastIndexOf('=');
    final suffix =
        separator < 0 ? specification : specification.substring(0, separator);
    final requiredFile = separator < 0
        ? null
        : double.tryParse(specification.substring(separator + 1));
    if (suffix.isEmpty ||
        (separator >= 0 &&
            (requiredFile == null || requiredFile < 0 || requiredFile > 100))) {
      stderr.writeln('Invalid file coverage specification: $specification');
      exitCode = 64;
      return;
    }
    final coverage = bestCoverageForSuffix(files, suffix);
    if (coverage == null) {
      stderr.writeln('Missing xccov entry for $suffix');
      failed = true;
      continue;
    }
    if (coverage.executableLines <= 0) {
      stderr.writeln('No executable xccov lines for $suffix');
      failed = true;
      continue;
    }
    totalCovered += coverage.coveredLines;
    totalExecutable += coverage.executableLines;
    final percentage = coverage.percentage;
    stdout.writeln(
      '$suffix: ${percentage.toStringAsFixed(2)}% '
      '(${coverage.coveredLines}/${coverage.executableLines})'
      '${requiredFile == null ? '' : ', required: ${requiredFile.toStringAsFixed(2)}%'}',
    );
    if (requiredFile != null && percentage + 1e-9 < requiredFile) {
      failed = true;
    }
  }

  final overall =
      totalExecutable == 0 ? 0 : totalCovered * 100 / totalExecutable;
  stdout.writeln(
    'Selected Swift coverage: ${overall.toStringAsFixed(2)}% '
    '($totalCovered/$totalExecutable), required: '
    '${requiredOverall.toStringAsFixed(2)}%',
  );
  if (overall + 1e-9 < requiredOverall) failed = true;
  if (failed) exitCode = 1;
}
