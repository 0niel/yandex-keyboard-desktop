import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length < 2) {
    stderr.writeln(
      'Usage: dart run tool/check_coverage.dart <lcov> <minimum> '
      '[--include-prefix=lib/src/ ...] '
      '[--exclude-prefix=lib/src/generated/ ...] '
      '[--require-source-root=lib/src/ ...] '
      '[--allow-unmeasured=lib/src/platform/native.dart ...] '
      '[--minimum-branch=80] '
      '[--require-branch=required/path.dart=minimum ...] '
      '[required/path.dart=minimum ...]',
    );
    exitCode = 64;
    return;
  }

  final file = File(arguments.first);
  if (!file.existsSync()) {
    stderr.writeln('Coverage file not found: ${file.path}');
    exitCode = 66;
    return;
  }

  final minimum = double.tryParse(arguments[1]);
  if (!isValidCoverageMinimum(minimum)) {
    stderr.writeln('Minimum coverage must be between 0 and 100.');
    exitCode = 64;
    return;
  }
  final requiredLineMinimum = minimum!;

  final trailingArguments = arguments.skip(2).toList();
  final includePrefixes = trailingArguments
      .where((argument) => argument.startsWith('--include-prefix='))
      .map((argument) => _normalizePath(argument.substring(17)))
      .toList();
  final excludePrefixes = trailingArguments
      .where((argument) => argument.startsWith('--exclude-prefix='))
      .map((argument) => _normalizePath(argument.substring(17)))
      .toList();
  final requiredSourceRoots = trailingArguments
      .where((argument) => argument.startsWith('--require-source-root='))
      .map((argument) => argument.substring(22))
      .toList();
  final allowedUnmeasuredPaths = trailingArguments
      .where((argument) => argument.startsWith('--allow-unmeasured='))
      .map((argument) => _normalizePath(argument.substring(19)))
      .toSet();
  final minimumBranchArguments = trailingArguments
      .where((argument) => argument.startsWith('--minimum-branch='))
      .toList();
  final minimumBranch = minimumBranchArguments.length == 1
      ? double.tryParse(minimumBranchArguments.single.substring(17))
      : null;
  if (minimumBranchArguments.length > 1 ||
      (minimumBranchArguments.isNotEmpty &&
          !isValidCoverageMinimum(minimumBranch))) {
    stderr.writeln('Branch coverage minimum must be between 0 and 100.');
    exitCode = 64;
    return;
  }
  final branchRequirements = trailingArguments
      .where((argument) => argument.startsWith('--require-branch='))
      .map((argument) => argument.substring(17));
  final requirements = trailingArguments.where(
    (argument) =>
        !argument.startsWith('--include-prefix=') &&
        !argument.startsWith('--exclude-prefix=') &&
        !argument.startsWith('--require-source-root=') &&
        !argument.startsWith('--allow-unmeasured=') &&
        !argument.startsWith('--minimum-branch=') &&
        !argument.startsWith('--require-branch='),
  );

  final lcovLines = file.readAsLinesSync();
  final files = parseLcov(lcovLines);
  final branchFiles = parseBranchLcov(lcovLines);
  final requiredSources = <String>{};
  for (final root in requiredSourceRoots) {
    final directory = Directory(root);
    if (!directory.existsSync()) {
      stderr.writeln('Required source root not found: $root');
      exitCode = 66;
      return;
    }
    requiredSources.addAll(
      directory
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map(_projectRelativePath),
    );
  }
  final missingSources = findMissingRequiredSources(
    measuredFiles: files,
    sourcePaths: requiredSources,
    includePrefixes: includePrefixes,
    excludePrefixes: excludePrefixes,
    allowedUnmeasuredPaths: allowedUnmeasuredPaths,
  );
  if (missingSources.isNotEmpty) {
    stderr.writeln(
      'Coverage report is missing required production sources:\n'
      '${missingSources.map((path) => '  $path').join('\n')}',
    );
    exitCode = 1;
  }
  final measured = measureCoverage(
    files,
    includePrefixes: includePrefixes,
    excludePrefixes: excludePrefixes,
  );
  final linesFound = measured.found;
  final linesHit = measured.hit;

  if (linesFound == 0) {
    stderr.writeln('Coverage report contains no instrumented lines.');
    exitCode = 65;
    return;
  }

  final percentage = 100 * linesHit / linesFound;
  stdout.writeln(
    'Line coverage${includePrefixes.isEmpty ? '' : ' for ${includePrefixes.join(', ')}'}'
    '${excludePrefixes.isEmpty ? '' : ' excluding ${excludePrefixes.join(', ')}'}: '
    '${percentage.toStringAsFixed(2)}% '
    '($linesHit/$linesFound), required: ${requiredLineMinimum.toStringAsFixed(2)}%',
  );
  if (percentage < requiredLineMinimum) {
    exitCode = 1;
  }

  if (minimumBranch != null) {
    final measuredBranches = measureCoverage(
      branchFiles,
      includePrefixes: includePrefixes,
      excludePrefixes: excludePrefixes,
    );
    if (measuredBranches.found == 0) {
      stderr.writeln(
        'Coverage report contains no branch data. Generate it with '
        '`flutter test --branch-coverage`.',
      );
      exitCode = 1;
    } else {
      final branchPercentage =
          100 * measuredBranches.hit / measuredBranches.found;
      stdout.writeln(
        'Branch coverage: ${branchPercentage.toStringAsFixed(2)}% '
        '(${measuredBranches.hit}/${measuredBranches.found}), '
        'required: ${minimumBranch.toStringAsFixed(2)}%',
      );
      if (branchPercentage < minimumBranch) exitCode = 1;
    }
  }

  for (final requirement in requirements) {
    _enforceFileRequirement(
      requirement,
      files,
      metricName: 'line',
    );
  }

  for (final requirement in branchRequirements) {
    _enforceFileRequirement(
      requirement,
      branchFiles,
      metricName: 'branch',
    );
  }
}

void _enforceFileRequirement(
  String requirement,
  Map<String, ({int found, int hit})> files, {
  required String metricName,
}) {
  final separator = requirement.lastIndexOf('=');
  if (separator <= 0) {
    stderr.writeln('Invalid required-$metricName rule: $requirement');
    exitCode = 64;
    return;
  }
  final path = _normalizePath(requirement.substring(0, separator));
  final requiredMinimum = double.tryParse(requirement.substring(separator + 1));
  final measured = files[path];
  if (!isValidCoverageMinimum(requiredMinimum) ||
      measured == null ||
      measured.found == 0) {
    stderr.writeln(
        'Required $metricName coverage file is missing or invalid: $path');
    exitCode = 1;
    return;
  }
  final threshold = requiredMinimum!;
  final measuredPercentage = 100 * measured.hit / measured.found;
  stdout.writeln(
    '$path $metricName coverage: ${measuredPercentage.toStringAsFixed(2)}% '
    '(${measured.hit}/${measured.found}), '
    'required: ${threshold.toStringAsFixed(2)}%',
  );
  if (measuredPercentage < threshold) exitCode = 1;
}

bool isValidCoverageMinimum(double? value) =>
    value != null && value.isFinite && value >= 0 && value <= 100;

Map<String, ({int found, int hit})> parseLcov(Iterable<String> lines) {
  final files = <String, ({int found, int hit})>{};
  String? currentFile;
  var currentFound = 0;
  var currentHit = 0;
  for (final line in lines) {
    if (line.startsWith('SF:')) {
      currentFile = _normalizePath(line.substring(3));
      currentFound = 0;
      currentHit = 0;
    } else if (line.startsWith('LF:')) {
      currentFound = int.parse(line.substring(3));
    } else if (line.startsWith('LH:')) {
      currentHit = int.parse(line.substring(3));
    } else if (line == 'end_of_record' && currentFile != null) {
      files[currentFile] = (found: currentFound, hit: currentHit);
      currentFile = null;
    }
  }
  return files;
}

Map<String, ({int found, int hit})> parseBranchLcov(Iterable<String> lines) {
  final files = <String, ({int found, int hit})>{};
  String? currentFile;
  int? summaryFound;
  int? summaryHit;
  var branchRecordsFound = 0;
  var branchRecordsHit = 0;
  for (final line in lines) {
    if (line.startsWith('SF:')) {
      currentFile = _normalizePath(line.substring(3));
      summaryFound = null;
      summaryHit = null;
      branchRecordsFound = 0;
      branchRecordsHit = 0;
    } else if (line.startsWith('BRDA:')) {
      final fields = line.substring(5).split(',');
      if (fields.length != 4) {
        throw FormatException('Invalid BRDA record: $line');
      }
      branchRecordsFound++;
      final taken = fields[3] == '-' ? 0 : int.parse(fields[3]);
      if (taken > 0) branchRecordsHit++;
    } else if (line.startsWith('BRF:')) {
      summaryFound = int.parse(line.substring(4));
    } else if (line.startsWith('BRH:')) {
      summaryHit = int.parse(line.substring(4));
    } else if (line == 'end_of_record' && currentFile != null) {
      files[currentFile] = (
        found: summaryFound ?? branchRecordsFound,
        hit: summaryHit ?? branchRecordsHit,
      );
      currentFile = null;
    }
  }
  return files;
}

({int found, int hit}) measureCoverage(
  Map<String, ({int found, int hit})> files, {
  List<String> includePrefixes = const [],
  List<String> excludePrefixes = const [],
}) {
  final normalizedIncludes = includePrefixes.map(_normalizePath).toList();
  final normalizedExcludes = excludePrefixes.map(_normalizePath).toList();
  final measuredFiles = files.entries.where(
    (entry) =>
        (normalizedIncludes.isEmpty ||
            normalizedIncludes.any(entry.key.startsWith)) &&
        !normalizedExcludes.any(entry.key.startsWith),
  );
  final linesFound = measuredFiles.fold<int>(
    0,
    (total, entry) => total + entry.value.found,
  );
  final linesHit = measuredFiles.fold<int>(
    0,
    (total, entry) => total + entry.value.hit,
  );
  return (found: linesFound, hit: linesHit);
}

List<String> findMissingRequiredSources({
  required Map<String, ({int found, int hit})> measuredFiles,
  required Iterable<String> sourcePaths,
  List<String> includePrefixes = const [],
  List<String> excludePrefixes = const [],
  Set<String> allowedUnmeasuredPaths = const {},
}) {
  final measured = measuredFiles.entries
      .where((entry) => entry.value.found > 0)
      .map((entry) => _normalizePath(entry.key))
      .toSet();
  final normalizedIncludes = includePrefixes.map(_normalizePath).toList();
  final normalizedExcludes = excludePrefixes.map(_normalizePath).toList();
  final normalizedAllowances =
      allowedUnmeasuredPaths.map(_normalizePath).toSet();
  final missing = sourcePaths
      .map(_normalizePath)
      .where(
        (path) =>
            (normalizedIncludes.isEmpty ||
                normalizedIncludes.any(path.startsWith)) &&
            !normalizedExcludes.any(path.startsWith) &&
            !normalizedAllowances.contains(path) &&
            !measured.contains(path),
      )
      .toSet()
      .toList()
    ..sort();
  return missing;
}

String _projectRelativePath(File file) {
  final absolute = _normalizePath(file.absolute.path);
  final projectRoot = '${_normalizePath(Directory.current.absolute.path)}/';
  return absolute.startsWith(projectRoot)
      ? absolute.substring(projectRoot.length)
      : absolute;
}

String _normalizePath(String value) => value.replaceAll('\\', '/');
